#!/usr/bin/env bash
###############################################################################
# sandbox-teardown.sh
#
# Fully undoes what sandbox-setup.sh deployed, in reverse order:
#   NFS unmount -> remove export -> unmount volume ->
#   remove LV/VG/PV -> detach loop devices -> delete images.
#
# Run:  sudo ./sandbox-teardown.sh
#
# Keep these variable values in sync with the setup script.
###############################################################################
set -uo pipefail   # no -e: fine if some parts are already gone; run to the end

### PARAMETERS — keep in sync with sandbox-setup.sh ###
IMG_DIR="/var/lib/sandbox-disks"
VG_NAME="labvg"
LV_NAME="labvol"
MOUNT_POINT="/srv/nfs/share"

log() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo:  sudo $0" >&2
    exit 1
fi

# 1. Unmount the NFS check (client side)
log "Unmounting /mnt/nfs-test"
umount /mnt/nfs-test 2>/dev/null && rmdir /mnt/nfs-test 2>/dev/null || true

# 2. Drop the export and remove the line from /etc/exports
log "Removing the NFS export"
exportfs -u "127.0.0.1:${MOUNT_POINT}" 2>/dev/null || true
# Remove our share's line from /etc/exports (if the file exists)
if [[ -f /etc/exports ]]; then
    grep -vF "${MOUNT_POINT}" /etc/exports > /etc/exports.tmp 2>/dev/null || true
    mv /etc/exports.tmp /etc/exports 2>/dev/null || true
    exportfs -ra 2>/dev/null || true
fi

# 3. Unmount the local volume
log "Unmounting ${MOUNT_POINT}"
umount "${MOUNT_POINT}" 2>/dev/null || true

# 4. Tear down LVM: logical volume first, then group, then physical volumes
log "Removing LVM (LV -> VG -> PV)"
lvremove -f "/dev/${VG_NAME}/${LV_NAME}" 2>/dev/null || true
vgremove -f "${VG_NAME}" 2>/dev/null || true

# 5. Detach loop devices bound to our images and delete the files
log "Detaching loop devices and deleting images"
if [[ -d "${IMG_DIR}" ]]; then
    for img in "${IMG_DIR}"/disk*.img; do
        [[ -e "${img}" ]] || continue
        # pvremove on the device bound to the image (clear the LVM label)
        dev="$(losetup -j "${img}" | cut -d: -f1)"
        if [[ -n "${dev}" ]]; then
            pvremove -f "${dev}" 2>/dev/null || true
            losetup -d "${dev}" 2>/dev/null || true
        fi
        rm -f "${img}"
    done
    rmdir "${IMG_DIR}" 2>/dev/null || true
fi

log "Done. Sandbox removed, system back to its original state."
echo "   To rebuild: sudo ./sandbox-setup.sh"
