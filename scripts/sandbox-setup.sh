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
###############################################################################

set -euo pipefail

IMG_DIR="/var/lib/sandbox-disks"
DISK_COUNT=3
DISK_SIZE="2G"
VG_NAME="labvg"
LV_NAME="labvol"
MOUNT_POINT="/srv/nfs/share"
EXPORT_CLIENT="127.0.0.1"
EXPORT_OPTS="rw,sync,no_subtree_check,root_squash"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo:  sudo $0" >&2
    exit 1
fi

log "Installing packages (nfs-utils, lvm2)"
dnf install -y nfs-utils lvm2

log "Creating ${DISK_COUNT} loop images of ${DISK_SIZE} each in ${IMG_DIR}"
mkdir -p "${IMG_DIR}"

LOOP_DEVICES=()
for i in $(seq 1 "${DISK_COUNT}"); do
    img="${IMG_DIR}/disk${i}.img"
    truncate -s "${DISK_SIZE}" "${img}"
    dev="$(losetup --find --show "${img}")"
    LOOP_DEVICES+=("${dev}")
    echo "   ${img}  ->  ${dev}"
done

log "Building LVM on top of the loop devices"
pvcreate "${LOOP_DEVICES[@]}"
vgcreate "${VG_NAME}" "${LOOP_DEVICES[@]}"
lvcreate -l 100%FREE -n "${LV_NAME}" "${VG_NAME}"
LV_PATH="/dev/${VG_NAME}/${LV_NAME}"

log "Formatting the volume as xfs and mounting it at ${MOUNT_POINT}"
mkfs.xfs "${LV_PATH}"

mkdir -p "${MOUNT_POINT}"
mount "${LV_PATH}" "${MOUNT_POINT}"
chmod 1777 "${MOUNT_POINT}"

log "Configuring the NFS export"
systemctl enable --now nfs-server

EXPORT_LINE="${MOUNT_POINT} ${EXPORT_CLIENT}(${EXPORT_OPTS})"
if ! grep -qF "${MOUNT_POINT}" /etc/exports 2>/dev/null; then
    echo "${EXPORT_LINE}" >> /etc/exports
fi

exportfs -ra

if systemctl is-active --quiet firewalld; then
    log "Opening NFS ports in firewalld"
    firewall-cmd --permanent --add-service=nfs
    firewall-cmd --permanent --add-service=mountd
    firewall-cmd --permanent --add-service=rpc-bind
    firewall-cmd --reload
fi

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
