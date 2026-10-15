#!/usr/bin/env bash
# Mount the cold tiers from Google Drive, tuned for Parquet range reads.
#
# `people/` (39.9 GiB, 1,564 files) and `children/` (58.5 GiB, 75 files) are
# read from here. The hot tiers -- agg, dims, idx -- are copied to the
# runner's own disk instead and never touch this mount.
#
# `children/` is the hard case and the flags below are chosen for it:
# /api/person/{id}. A detail view reads twenty small slices out of files that
# average 800 MB, so what matters is the cost of a *seek*, not throughput --
# which is why this is a FUSE mount with a read cache rather than a download.
#
# Why Drive at all, when people/ and idx/ are on R2: a person lookup is one
# click on one person, not the search path, so 100-300 ms of Drive latency is
# affordable here and nowhere else. It also keeps 58.5 GiB out of R2, which is
# the only part of this deployment that costs money.
#
#   deploy/runner/mount-drive.sh /mnt/drive/atlas-lake
#   deploy/runner/mount-drive.sh /mnt/atlas-drive --unmount
#
# Reads credentials from rclone's own config or RCLONE_CONFIG_* environment
# variables. Nothing here holds a secret.
set -euo pipefail

MOUNT_POINT="${1:-/mnt/atlas-drive}"
REMOTE="${ATLAS_DRIVE_REMOTE:-atlas-drive}"
# Empty by default, and that is the point: the `atlas-drive` remote is
# configured with root_folder_id pointing at the atlas-lake folder, so the
# remote root already *is* the lake. A default of "atlas-lake" here would
# mount atlas-lake/atlas-lake, which exists nowhere and mounts as empty --
# a lake that reads as "no files" rather than as an error.
BUCKET="${ATLAS_DRIVE_PATH:-}"
CACHE_DIR="${ATLAS_VFS_CACHE:-/opt/atlas/vfs-cache}"
LOG="${ATLAS_MOUNT_LOG:-/opt/atlas/logs/mount-drive.log}"

if [[ "${2:-}" == "--unmount" ]]; then
  fusermount -u "$MOUNT_POINT" 2>/dev/null || umount "$MOUNT_POINT" 2>/dev/null || true
  echo "unmounted $MOUNT_POINT"
  exit 0
fi

command -v rclone >/dev/null || { echo "rclone is not installed" >&2; exit 1; }
rclone listremotes | grep -qx "${REMOTE}:" || {
  echo "rclone remote '${REMOTE}' is not configured -- see docs/DEPLOYMENT.md section 4" >&2
  exit 1
}

mkdir -p "$MOUNT_POINT" "$CACHE_DIR" "$(dirname "$LOG")"

# Already mounted and answering? Leave it alone. The runner's boot script is
# idempotent on purpose: a watchdog that remounts a working mount is a watchdog
# that drops in-flight reads.
if mountpoint -q "$MOUNT_POINT" && [[ -d "$MOUNT_POINT/children" && -d "$MOUNT_POINT/people" ]]; then
  echo "already mounted: $MOUNT_POINT"
  exit 0
fi
mountpoint -q "$MOUNT_POINT" && { fusermount -u "$MOUNT_POINT" || true; }

# --- the flags, and why each one is not the default ------------------------ #
#
# --vfs-cache-mode full
#     Parquet is read by seeking to a row group. In `minimal` mode rclone
#     cannot serve a read that is not sequential, so DuckDB's seeks turn into
#     whole-file downloads -- 800 MB to answer one lookup.
#
# --vfs-cache-max-size 8G
#     The runner has ~45 GB free after reclaiming the preinstalled toolchains,
#     and 6.2 GiB of that is the local dims/ tier. 8G leaves room and still
#     holds the hot slices of several files.
#
# --dir-cache-time 9999h
#     The lake is immutable. Re-reading directory listings would spend an API
#     call to learn nothing. This is the single biggest win available here and
#     it is only correct because nothing ever writes to this tier.
#
# --vfs-read-chunk-size 32M / --vfs-read-chunk-size-limit 256M
#     Start modest so a 4 KB footer read does not fetch 128 MB, then let the
#     chunk grow when a read really is sequential. The default 128M start is
#     wrong for footer-then-row-group access.
#
# --attr-timeout 1h, --poll-interval 0
#     No change notification is needed for data that cannot change, and
#     polling Drive for changes costs quota.
#
# --drive-pacer-min-sleep 10ms, --drive-pacer-burst 200
#     Drive returns 403 rateLimitExceeded under concurrency; the pacer backs
#     off rather than failing the read.
#
# --read-only
#     Nothing should ever write to the lake. A typo that truncates a child
#     dataset would be silent and permanent.
rclone mount "${REMOTE}:${BUCKET}" "$MOUNT_POINT" \
  --daemon \
  --read-only \
  --allow-other \
  --vfs-cache-mode full \
  --vfs-cache-max-size 8G \
  --vfs-cache-max-age 24h \
  --vfs-read-chunk-size 32M \
  --vfs-read-chunk-size-limit 256M \
  --dir-cache-time 9999h \
  --attr-timeout 1h \
  --poll-interval 0 \
  --buffer-size 32M \
  --drive-pacer-min-sleep 10ms \
  --drive-pacer-burst 200 \
  --cache-dir "$CACHE_DIR" \
  --log-file "$LOG" \
  --log-level INFO

# --daemon returns before the mount is usable, so wait for it rather than
# letting the first request fail. Twenty seconds is generous; a healthy mount
# is ready in two.
for _ in $(seq 1 40); do
  if mountpoint -q "$MOUNT_POINT" && [[ -d "$MOUNT_POINT/children" && -d "$MOUNT_POINT/people" ]]; then
    n=$(ls -1 "$MOUNT_POINT/children" 2>/dev/null | wc -l)
    echo "mounted $MOUNT_POINT  ($n child datasets visible)"
    exit 0
  fi
  sleep 0.5
done

echo "mount did not become usable within 20s; see $LOG" >&2
tail -20 "$LOG" >&2 || true
exit 1
