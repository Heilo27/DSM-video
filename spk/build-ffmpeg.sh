#!/bin/bash
# TASK-750: build a VAAPI-enabled static ffmpeg/ffprobe for the SPK and drop the
# binaries into the package's bin/ dir so hardware transcode + trick-play engage.
#
# Run this once before build-spk.sh (or whenever you want to refresh ffmpeg). The
# binaries are committed into DSVideoServer/bin/ so a normal package build doesn't
# need Docker every time.
#
#   ./build-ffmpeg.sh          # builds and installs into DSVideoServer/bin/
#
# Requires Docker with BuildKit (for the scratch export stage).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_BIN="$SCRIPT_DIR/DSVideoServer/bin"
OUT_DIR="$SCRIPT_DIR/ffmpeg-out"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Building VAAPI-enabled ffmpeg for DSVideoServer (x86_64)"
echo "═══════════════════════════════════════════════════════════════════════════════"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found. Install Docker Desktop and retry." >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# BuildKit's --output writes the 'export' (scratch) stage straight to the host.
echo "🔨 Building ffmpeg in Docker (this takes several minutes)..."
DOCKER_BUILDKIT=1 docker build \
  --platform linux/amd64 \
  -f "$SCRIPT_DIR/Dockerfile.ffmpeg" \
  --target export \
  --output "type=local,dest=$OUT_DIR" \
  "$SCRIPT_DIR"

if [ ! -x "$OUT_DIR/out/ffmpeg" ] || [ ! -x "$OUT_DIR/out/ffprobe" ]; then
  echo "ERROR: ffmpeg/ffprobe not produced by the Docker build." >&2
  exit 1
fi

mkdir -p "$PKG_BIN"
cp "$OUT_DIR/out/ffmpeg" "$PKG_BIN/ffmpeg"
cp "$OUT_DIR/out/ffprobe" "$PKG_BIN/ffprobe"
chmod +x "$PKG_BIN/ffmpeg" "$PKG_BIN/ffprobe"
rm -rf "$OUT_DIR"

echo ""
echo "✅ Installed VAAPI ffmpeg into: $PKG_BIN"
echo "   $("$PKG_BIN/ffmpeg" -version 2>/dev/null | head -1 || echo 'ffmpeg (cross-built; cannot run on this host)')"
echo ""
echo "Next: run ./build-spk.sh amd64 to package it."
