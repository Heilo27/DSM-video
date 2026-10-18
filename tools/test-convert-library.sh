#!/bin/bash
# Behavioural check for tools/convert-library.sh (TASK-1032, TASK-1033).
# Runs the real script against real ffmpeg on tiny generated clips, with a stub backend that
# answers --list-video-files. Needs ffmpeg with libx264 and libx265 on PATH (or FFMPEG/FFPROBE).
#
#   bash tools/test-convert-library.sh [path/to/convert-library.sh]
#
# Covers: a backup already in the slot is never overwritten; a backup that cannot be written
# aborts the conversion with the original intact; a different file already at the target is
# never replaced; HEVC remuxes are tagged hvc1 and H.264 is not.
set -u
SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/convert-library.sh}"
REAL="${FFMPEG:-$(command -v ffmpeg)}"
PROBE="${FFPROBE:-$(command -v ffprobe)}"
[ -x "$REAL" ] && [ -x "$PROBE" ] || { echo "ffmpeg/ffprobe not found"; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/convert-library-test.XXXXXX")"
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

cat > "$W/backend" <<'EOF'
#!/bin/sh
# Stub of `dsvideo-backend --list-video-files <roots...>`.
shift
find "$@" -type f \( -name '*.mkv' -o -name '*.mp4' \) ! -name '.*' -print0
EOF
chmod +x "$W/backend"
cat > "$W/ffmpeg" <<EOF
#!/bin/sh
echo "\$@" >> "$W/ffmpeg.args"
exec "$REAL" "\$@"
EOF
chmod +x "$W/ffmpeg"

mk() { # mk <file> <video encoder>
  "$REAL" -v error -y -f lavfi -i testsrc=size=320x240:rate=24:duration=2 -f lavfi -i sine=duration=2 \
    -c:v "$2" -pix_fmt yuv420p -c:a ac3 -shortest "$1"
}
run() { # run "<roots>"
  ROOTS="$1" BACKUP_DIR="$W/backup" LOG="$W/log" FFMPEG="$W/ffmpeg" FFPROBE="$PROBE" DSVIDEO_BACKEND="$W/backend" \
    bash "$SCRIPT" >/dev/null 2>&1
}
tagof() { "$PROBE" -v error -select_streams v:0 -show_entries stream=codec_tag_string -of csv=p=0 "$1"; }

# 1. HEVC and H.264 sources; a backup already sits in the HEVC original's slot.
mkdir -p "$W/m/Movies" "$W/m/Shows"
mk "$W/m/Movies/hevc.mkv" libx265
mk "$W/m/Shows/h264.mkv" libx264
SLOT="$W/backup${W}/m/Movies/hevc.mkv"
mkdir -p "$(dirname "$SLOT")"
echo "PRE-EXISTING BACKUP" > "$SLOT"
cp "$W/m/Movies/hevc.mkv" "$W/hevc.orig"
run "$W/m/Movies $W/m/Shows"

[ "$(cat "$SLOT")" = "PRE-EXISTING BACKUP" ] && ok "pre-existing backup untouched" || bad "pre-existing backup overwritten"
cmp -s "$W/hevc.orig" "${SLOT%.mkv}.1.mkv" && ok "original filed under the .1 name" || bad "original not filed at .1"
{ [ -f "$W/m/Movies/hevc.mp4" ] && [ ! -e "$W/m/Movies/hevc.mkv" ]; } && ok "hevc converted, original moved" || bad "hevc conversion state wrong"
[ "$(tagof "$W/m/Movies/hevc.mp4")" = "hvc1" ] && ok "hevc output tagged hvc1" || bad "hevc tag is $(tagof "$W/m/Movies/hevc.mp4")"
[ "$(tagof "$W/m/Shows/h264.mp4")" = "avc1" ] && ok "h264 output stays avc1" || bad "h264 tag is $(tagof "$W/m/Shows/h264.mp4")"
[ "$(grep -c 'tag:v hvc1' "$W/ffmpeg.args")" = "1" ] && ok "-tag:v passed once, for hevc only" || bad "tag:v count: $(grep -c 'tag:v' "$W/ffmpeg.args")"

# 2. The backup cannot be written: abort, original intact, nothing swapped in.
rm -rf "$W/backup" "$W/m"; mkdir -p "$W/m/Movies"
mk "$W/m/Movies/x.mkv" libx264
cp "$W/m/Movies/x.mkv" "$W/x.orig"
mkdir -p "$W/backup"; chmod 555 "$W/backup"
run "$W/m/Movies"
chmod 755 "$W/backup"
cmp -s "$W/x.orig" "$W/m/Movies/x.mkv" && ok "unwritable backup: original untouched" || bad "unwritable backup: original changed or missing"
[ ! -e "$W/m/Movies/x.mp4" ] && ok "unwritable backup: no mp4 swapped in" || bad "unwritable backup: mp4 present"
ls "$W/m/Movies"/.*.converting.mp4 >/dev/null 2>&1 && bad "temp file left behind" || ok "no temp file left behind"

# 3. A different file already at the target is never replaced.
rm -rf "$W/backup" "$W/m"; mkdir -p "$W/m/Movies"
mk "$W/m/Movies/y.mkv" libx264
echo "NOT A VIDEO" > "$W/m/Movies/y.mp4"
run "$W/m/Movies"
[ "$(cat "$W/m/Movies/y.mp4")" = "NOT A VIDEO" ] && ok "existing target not replaced" || bad "existing target replaced"
[ -f "$W/m/Movies/y.mkv" ] && ok "original kept when the target is taken" || bad "original lost"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
