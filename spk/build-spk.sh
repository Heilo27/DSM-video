#!/bin/bash
# Build SPK package for Synology NAS
# This script cross-compiles the Go backend and prepares the SPK structure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPK_DIR="$SCRIPT_DIR/DSVideoServer"
BUILD_DIR="$REPO_ROOT/build/spk"
TARGET_DIR="$BUILD_DIR/DSVideoServer"

# Ensure Go is in PATH
export PATH="$PATH:/usr/local/go/bin"

# Detect architecture from argument or default to arm64
ARCH="${1:-arm64}"
case "$ARCH" in
  arm64|aarch64)
    GOOS=linux
    GOARCH=arm64
    SPK_ARCH="armv8"
    ;;
  amd64|x86_64)
    GOOS=linux
    GOARCH=amd64
    SPK_ARCH="x64"
    ;;
  *)
    echo "Unknown architecture: $ARCH"
    echo "Usage: $0 [arm64|amd64]"
    exit 1
    ;;
esac

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Building SPK for Synology NAS (${SPK_ARCH})"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$TARGET_DIR"

# Copy SPK structure
echo "📦 Copying SPK structure..."
cp -r "$SPK_DIR"/* "$TARGET_DIR/"

# Build Go backend for target architecture
echo "🔨 Cross-compiling Go backend for ${GOOS}/${GOARCH}..."
cd "$REPO_ROOT/backend"
GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED=0 go build -ldflags="-s -w" -o "$TARGET_DIR/target/backend/dsvideo-backend" ./cmd/dsvideo-backend

# Make binary executable
chmod +x "$TARGET_DIR/target/backend/dsvideo-backend"

# Create package structure
mkdir -p "$TARGET_DIR/target/backend"
mkdir -p "$TARGET_DIR/var"

echo ""
echo "✅ SPK structure prepared at: $TARGET_DIR"
echo ""
echo "📋 Next steps:"
echo "   1. Review SPK contents: ls -R $TARGET_DIR"
echo "   2. Use Synology's pkgscripts-ng to create the .spk file:"
echo "      cd $BUILD_DIR"
echo "      # Follow Synology SPK packaging guide"
echo ""
echo "📦 Package contents:"
echo "   - INFO: Package metadata"
echo "   - scripts/start-stop-status: Service control script"
echo "   - target/backend/dsvideo-backend: Go binary (${SPK_ARCH})"
echo ""
