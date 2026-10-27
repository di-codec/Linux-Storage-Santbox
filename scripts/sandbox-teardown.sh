#!/usr/bin/env bash
###############################################################################
# sandbox-teardown.sh
#
# Fully undoes what sandbox-setup.sh deployed, in reverse order:
#   NFS unmount -> remove export -> unmount volume ->
#   remove LV/VG/PV -> detach loop devices -> delete images.
###############################################################################
set -uo pipefail

IMG_DIR="/var/lib/sandbox-disks"
VG_NAME="labvg"
LV_NAME="labvol"
MOUNT_POINT="/srv/nfs/share"

log() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo:  sudo $0" >&2
    exit 1
fi

log "Unmounting /mnt/nfs-test"
umount /mnt/nfs-test 2>/dev/null && rmdir /mnt/nfs-test 2>/dev/null || true

log "Removing the NFS export"
exportfs -u "127.0.0.1:${MOUNT_POINT}" 2>/dev/null || true
if [[ -f /etc/exports ]]; then
    grep -vF "${MOUNT_POINT}" /etc/exports > /etc/exports.tmp 2>/dev/null || true
    mv /etc/exports.tmp /etc/exports 2>/dev/null || true
    exportfs -ra 2>/dev/null || true
fi

log "Unmounting ${MOUNT_POINT}"
umount "${MOUNT_POINT}" 2>/dev/null || true

log "Removing LVM (LV -> VG -> PV)"
lvremove -f "/dev/${VG_NAME}/${LV_NAME}" 2>/dev/null || true
vgremove -f "${VG_NAME}" 2>/dev/null || true

log "Detaching loop devices and deleting images"
if [[ -d "${IMG_DIR}" ]]; then
    for img in "${IMG_DIR}"/disk*.img; do
        [[ -e "${img}" ]] || continue
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
