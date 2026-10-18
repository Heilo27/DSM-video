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
#   - Takes its file list from `dsvideo-backend --list-video-files`, so it only ever
#     touches files the library scanner indexes, and only remuxes H.264 (anything else
#     is logged and left for the backend's worker).
#   - On success: <name>.mp4 is produced, then the original is moved to the backup
#     dir under its path relative to VIDEO_ROOT (never overwriting an existing backup)
#     and stamped with the current time, so the backend's 7-day reaper keeps it.
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
FFPROBE="${DSVIDEO_FFPROBE_PATH:-$(dirname "$FFMPEG")/ffprobe}"
# The server decides which files are videos (TASK-1025): this converts only files the
# library scanner indexes, so it carries no extension list of its own.
BACKEND="${DSVIDEO_BACKEND:-}"
if [ -z "$BACKEND" ]; then
  for p in /var/packages/DSVideoServer/target/backend/dsvideo-backend \
           /var/packages/DSVideoServer/target/bin/dsvideo-backend; do
    [ -x "$p" ] && { BACKEND="$p"; break; }
  done
fi
LOCK_DIR="/tmp/sprint-convert.locks"
LIST="/tmp/sprint-convert.pending"
LOG="/tmp/sprint-convert.log"
WORKERS="${1:-3}"

[ -x "$FFMPEG" ]  || { echo "ffmpeg not found at $FFMPEG (set DSVIDEO_FFMPEG_PATH)"; exit 1; }
[ -x "$FFPROBE" ] || { echo "ffprobe not found at $FFPROBE (set DSVIDEO_FFPROBE_PATH)"; exit 1; }
mkdir -p "$LOCK_DIR" "$BACKUP_DIR"
: > "$LOG"

log(){ echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

# Write the scanner's file list for VIDEO_ROOT (NUL-separated) to $1. Fails loudly rather
# than returning an empty list: a missing backend, one too old to have the flag (it would
# try to start the server instead), or an unreadable root all stop the run.
# (Same contract as list_video_files in tools/convert-library.sh.)
list_video_files() {
  local out="$1"
  [ -n "$BACKEND" ] && [ -x "$BACKEND" ] || { echo "dsvideo-backend not found (set DSVIDEO_BACKEND)"; return 1; }
  grep -q -- '--list-video-files' "$BACKEND" || { echo "$BACKEND predates --list-video-files; update DSVideoServer"; return 1; }
  "$BACKEND" --list-video-files "$VIDEO_ROOT" > "$out" || { echo "listing video files under $VIDEO_ROOT failed"; return 1; }
}

# Build the pending list (NUL-separated): files the scanner indexes that have no converted
# .mp4 sibling (an .mp4 is its own sibling, so it never qualifies) and no in-flight
# .converting temp. The scanner already leaves out the server's _dsvideo_originals tree
# and disc-rip folders; the other two are this script family's own old backup trees.
build_pending() {
  local all="${LIST}.all"
  list_video_files "$all" || exit 1
  while IFS= read -r -d '' f; do
    case "$f" in */_originals_backup/*|*/Movies_backup/*) continue;; esac
    mp4="${f%.*}.mp4"; base=$(basename "$f"); dir=$(dirname "$f")
    [ -f "$mp4" ] && continue
    ls "$dir/.${base%.*}.converting."* >/dev/null 2>&1 && continue
    printf '%s\0' "$f"
  done < "$all" > "$LIST"
  rm -f "$all"
}

convert_one() {
  local f="$1"
  local dir base stem mp4 tmp lock vcodec backup
  dir=$(dirname "$f"); base=$(basename "$f"); stem="${base%.*}"
  mp4="${dir}/${stem}.mp4"
  tmp="${dir}/.${stem}.converting.mp4"
  # Mirror the path under VIDEO_ROOT, as the backend's worker does under its library
  # root: a flat basename let two shows' S01E01.mkv overwrite each other's backup.
  backup="${BACKUP_DIR}/${f#"${VIDEO_ROOT}"/}"
  lock="${LOCK_DIR}/$(echo "$f" | md5sum | cut -d' ' -f1).lock"

  # Atomic claim: exactly one worker wins the mkdir.
  mkdir "$lock" 2>/dev/null || return 0

  # Re-check under lock — the backend may have taken it since the list was built.
  if [ -f "$mp4" ]; then log "SKIP (mp4 exists): $base"; rmdir "$lock"; return 0; fi
  if ls "${dir}/.${stem}.converting."* >/dev/null 2>&1; then log "SKIP (backend in-flight): $base"; rmdir "$lock"; return 0; fi
  if [ ! -f "$f" ]; then log "SKIP (gone): $base"; rmdir "$lock"; return 0; fi
  if [ -e "$backup" ]; then log "SKIP (a backup already exists at $backup): $base"; rmdir "$lock"; return 0; fi
  # Stream copy is only right for H.264. Anything else needs a re-encode, or (HEVC) the
  # backend's hvc1 relabel; leave those to the backend's own worker.
  vcodec=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name \
             -of default=nw=1:nk=1 "$f" 2>/dev/null | head -1)
  if [ "$vcodec" != "h264" ]; then log "SKIP (video is '${vcodec:-unreadable}', not h264; left for the backend): $base"; rmdir "$lock"; return 0; fi

  log "START: $f"
  # The backend's h264 remux command: stream-copy video, AAC audio, faststart.
  if "$FFMPEG" -nostdin -y -fflags +genpts+igndts -i "$f" \
       -map 0:v:0 -map 0:a:0? -c:v copy -c:a aac -b:a 192k -ac 2 \
       -movflags +faststart -avoid_negative_ts make_zero "$tmp" >> "$LOG" 2>&1; then
    if [ -s "$tmp" ] && [ "$(stat -c%s "$tmp")" -gt 100000 ]; then
      # Never replace a file that appeared at the target while ffmpeg ran. mv -n can exit 0
      # without moving, so the proof is that the temp is gone.
      mv -n "$tmp" "$mp4"
      if [ -e "$tmp" ]; then
        log "FAIL (a file appeared at $mp4 during conversion; not replacing it, original untouched): $base"
        rm -f "$tmp"; rmdir "$lock"; return 0
      fi
      mkdir -p "$(dirname "$backup")"
      mv -n "$f" "$backup"
      if [ -e "$f" ]; then
        # Never overwrite a backup; leave the original where it is for a person to sort out.
        log "FAIL (mp4 made, but the original could not be archived to $backup; it is still in place): $base"
      else
        # The backend's retention reaper deletes backups by mtime; stamp it now, as the
        # backend does, or an old original is reaped within the hour instead of in 7 days.
        touch "$backup"
        log "DONE: $base  -> mp4 + original archived at $backup"
      fi
    else
      log "FAIL (tiny/empty output): $base"; rm -f "$tmp"
    fi
  else
    log "FAIL (ffmpeg error — likely corrupt/partial source): $base"; rm -f "$tmp"
  fi
  rmdir "$lock"
}
export -f convert_one log
export LOCK_DIR BACKUP_DIR FFMPEG FFPROBE LOG VIDEO_ROOT

build_pending
n=$(tr -cd '\0' < "$LIST" | wc -c)
log "=== sprint-convert starting: $WORKERS workers, $n candidate(s) ==="
if [ "$n" -eq 0 ]; then log "nothing to convert — exiting"; echo "Nothing pending."; exit 0; fi

xargs -0 -P "$WORKERS" -I {} bash -c 'convert_one "$@"' _ {} < "$LIST"

done_n=$(grep -c "DONE:" "$LOG"); fail_n=$(grep -c "FAIL" "$LOG")
log "=== sprint-convert COMPLETE: ${done_n} converted, ${fail_n} failed ==="
echo "Sprint complete: ${done_n} converted, ${fail_n} failed (see $LOG)."
