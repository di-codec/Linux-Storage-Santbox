#!/usr/bin/env bash
###############################################################################
# sandbox-setup.sh
#
# Deploys a learning storage sandbox for practicing the
# Storage Automation Engineer role:
#
#     loop images  ->  LVM (PV -> VG -> LV)  ->  xfs  ->  NFS export
#
# Run:    sudo ./sandbox-setup.sh
# Reset:  sudo ./sandbox-teardown.sh   (undoes everything this script did)
#
# The script assumes a clean system. To rebuild the sandbox, run teardown
# first, then setup again.
###############################################################################

# set -e   : exit on any command error (don't continue in a broken state)
# set -u   : error on use of an undeclared variable (catches typos)
# set -o pipefail : an error in a pipeline (a | b) fails the whole line
set -euo pipefail


### 0. PARAMETERS — edit here ###############################################

IMG_DIR="/var/lib/sandbox-disks"   # where the disk image files live.
                                   # Later you can point this at the 5 TB drive,
                                   # e.g. /mnt/bigdrive/disks
DISK_COUNT=3                       # how many virtual disks to create
DISK_SIZE="2G"                     # size of each image
VG_NAME="labvg"                    # LVM Volume Group name
LV_NAME="labvol"                   # LVM Logical Volume name
MOUNT_POINT="/srv/nfs/share"       # where the finished volume is mounted / exported
EXPORT_CLIENT="127.0.0.1"          # who is allowed to mount over NFS.
                                   # 127.0.0.1 = mount from this same machine.
                                   # For a second client VM, use its subnet,
                                   # e.g. 10.0.2.0/24
EXPORT_OPTS="rw,sync,no_subtree_check,root_squash"
                                   # rw            — read + write
                                   # sync          — flush writes to disk at once
                                   # no_subtree_check — faster, standard for shares
                                   # root_squash   — client root != server root
                                   #                 (security: remote root is
                                   #                  mapped to nobody)

# Small helper for readable step output
log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }


### 1. CHECKS AND PACKAGES ##################################################

# Disks, LVM and exports all require root privileges.
if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo:  sudo $0" >&2
    exit 1
fi

log "Installing packages (nfs-utils, lvm2)"
dnf install -y nfs-utils lvm2


### 2. LOOP IMAGES #########################################################
# Create N image files and attach each as a block device /dev/loopX.
# The system will treat them as ordinary disks.

log "Creating ${DISK_COUNT} loop images of ${DISK_SIZE} each in ${IMG_DIR}"
mkdir -p "${IMG_DIR}"

LOOP_DEVICES=()   # collect the created /dev/loopX names here
for i in $(seq 1 "${DISK_COUNT}"); do
    img="${IMG_DIR}/disk${i}.img"

    # truncate creates a sparse file: declared at DISK_SIZE, but it only uses
    # real disk space as data is written.
    truncate -s "${DISK_SIZE}" "${img}"

    # losetup --find --show : grab the first free /dev/loopX, bind it to the
    # file, and print its name. Capture that name into a variable.
    dev="$(losetup --find --show "${img}")"
    LOOP_DEVICES+=("${dev}")
    echo "   ${img}  ->  ${dev}"
done


### 3. LVM: PV -> VG -> LV ##################################################
# This is how real servers turn a set of disks into one expandable volume.

log "Building LVM on top of the loop devices"

# pvcreate — mark the devices as Physical Volumes (LVM building blocks)
pvcreate "${LOOP_DEVICES[@]}"

# vgcreate — combine all PVs into one Volume Group (a shared pool of space)
vgcreate "${VG_NAME}" "${LOOP_DEVICES[@]}"

# lvcreate — carve out a Logical Volume. -l 100%FREE = take the whole pool.
lvcreate -l 100%FREE -n "${LV_NAME}" "${VG_NAME}"

LV_PATH="/dev/${VG_NAME}/${LV_NAME}"   # path to the finished volume


### 4. FILESYSTEM + MOUNT ###################################################

log "Formatting the volume as xfs and mounting it at ${MOUNT_POINT}"
mkfs.xfs "${LV_PATH}"

mkdir -p "${MOUNT_POINT}"
mount "${LV_PATH}" "${MOUNT_POINT}"

# Lab shortcut: let any user write to the share (like /tmp). Don't do this in
# production — permissions are granted narrowly there.
chmod 1777 "${MOUNT_POINT}"


### 5. NFS SERVER ###########################################################

log "Configuring the NFS export"
systemctl enable --now nfs-server

# Add the export line only if it isn't there yet (avoid duplicates on re-run)
EXPORT_LINE="${MOUNT_POINT} ${EXPORT_CLIENT}(${EXPORT_OPTS})"
if ! grep -qF "${MOUNT_POINT}" /etc/exports 2>/dev/null; then
    echo "${EXPORT_LINE}" >> /etc/exports
fi

# exportfs -ra : re-read /etc/exports and apply all exports
exportfs -ra

# Open the NFS ports in firewalld — but only if it is actually running
if systemctl is-active --quiet firewalld; then
    log "Opening NFS ports in firewalld"
    firewall-cmd --permanent --add-service=nfs
    firewall-cmd --permanent --add-service=mountd
    firewall-cmd --permanent --add-service=rpc-bind
    firewall-cmd --reload
fi


### 6. VERIFICATION #########################################################
# Prove it works: show the volume, the export, and mount the share back to
# ourselves over NFS into a separate folder.

log "Check: local volume"
df -hT "${MOUNT_POINT}"

log "Check: list of NFS exports"
exportfs -v

log "Check: mounting the share back over NFS at /mnt/nfs-test"
mkdir -p /mnt/nfs-test
mount -t nfs 127.0.0.1:"${MOUNT_POINT}" /mnt/nfs-test
df -hT /mnt/nfs-test

log "Done. Sandbox deployed."
echo "   Working folder (local):  ${MOUNT_POINT}"
echo "   Same folder via NFS:     /mnt/nfs-test"
echo "   Write files into either and practice df / du / find."
