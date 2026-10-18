#!/bin/bash
# convert-library.sh — one-time library normalisation for DSVideoServer.
#
# Goal: make every video DirectPlay-eligible (MP4 + H.264/HEVC + AAC) so the
# server never has to transcode on playback. Two actions, chosen per file:
#
#   REMUX     video is already H.264/HEVC but the container/audio is wrong.
#             Copy the video stream untouched, convert audio to AAC, repackage
#             to MP4. Fast (no video re-encode), lossless video.
#
#   ENCODE    video is mpeg4/XVID/etc and must be re-encoded to H.264. Slow on a
#             CPU-only NAS (libx264). Capped at 720p to stay sane.
#
# Files that already DirectPlay are skipped.
#
# Safety:
#   - Originals are NEVER deleted. After a verified conversion the original is
#     MOVED to a sibling backup tree under $BACKUP_DIR (same relative path).
#   - Nothing is ever overwritten. A taken backup slot gets a "<name>.<n>.<ext>"
#     name, a failed backup aborts the conversion, and the converted file is only
#     moved into place with `mv -n`.
#   - Output is written to a .tmp file, validated with ffprobe, and only then
#     swapped in. A failed/partial conversion leaves the original in place.
#   - Resumable: if the target .mp4 already exists and probes valid, the file is
#     skipped. Safe to Ctrl-C and re-run; it picks up where it left off.
#   - One ffmpeg at a time by default (the NAS has 4 cores; concurrency would
#     starve any live playback). Raise JOBS only if nobody is watching.
#
# Usage:
#   ./convert-library.sh                 # convert everything (remux + encode)
#   MODE=remux ./convert-library.sh      # only the fast remuxes
#   MODE=encode ./convert-library.sh     # only the slow re-encodes
#   ROOTS="/volume1/video/Shows" ./convert-library.sh   # limit scope
#
set -uo pipefail

# ---- config (override via env) ---------------------------------------------
ROOTS="${ROOTS:-/volume1/video/Shows /volume1/video/Movies}"
BACKUP_DIR="${BACKUP_DIR:-/volume1/video/_originals_backup}"
LOG="${LOG:-/volume1/video/convert-library.log}"
MODE="${MODE:-all}"            # all | remux | encode
MAX_HEIGHT="${MAX_HEIGHT:-720}"   # cap for re-encodes
AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"
CRF="${CRF:-21}"
PRESET="${PRESET:-veryfast}"  # ultrafast..veryslow; veryfast is a good NAS tradeoff

# Prefer the server's bundled ffmpeg/ffprobe (6.1.x) over the OS one (4.1.9).
find_bin() {
  local name="$1"
  for p in \
    "/volume1/@appstore/DSVideoServer/bin/$name" \
    "/var/packages/DSVideoServer/target/bin/$name" \
    "/var/packages/DSVideoServer/target/backend/$name" \
    "/var/packages/ffmpeg/target/bin/$name" \
    "/usr/local/bin/$name" \
    "/usr/bin/$name"; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
FFMPEG="${FFMPEG:-$(find_bin ffmpeg)}"
FFPROBE="${FFPROBE:-$(find_bin ffprobe)}"
# The server decides which files are videos (TASK-1025): this script converts exactly
# what the library scanner indexes, so it carries no extension list of its own.
BACKEND="${DSVIDEO_BACKEND:-$(find_bin dsvideo-backend)}"

# ---- helpers ----------------------------------------------------------------
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

# Container-compatible extensions we consider "MP4 family".
is_mp4_container() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in mp4|mov|m4v) return 0;; *) return 1;; esac; }

# probe one stream property: probe_field <file> <stream> <entry>
#   stream: v:0 | a:0   entry: codec_name | codec_type
probe_field() {
  "$FFPROBE" -v error -select_streams "$2" -show_entries "stream=$3" \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1
}

# Decide action for a file: prints "skip" | "remux" | "encode"
decide() {
  local f="$1" ext vcodec acodec
  ext="${f##*.}"
  vcodec="$(probe_field "$f" v:0 codec_name)"
  acodec="$(probe_field "$f" a:0 codec_name)"
  [ -z "$vcodec" ] && { echo "skip"; return; }   # not a video / unreadable

  local v_ok=0 a_ok=0 c_ok=0
  case "$vcodec" in h264|hevc) v_ok=1;; esac
  case "$acodec" in aac|mp3|"") a_ok=1;; esac      # no audio stream is fine
  is_mp4_container "$ext" && c_ok=1

  if [ "$v_ok" = 1 ] && [ "$a_ok" = 1 ] && [ "$c_ok" = 1 ]; then echo "skip"; return; fi
  if [ "$v_ok" = 1 ]; then echo "remux"; else echo "encode"; fi
}

# Verify a produced file is a sane, playable MP4 with the expected video codec.
verify_out() {
  local out="$1"
  [ -s "$out" ] || return 1
  local vc; vc="$(probe_field "$out" v:0 codec_name)"
  case "$vc" in h264|hevc) ;; *) return 1;; esac
  # duration must be > 0
  local dur; dur="$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$out" 2>/dev/null | head -1)"
  awk "BEGIN{exit !($dur > 0)}" 2>/dev/null || return 1
  return 0
}

# Move the original into the backup tree (absolute path minus the leading slash), NEVER
# overwriting. The tree is shared with the server's worker and sprint-convert.sh, and a
# backup is the only copy of the original once the converted file replaces it. If the slot
# is taken (a previous run, another library, a restored file) the original is filed under
# "<name>.<n>.<ext>" instead. `mv -n` can exit 0 without moving anything when the target
# exists, so success means the source is gone AND the destination exists.
# On success sets BACKED_UP_AT to the final path and returns 0; on failure the original is
# still at $src and the return is non-zero.
BACKED_UP_AT=""
backup_original() {
  local src="$1" rel preferred cand n=0 rc
  BACKED_UP_AT=""
  rel="${src#/}"                       # strip leading slash
  preferred="$BACKUP_DIR/$rel"
  mkdir -p "$(dirname "$preferred")" || return 1
  cand="$preferred"
  while [ "$n" -lt 1000 ]; do
    if [ ! -e "$cand" ] && [ ! -L "$cand" ]; then
      mv -n "$src" "$cand"; rc=$?
      if [ "$rc" -eq 0 ] && [ ! -e "$src" ] && [ -e "$cand" ]; then
        BACKED_UP_AT="$cand"
        return 0
      fi
      # Source still here: either a real failure (permissions, disk) or something took the
      # slot between the check and the move. Only the latter is worth another slot.
      [ "$rc" -ne 0 ] && return 1
    fi
    n=$((n + 1))
    cand="${preferred%.*}.$n.${preferred##*.}"
  done
  return 1
}

convert_one() {
  local src="$1" action="$2"
  local dir base stem out tmp
  dir="$(dirname "$src")"
  base="$(basename "$src")"
  stem="${base%.*}"
  out="$dir/$stem.mp4"
  tmp="$dir/.$stem.converting.mp4"

  # Resume: a valid target already exists (and isn't the source itself).
  if [ "$out" != "$src" ] && [ -f "$out" ] && verify_out "$out"; then
    log "SKIP (already converted): $src"
    return 0
  fi

  # The target name is held by a file that is not the (valid, converted) output we skip
  # above and is not the source itself: never replace it. The swap below uses mv -n as well,
  # this just avoids a wasted conversion.
  if [ "$out" != "$src" ] && [ -e "$out" ]; then
    log "FAIL (target exists but is not a valid conversion: $out) — not replacing it, original untouched: $src"
    return 1
  fi

  rm -f "$tmp"

  if [ "$action" = "remux" ]; then
    # Copy video, transcode audio to AAC, repackage to MP4. faststart moves the
    # moov atom to the front for instant streaming. genpts+igndts repairs the
    # broken DTS some MKVs carry (same flags the server uses).
    #
    # HEVC must be tagged hvc1. ffmpeg writes hev1 when it copies HEVC into MP4, and Apple
    # players (AVFoundation) will not initialise a decoder from it: audio plays and the
    # picture stays black. -tag:v only for HEVC; it is wrong for any other codec.
    local -a tag_args=()
    [ "$(probe_field "$src" v:0 codec_name)" = "hevc" ] && tag_args=(-tag:v hvc1)
    "$FFMPEG" -nostdin -y -fflags +genpts+igndts -i "$src" \
      -map 0:v:0 -map 0:a:0? \
      -c:v copy ${tag_args[@]+"${tag_args[@]}"} -c:a aac -b:a "$AUDIO_BITRATE" -ac 2 \
      -movflags +faststart -avoid_negative_ts make_zero \
      "$tmp" >>"$LOG" 2>&1 </dev/null
  else
    # Full re-encode to H.264, capped at MAX_HEIGHT, never upscaling.
    "$FFMPEG" -nostdin -y -fflags +genpts -i "$src" \
      -map 0:v:0 -map 0:a:0? \
      -vf "scale=-2:min(ih\,$MAX_HEIGHT)" \
      -c:v libx264 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p \
      -c:a aac -b:a "$AUDIO_BITRATE" -ac 2 \
      -movflags +faststart -avoid_negative_ts make_zero \
      "$tmp" >>"$LOG" 2>&1 </dev/null
  fi
  local rc=$?

  if [ $rc -ne 0 ] || ! verify_out "$tmp"; then
    log "FAIL ($action, rc=$rc): $src — leaving original untouched"
    rm -f "$tmp"
    return 1
  fi

  # Success: back up the original, then swap in the new file. If the original cannot be
  # backed up, stop: the converted file must never be moved over the only copy.
  if ! backup_original "$src"; then
    log "FAIL (could not back up the original; leaving it and discarding the conversion): $src"
    rm -f "$tmp"
    return 1
  fi
  # mv -n so nothing already at $out is replaced; it can exit 0 without moving, so the
  # proof of success is that the temp is gone. On failure put the original back.
  mv -n "$tmp" "$out"
  if [ -e "$tmp" ]; then
    log "FAIL (could not place $out; restoring the original): $src"
    rm -f "$tmp"
    if [ -e "$src" ] || ! mv -n "$BACKED_UP_AT" "$src" || [ -e "$BACKED_UP_AT" ]; then
      log "ERROR: original NOT restored, it is safe at $BACKED_UP_AT (wanted $src)"
    fi
    return 1
  fi
  log "OK ($action): $src -> $out (original kept at $BACKED_UP_AT)"
  return 0
}

# Write the scanner's file list for ROOTS (NUL-separated) to $1. Fails loudly rather than
# returning an empty list: a missing backend, one too old to have the flag (it would try
# to start the server instead), or an unreadable root all stop the run.
# (Same contract as list_video_files in scripts/sprint-convert.sh.)
list_video_files() {
  local out="$1"
  [ -n "$BACKEND" ] && [ -x "$BACKEND" ] || { echo "dsvideo-backend not found (set DSVIDEO_BACKEND)"; return 1; }
  grep -q -- '--list-video-files' "$BACKEND" || { echo "$BACKEND predates --list-video-files; update DSVideoServer"; return 1; }
  # shellcheck disable=SC2086  # ROOTS is a space-separated list, split on purpose
  "$BACKEND" --list-video-files $ROOTS > "$out" || { echo "listing video files under $ROOTS failed"; return 1; }
}

# ---- main -------------------------------------------------------------------
[ -n "$FFMPEG" ]  || { echo "ffmpeg not found"; exit 1; }
[ -n "$FFPROBE" ] || { echo "ffprobe not found"; exit 1; }
FILE_LIST="$(mktemp "${TMPDIR:-/tmp}/convert-library.XXXXXX")" || exit 1
trap 'rm -f "$FILE_LIST"' EXIT
list_video_files "$FILE_LIST" || exit 1
mkdir -p "$BACKUP_DIR"
: > "$LOG" 2>/dev/null || true

log "=== convert-library start ==="
log "ffmpeg=$FFMPEG backend=$BACKEND"
log "mode=$MODE roots=$ROOTS backup=$BACKUP_DIR max_height=$MAX_HEIGHT preset=$PRESET crf=$CRF"

declare -i n_skip=0 n_remux=0 n_encode=0 n_fail=0 n_total=0

# Every file the library scanner indexes under the roots (disc-rip folders, conversion
# temps and the server's backup tree are already left out by the scanner's own rules).
while IFS= read -r -d '' f; do
  n_total+=1
  # Skip our own temp/backup artifacts.
  case "$f" in
    "$BACKUP_DIR"/*) continue;;
    */.*.converting.mp4) continue;;
  esac

  action="$(decide "$f")"

  case "$action" in
    skip)  n_skip+=1; continue;;
    remux) [ "$MODE" = "encode" ] && { continue; }; ;;
    encode) [ "$MODE" = "remux" ] && { continue; }; ;;
  esac

  log "PLAN $action: $f"
  if convert_one "$f" "$action"; then
    [ "$action" = "remux" ] && n_remux+=1 || n_encode+=1
  else
    n_fail+=1
  fi
done < "$FILE_LIST"

log "=== done: scanned=$n_total skipped=$n_skip remuxed=$n_remux encoded=$n_encode failed=$n_fail ==="
log "Originals preserved under: $BACKUP_DIR"
log "After confirming playback, reclaim space with:  rm -rf '$BACKUP_DIR'"
log "Then rescan the library in the app so the DB picks up the new .mp4 files."
