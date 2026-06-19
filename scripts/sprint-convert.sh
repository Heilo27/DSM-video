#!/bin/bash
# sprint-convert.sh — manual "sprint mode" for DSVideoServer bulk conversions.
#
# WHAT IT DOES
#   Drains the pending normalization queue in PARALLEL, using the backend's EXACT
#   ffmpeg command and backup behavior. Use it after dropping a large batch of new
#   videos on the NAS, when you want the queue cleared in minutes instead of the
#   backend's deliberate one-at-a-time overnight pace.
#
# WHY IT'S SAFE TO RUN ALONGSIDE THE BACKEND
#   - Each file is claimed with an atomic mkdir lock, then RE-CHECKED under lock,
#     so this never collides with the backend or its own sibling workers.
#   - Skips any file that already has a converted .mp4, or a .converting.* temp
#     in flight (the backend's marker).
#   - On success: <name>.mp4 is produced, then the original is moved to the backup
#     dir — mirroring the backend's pipeline exactly.
#   - On ANY ffmpeg failure (e.g. a truncated/partial download with a zeroed
#     header), the original is left untouched. No data loss.
#
# IMPORTANT — WHEN *NOT* TO USE
#   This runs ffmpeg with -c:v copy (stream remux): cheap, near-zero CPU/RAM, safe
#   to parallelize. It does NOT handle libx264 re-encode jobs (downscaling >maxHeight
#   content), which are heavy — running several of those at once OOM-killed this NAS
#   historically (see backend/internal/transcode/limiter.go, TASK-752). If your batch
#   needs real re-encoding (4K/1080p sources being downscaled), let the backend do it
#   serially instead. For the common case — h264 .mkv/.avi just being remuxed to
#   faststart .mp4 — this is the fast path.
#
# USAGE (run on the NAS, or via ssh):
#   bash sprint-convert.sh [WORKERS]
#     WORKERS  number of parallel ffmpeg jobs (default 3). The box has 4 threads;
#              3 leaves headroom for the backend's own job. Use 4 to fully saturate
#              when nothing else needs the NAS (no streaming/builds).
#
#   Watch progress:  tail -f /tmp/sprint-convert.log | grep -E 'DONE|FAIL|COMPLETE'
#
set -u

VIDEO_ROOT="${DSVIDEO_VIDEO_ROOT:-/volume1/video}"
BACKUP_DIR="${VIDEO_ROOT}/_dsvideo_originals"
FFMPEG="${DSVIDEO_FFMPEG_PATH:-/var/packages/DSVideoServer/target/bin/ffmpeg}"
LOCK_DIR="/tmp/sprint-convert.locks"
LIST="/tmp/sprint-convert.pending"
LOG="/tmp/sprint-convert.log"
WORKERS="${1:-3}"

mkdir -p "$LOCK_DIR" "$BACKUP_DIR"
: > "$LOG"

log(){ echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

# Build the pending list: raw video files with no converted .mp4 sibling and no
# in-flight .converting temp, excluding the backup trees.
build_pending() {
  cd "$VIDEO_ROOT" || exit 1
  find . -type f \
      \( -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" \
         -o -iname "*.ts" -o -iname "*.wmv" -o -iname "*.flv" \) \
      -not -path "*/_dsvideo_originals/*" \
      -not -path "*/_originals_backup/*" \
      -not -path "*/Movies_backup/*" 2>/dev/null | \
  while IFS= read -r f; do
    mp4="${f%.*}.mp4"; base=$(basename "$f"); dir=$(dirname "$f")
    [ -f "$mp4" ] && continue
    ls "$dir/.${base%.*}.converting."* >/dev/null 2>&1 && continue
    # emit absolute path
    echo "${VIDEO_ROOT}/${f#./}"
  done > "$LIST"
}

convert_one() {
  local f="$1"
  local dir base stem mp4 tmp lock
  dir=$(dirname "$f"); base=$(basename "$f"); stem="${base%.*}"
  mp4="${dir}/${stem}.mp4"
  tmp="${dir}/.${stem}.converting.mp4"
  lock="${LOCK_DIR}/$(echo "$f" | md5sum | cut -d' ' -f1).lock"

  # Atomic claim: exactly one worker wins the mkdir.
  mkdir "$lock" 2>/dev/null || return 0

  # Re-check under lock — the backend may have taken it since the list was built.
  if [ -f "$mp4" ]; then log "SKIP (mp4 exists): $base"; rmdir "$lock"; return 0; fi
  if ls "${dir}/.${stem}.converting."* >/dev/null 2>&1; then log "SKIP (backend in-flight): $base"; rmdir "$lock"; return 0; fi
  if [ ! -f "$f" ]; then log "SKIP (gone): $base"; rmdir "$lock"; return 0; fi

  log "START: $f"
  # EXACT backend remux command: stream-copy video, AAC audio, faststart.
  if "$FFMPEG" -nostdin -y -fflags +genpts+igndts -i "$f" \
       -map 0:v:0 -map 0:a:0? -c:v copy -c:a aac -b:a 192k -ac 2 \
       -movflags +faststart -avoid_negative_ts make_zero "$tmp" >> "$LOG" 2>&1; then
    if [ -s "$tmp" ] && [ "$(stat -c%s "$tmp")" -gt 100000 ]; then
      mv "$tmp" "$mp4"
      mv "$f" "${BACKUP_DIR}/${base}"
      log "DONE: $base  -> mp4 + original archived"
    else
      log "FAIL (tiny/empty output): $base"; rm -f "$tmp"
    fi
  else
    log "FAIL (ffmpeg error — likely corrupt/partial source): $base"; rm -f "$tmp"
  fi
  rmdir "$lock"
}
export -f convert_one log
export LOCK_DIR BACKUP_DIR FFMPEG LOG

build_pending
n=$(wc -l < "$LIST")
log "=== sprint-convert starting: $WORKERS workers, $n candidate(s) ==="
if [ "$n" -eq 0 ]; then log "nothing to convert — exiting"; echo "Nothing pending."; exit 0; fi

xargs -d '\n' -P "$WORKERS" -I {} bash -c 'convert_one "$@"' _ {} < "$LIST"

done_n=$(grep -c "DONE:" "$LOG"); fail_n=$(grep -c "FAIL" "$LOG")
log "=== sprint-convert COMPLETE: ${done_n} converted, ${fail_n} failed ==="
echo "Sprint complete: ${done_n} converted, ${fail_n} failed (see $LOG)."
