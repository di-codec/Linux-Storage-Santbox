#!/usr/bin/env bash
###############################################################################
# generate-messy-data.sh
#
# Fills the NFS share with a realistically messy dataset for storage-audit
# practice: nested folders, random-content files of varied sizes, duplicate
# files (same content, different names), stale files (old mtime), a few large
# files, and a couple of files with bad permissions.
#
# Run:  ./generate-messy-data.sh
#
# Safe to re-run: it only ever touches the "dataset" subfolder of the share,
# and wipes it at the start so the mess doesn't pile up.
###############################################################################
set -euo pipefail


### 0. PARAMETERS — edit here ###############################################

TARGET_DIR="/srv/nfs/share"        # the mounted share (from stage 1)
DATASET="${TARGET_DIR}/dataset"    # everything is created under here

TOTAL_FILES=1500                   # number of ordinary filler files
DUP_SETS=15                        # how many groups of duplicate files
DUP_COPIES_MAX=6                   # up to this many copies per duplicate group
STALE_PERCENT=30                   # % of files to back-date (mtime 1–3 years ago)
LARGE_FILES=3                      # number of big files
LARGE_SIZE_MB=30                   # size of each big file, in MB

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }


### 1. CHECKS AND PREP ######################################################

# The share must be mounted (stage 1). Bail out clearly if it isn't.
if ! mountpoint -q "${TARGET_DIR}"; then
    echo "ERROR: ${TARGET_DIR} is not mounted. Run sandbox-setup.sh first." >&2
    exit 1
fi

# Safety guard: only ever wipe a path that ends in /dataset.
if [[ "${DATASET}" != *"/dataset" ]]; then
    echo "ERROR: DATASET path looks wrong, refusing to delete: ${DATASET}" >&2
    exit 1
fi

log "Resetting dataset folder: ${DATASET}"
rm -rf "${DATASET}"
mkdir -p "${DATASET}"

# File extensions to spread around (for auditing by type later)
EXTENSIONS=(log csv txt bak tmp dat json xml)


### 2. DIRECTORY TREE #######################################################
# Build a human-looking structure so du/find have something to chew on.

log "Building directory tree"
DIRS=(
    "projects/alpha/src"   "projects/alpha/build"   "projects/beta/data"
    "projects/gamma/logs"  "users/alice/docs"       "users/bob/downloads"
    "users/carol/backup"   "shared/reports"         "archive/2023"
    "archive/2024"         "logs/app"               "tmp"
)
for d in "${DIRS[@]}"; do
    mkdir -p "${DATASET}/${d}"
done


### 3. ORDINARY FILES #######################################################
# The bulk of the dataset: random *content* (real bytes, so du is honest),
# random size, random extension, scattered across the tree.

log "Creating ${TOTAL_FILES} ordinary files"
for i in $(seq 1 "${TOTAL_FILES}"); do
    dir="${DIRS[$((RANDOM % ${#DIRS[@]}))]}"          # pick a random folder
    ext="${EXTENSIONS[$((RANDOM % ${#EXTENSIONS[@]}))]}"
    size=$((RANDOM % 20000 + 512))                    # 0.5 KB .. ~20 KB
    head -c "${size}" /dev/urandom > "${DATASET}/${dir}/file_${i}.${ext}"
done


### 4. DUPLICATES ###########################################################
# Make a master file, then copy it (identical content = identical hash) under
# different names in different folders. This is what dedup tools detect.

log "Injecting ${DUP_SETS} duplicate groups"
for s in $(seq 1 "${DUP_SETS}"); do
    master="/tmp/dup_master_${s}"
    head -c $((RANDOM % 50000 + 5000)) /dev/urandom > "${master}"

    copies=$((RANDOM % (DUP_COPIES_MAX - 1) + 2))     # 2..DUP_COPIES_MAX copies
    for c in $(seq 1 "${copies}"); do
        dir="${DIRS[$((RANDOM % ${#DIRS[@]}))]}"
        cp "${master}" "${DATASET}/${dir}/report_${s}_copy${c}.dat"
    done
    rm -f "${master}"
done


### 5. LARGE FILES ##########################################################
# A few heavy files that will dominate du / show up in find -size.

log "Creating ${LARGE_FILES} large files of ${LARGE_SIZE_MB}MB each"
for i in $(seq 1 "${LARGE_FILES}"); do
    dir="${DIRS[$((RANDOM % ${#DIRS[@]}))]}"
    head -c "$((LARGE_SIZE_MB * 1024 * 1024))" /dev/urandom \
        > "${DATASET}/${dir}/bigdump_${i}.tar"
done


### 6. AGE A FRACTION (STALE FILES) #########################################
# Back-date mtime on a share of files so `find -mtime +365` finds them.

log "Back-dating ~${STALE_PERCENT}% of files (stale files)"
total_now=$(find "${DATASET}" -type f | wc -l)
stale_count=$((total_now * STALE_PERCENT / 100))

find "${DATASET}" -type f | shuf | head -n "${stale_count}" | while read -r f; do
    days_ago=$((RANDOM % 900 + 400))                  # ~1.1 .. 3.5 years ago
    old_date="$(date -d "-${days_ago} days" +%Y-%m-%d)"
    touch -d "${old_date}" "${f}"
done


### 7. BAD PERMISSIONS ######################################################
# A couple of world-writable files — a classic security-audit finding.

log "Setting a few bad permissions"
find "${DATASET}" -type f | shuf | head -n 3 | while read -r f; do
    chmod 0777 "${f}"
done


### 8. SUMMARY + WHAT TO TRY ################################################

file_count=$(find "${DATASET}" -type f | wc -l)
total_size=$(du -sh "${DATASET}" | cut -f1)

log "Done. Messy dataset ready."
echo "   Location:    ${DATASET}"
echo "   Files:       ${file_count}"
echo "   Total size:  ${total_size}"
echo
echo "   Try these audit commands:"
echo "     du -h --max-depth=2 ${DATASET} | sort -h        # where the space went"
echo "     find ${DATASET} -type f -size +10M              # large files"
echo "     find ${DATASET} -type f -mtime +365             # stale (>1 year)"
echo "     find ${DATASET} -type f -perm -0002             # world-writable"
