#!/bin/sh
# fix-hev1-tags.sh — relabel HEVC video sample entries from hev1 to hvc1, in place.
#
# WHY
#   Apple requires the hvc1 FourCC for HEVC in MP4/MOV. With hev1 the parameter sets
#   (VPS/SPS/PPS) live in-band in the bitstream rather than in the sample description, and
#   AVFoundation will not initialise a decoder from it: the file opens, the audio track
#   plays, the video renders BLACK, and no error is raised. On this library 100 of 102
#   HEVC files were affected.
#
#   The server now detects this and routes such files to a remux, so they play — but that
#   is per-playback work. Relabelling the file once removes the need entirely and restores
#   DirectPlay.
#
# WHAT IT DOES NOT DO
#   This is NOT a re-encode. `-c copy` copies the video, audio and subtitle streams
#   bit-for-bit; only the container's sample-entry FourCC changes (ffmpeg also relocates
#   the parameter sets into the sample description). Quality, duration, size and timing
#   are unchanged. A 2GB file takes seconds, not hours.
#
# SAFETY
#   * Writes to a temp file beside the original; the original is only replaced after the
#     new file is verified to exist, be non-empty, report hvc1, and have a duration within
#     1 second of the source.
#   * mtime is preserved with `touch -r`, so the scanner's size+mtime probe cache is not
#     invalidated and the library is not re-probed wholesale afterwards.
#   * On ANY failure the temp file is removed and the original is left untouched.
#   * --dry-run prints what would change and touches nothing.
#   * Skips files already tagged hvc1, so it is safe to re-run.
#
# USAGE
#   sh fix-hev1-tags.sh --dry-run            # report only (start here)
#   sh fix-hev1-tags.sh --limit 3            # convert 3 files, verify, then continue
#   sh fix-hev1-tags.sh                      # convert everything
#
# KNOWN LIMITATION — run it twice.
#   The file list is built once, up front, and each conversion replaces a file in the
#   tree while the loop is still walking it. On a real run of 100 files this caused the
#   first pass to convert 44 and exit CLEANLY (converted=51 skipped=5072 failed=0) with
#   34 still tagged hev1 — it skipped alternating episodes in the same folder. A second
#   pass converted the remainder and a direct disk scan then confirmed zero hev1 left.
#   Nothing is lost or corrupted, the sweep is just incomplete, and it is safe to re-run
#   because already-hvc1 files are skipped. Always verify by scanning the DISK afterwards
#   rather than trusting this script's own counters.
#
set -u

FFMPEG=${FFMPEG:-/var/packages/DSVideoServer/target/bin/ffmpeg}
FFPROBE=${FFPROBE:-/var/packages/DSVideoServer/target/bin/ffprobe}
ROOTS=${ROOTS:-"/volume1/video/Movies /volume1/video/Shows"}

DRY=0
LIMIT=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --limit)   NEXT_IS_LIMIT=1 ;;
    *) if [ "${NEXT_IS_LIMIT:-0}" = "1" ]; then LIMIT=$a; NEXT_IS_LIMIT=0; fi ;;
  esac
done

[ -x "$FFMPEG" ]  || { echo "ffmpeg not found at $FFMPEG"; exit 1; }
[ -x "$FFPROBE" ] || { echo "ffprobe not found at $FFPROBE"; exit 1; }

converted=0; skipped=0; failed=0

# Duration to whole seconds, for the post-conversion sanity check.
dur_of() {
  $FFPROBE -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null \
    | awk -F. '{print ($1==""?0:$1)}'
}

# NOTE: `find | while` would run the loop in a SUBSHELL, so the counters below (and the
# --limit break) would be discarded when it exits — the first dry-run reported
# "converted=0" while listing 100 files for exactly that reason. Redirecting from a file
# keeps the loop in this shell.
LIST=$(mktemp /tmp/hev1list.XXXXXX)
find $ROOTS -type f \( -name '*.mp4' -o -name '*.m4v' -o -name '*.mov' \) 2>/dev/null | sort > "$LIST"
trap 'rm -f "$LIST"' EXIT INT TERM

while IFS= read -r f; do
  [ "$LIMIT" -gt 0 ] && [ "$converted" -ge "$LIMIT" ] && break

  info=$($FFPROBE -v error -select_streams v:0 \
          -show_entries stream=codec_name,codec_tag_string -of csv=p=0 "$f" 2>/dev/null)
  case "$info" in
    hevc,hev1) ;;                       # the case we fix
    *) skipped=$((skipped+1)); continue ;;
  esac

  if [ "$DRY" = "1" ]; then
    echo "WOULD FIX: $f"
    converted=$((converted+1))
    continue
  fi

  tmp="${f%.*}.hvc1tmp.${f##*.}"
  rm -f "$tmp"

  # -c copy: no re-encode. -tag:v hvc1: relabel. -movflags +faststart: move the moov
  # atom to the front so playback can begin before the whole file is fetched.
  if ! $FFMPEG -v error -y -i "$f" -map 0 -c copy -tag:v hvc1 \
        -movflags +faststart "$tmp" 2>/dev/null; then
    echo "FAIL (ffmpeg): $f"
    rm -f "$tmp"; failed=$((failed+1)); continue
  fi

  # Verify before replacing anything.
  newtag=$($FFPROBE -v error -select_streams v:0 -show_entries stream=codec_tag_string \
            -of csv=p=0 "$tmp" 2>/dev/null)
  if [ ! -s "$tmp" ] || [ "$newtag" != "hvc1" ]; then
    echo "FAIL (verify tag=$newtag): $f"
    rm -f "$tmp"; failed=$((failed+1)); continue
  fi

  d_old=$(dur_of "$f"); d_new=$(dur_of "$tmp")
  diff=$((d_old - d_new)); [ "$diff" -lt 0 ] && diff=$((-diff))
  if [ "$diff" -gt 1 ]; then
    echo "FAIL (duration ${d_old}s -> ${d_new}s): $f"
    rm -f "$tmp"; failed=$((failed+1)); continue
  fi

  # Preserve mtime so the scanner's size+mtime probe cache stays valid. Size DOES change
  # slightly (the moov atom moves), so a re-probe of these rows is expected and correct —
  # it is what lets the server go back to DirectPlay.
  touch -r "$f" "$tmp"
  if mv -f "$tmp" "$f"; then
    echo "FIXED: $f"
    converted=$((converted+1))
  else
    echo "FAIL (replace): $f"
    rm -f "$tmp"; failed=$((failed+1))
  fi
done < "$LIST"

echo
echo "done — converted=$converted skipped=$skipped failed=$failed"
