#!/usr/bin/env bash
###############################################################################
# generate-messy-data.sh
#
# Fills the NFS share with a realistically messy dataset for storage-audit
# practice.
###############################################################################
set -euo pipefail

TARGET_DIR="/srv/nfs/share"
DATASET="${TARGET_DIR}/dataset"
TOTAL_FILES=1500
DUP_SETS=15
DUP_COPIES_MAX=6
STALE_PERCENT=30
LARGE_FILES=3
LARGE_SIZE_MB=30

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if ! mountpoint -q "${TARGET_DIR}"; then
    echo "ERROR: ${TARGET_DIR} is not mounted. Run sandbox-setup.sh first." >&2
    exit 1
fi

if [[ "${DATASET}" != *"/dataset" ]]; then
    echo "ERROR: DATASET path looks wrong, refusing to delete: ${DATASET}" >&2
    exit 1
fi

log "Resetting dataset folder: ${DATASET}"
rm -rf "${DATASET}"
mkdir -p "${DATASET}"

EXTENSIONS=(log csv txt bak tmp dat json xml)
DIRS=(
    "projects/alpha/src"   "projects/alpha/build"   "projects/beta/data"
    "projects/gamma/logs"  "users/alice/docs"       "users/bob/downloads"
    "users/carol/backup"   "shared/reports"         "archive/2023"
    "archive/2024"         "logs/app"               "tmp"
)
for d in "${DIRS[@]}"; do
    mkdir -p "${DATASET}/${d}"
done

log "Creating ${TOTAL_FILES} ordinary files"
for i in $(seq 1 "${TOTAL_FILES}"); do
    dir="${DIRS[$((RANDOM % ${#DIRS[@]}))]}"
    ext="${EXTENSIONS[$((RANDOM % ${#EXTENSIONS[@]}))]}"
    size=$((RANDOM % 20000 + 512))
    head -c "${size}" /dev/urandom > "${DATASET}/${dir}/file_${i}.${ext}"
done

log "Injecting ${DUP_SETS} duplicate groups"
for s in $(seq 1 "${DUP_SETS}"); do
    master="/tmp/dup_master_${s}"
    head -c $((RANDOM % 50000 + 5000)) /dev/urandom > "${master}"

    copies=$((RANDOM % (DUP_COPIES_MAX - 1) + 2))
    for c in $(seq 1 "${copies}"); do
        dir="${DIRS[$((RANDOM % ${#DIRS[@]}))]}"
        cp "${master}" "${DATASET}/${dir}/report_${s}_copy${c}.dat"
    done
    rm -f "${master}"
done

log "Creating ${LARGE_FILES} large files of ${LARGE_SIZE_MB}MB each"
for i in $(seq 1 "${LARGE_FILES}"); do
    dir="${DIRS[$((RANDOM % ${#DIRS[@]}))]}"
    head -c "$((LARGE_SIZE_MB * 1024 * 1024))" /dev/urandom \
        > "${DATASET}/${dir}/bigdump_${i}.tar"
done

log "Back-dating ~${STALE_PERCENT}% of files (stale files)"
total_now=$(find "${DATASET}" -type f | wc -l)
stale_count=$((total_now * STALE_PERCENT / 100))

find "${DATASET}" -type f | shuf | head -n "${stale_count}" | while read -r f; do
    days_ago=$((RANDOM % 900 + 400))
    old_date="$(date -d "-${days_ago} days" +%Y-%m-%d)"
    touch -d "${old_date}" "${f}"
done

log "Setting a few bad permissions"
find "${DATASET}" -type f | shuf | head -n 3 | while read -r f; do
    chmod 0777 "${f}"
done

file_count=$(find "${DATASET}" -type f | wc -l)
total_size=$(du -sh "${DATASET}" | cut -f1)

log "Done. Messy dataset ready."
echo "   Location:    ${DATASET}"
echo "   Files:       ${file_count}"
echo "   Total size:  ${total_size}"
