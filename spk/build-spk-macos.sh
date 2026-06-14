#!/bin/bash
# Build SPK package for Synology NAS (macOS-compatible)
# This script manually creates the .spk file without requiring pkgscripts-ng
#
# An SPK file is essentially a tar.gz archive with:
# - INFO file (package metadata)
# - package.tgz (the actual package contents)
# - scripts/ (lifecycle scripts)
# - conf/ (privilege configuration - REQUIRED for DSM 7)
#
# Usage: ./build-spk-macos.sh [arm64|amd64]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPK_DIR="$SCRIPT_DIR/DSVideoServer"
BUILD_DIR="$REPO_ROOT/build/spk"
PACKAGE_DIR="$BUILD_DIR/DSVideoServer"
TEMP_SPK_DIR="$BUILD_DIR/spk-temp"

# Ensure Go is in PATH
export PATH="$PATH:/usr/local/go/bin"

# Detect architecture from argument, or read from INFO file
INFO_ARCH_DEFAULT=$(grep '^arch=' "$SPK_DIR/INFO" | cut -d'"' -f2)
case "$INFO_ARCH_DEFAULT" in
  x86_64) DEFAULT_ARCH="amd64" ;;
  armv8)  DEFAULT_ARCH="arm64" ;;
  *)      DEFAULT_ARCH="amd64" ;;
esac
ARCH="${1:-$DEFAULT_ARCH}"
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
    echo "❌ Unknown architecture: $ARCH"
    echo "Usage: $0 [arm64|amd64]"
    exit 1
    ;;
esac

# Read version from INFO file
PACKAGE_VERSION=$(grep '^version=' "$SPK_DIR/INFO" | cut -d'"' -f2)
PACKAGE_NAME=$(grep '^package=' "$SPK_DIR/INFO" | cut -d'"' -f2)
SPK_FILENAME="${PACKAGE_NAME}-${PACKAGE_VERSION}-${SPK_ARCH}.spk"

# Map architecture for INFO file
# For x86_64, use "x86_64" (Synology's expected format)
case "$SPK_ARCH" in
  armv8)
    INFO_ARCH="armv8"
    ;;
  x64)
    INFO_ARCH="x86_64"  # Use x86_64 for AMD Ryzen/Intel x64
    ;;
  *)
    INFO_ARCH="noarch"
    ;;
esac

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Building SPK for Synology NAS (${SPK_ARCH})"
echo "Package: ${PACKAGE_NAME} v${PACKAGE_VERSION}"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$PACKAGE_DIR/backend"
mkdir -p "$PACKAGE_DIR/var"
mkdir -p "$TEMP_SPK_DIR"

# Copy SPK structure
echo "📦 Copying SPK structure..."
cp "$SPK_DIR/INFO" "$PACKAGE_DIR/"
cp -r "$SPK_DIR/scripts" "$PACKAGE_DIR/"

# Build Go backend for target architecture
echo "🔨 Cross-compiling Go backend for ${GOOS}/${GOARCH}..."
cd "$REPO_ROOT/backend"

# Force cross-compilation with CGO disabled (required for static binaries)
export CGO_ENABLED=0
export GOOS=$GOOS
export GOARCH=$GOARCH

go build -ldflags="-s -w -X main.BuildVersion=${PACKAGE_VERSION}" -o "$PACKAGE_DIR/backend/dsvideo-backend" ./cmd/dsvideo-backend

# Verify it's a Linux binary
if file "$PACKAGE_DIR/backend/dsvideo-backend" | grep -q "Mach-O"; then
    echo "❌ ERROR: Binary is macOS format, not Linux!"
    echo "   This means cross-compilation failed."
    echo "   Binary type: $(file "$PACKAGE_DIR/backend/dsvideo-backend")"
    exit 1
fi

# Make binary executable
chmod +x "$PACKAGE_DIR/backend/dsvideo-backend"

# Verify binary
if [ ! -f "$PACKAGE_DIR/backend/dsvideo-backend" ]; then
    echo "❌ Failed to build Go binary"
    exit 1
fi

echo "✅ Go binary built: $(ls -lh "$PACKAGE_DIR/backend/dsvideo-backend" | awk '{print $5}')"

# TASK-750: bundle VAAPI-enabled ffmpeg/ffprobe (x64/Intel iGPU only). Built by
# build-ffmpeg.sh and committed into DSVideoServer/bin/. start-stop-status prefers
# these over the system ffmpeg so hardware transcode + trick-play engage. Missing =
# ship anyway (server falls back to system ffmpeg + software), but warn.
if [ "$SPK_ARCH" = "x64" ]; then
    if [ -x "$SPK_DIR/bin/ffmpeg" ] && [ -x "$SPK_DIR/bin/ffprobe" ]; then
        mkdir -p "$PACKAGE_DIR/bin"
        cp "$SPK_DIR/bin/ffmpeg" "$PACKAGE_DIR/bin/ffmpeg"
        cp "$SPK_DIR/bin/ffprobe" "$PACKAGE_DIR/bin/ffprobe"
        chmod +x "$PACKAGE_DIR/bin/ffmpeg" "$PACKAGE_DIR/bin/ffprobe"
        echo "✅ VAAPI ffmpeg/ffprobe bundled ($(ls -lh "$PACKAGE_DIR/bin/ffmpeg" | awk '{print $5}'))"
    else
        echo "⚠️  No bundled ffmpeg (DSVideoServer/bin/ffmpeg missing) — hardware"
        echo "    transcode + trick-play will fall back to system ffmpeg / software."
        echo "    Run ./build-ffmpeg.sh to bundle a VAAPI build."
    fi
fi

# Copy ui directory into package contents (DSM reads dsmuidir from target/ui/)
if [ -d "$SPK_DIR/ui" ]; then
    cp -r "$SPK_DIR/ui" "$PACKAGE_DIR/"
    echo "✅ ui/ added to package contents"
fi

# Copy webapi directory into package contents (Video Station WebAPI compatibility)
if [ -d "$SPK_DIR/webapi" ]; then
    cp -r "$SPK_DIR/webapi" "$PACKAGE_DIR/"
    chmod +x "$PACKAGE_DIR/webapi/"*.cgi 2>/dev/null || true
    chmod +x "$PACKAGE_DIR/webapi/VideoStation/"*.cgi 2>/dev/null || true
    echo "✅ webapi/ added to package contents (VideoStation API compatibility)"
fi

# Copy nginx config into package contents
if [ -d "$SPK_DIR/nginx" ]; then
    cp -r "$SPK_DIR/nginx" "$PACKAGE_DIR/"
    echo "✅ nginx/ added to package contents (DSM proxy config)"
fi

# Create package.tgz (the actual package contents - WITHOUT scripts)
# NOTE: DSM 7 creates symlink /var/packages/PKG/target -> /volume1/@appstore/PKG
# So package.tgz contents extract to @appstore, and target/ symlink points there
# Binary at backend/dsvideo-backend becomes accessible via target/backend/dsvideo-backend
echo "📦 Creating package.tgz..."
cd "$PACKAGE_DIR"
# Build list of directories to include
PKG_CONTENTS="backend/ var/"
[ -d "bin" ] && PKG_CONTENTS="$PKG_CONTENTS bin/"   # TASK-750: bundled VAAPI ffmpeg
[ -d "ui" ] && PKG_CONTENTS="$PKG_CONTENTS ui/"
[ -d "webapi" ] && PKG_CONTENTS="$PKG_CONTENTS webapi/"
[ -d "nginx" ] && PKG_CONTENTS="$PKG_CONTENTS nginx/"
# Create tar.gz (macOS tar may not support --owner/--group, but that's OK)
tar -czf "$TEMP_SPK_DIR/package.tgz" $PKG_CONTENTS

# Copy INFO, scripts, and conf to temp directory (these go at SPK root, not in package.tgz)
cp "$PACKAGE_DIR/INFO" "$TEMP_SPK_DIR/"
cp -r "$PACKAGE_DIR/scripts" "$TEMP_SPK_DIR/"

# Copy conf directory (required for DSM 7 - contains privilege file)
if [ -d "$SPK_DIR/conf" ]; then
    cp -r "$SPK_DIR/conf" "$TEMP_SPK_DIR/"
    echo "✅ conf/privilege copied (required for DSM 7)"
else
    echo "⚠️  Warning: conf/ directory not found - package may fail to install on DSM 7"
fi

# Copy package icons
if [ -f "$SPK_DIR/PACKAGE_ICON.PNG" ]; then
    cp "$SPK_DIR/PACKAGE_ICON.PNG" "$TEMP_SPK_DIR/"
    cp "$SPK_DIR/PACKAGE_ICON_256.PNG" "$TEMP_SPK_DIR/" 2>/dev/null || true
    echo "✅ Package icons copied"
else
    echo "⚠️  Warning: PACKAGE_ICON.PNG not found"
fi

# Copy ui directory (DSM desktop icon configuration)
if [ -d "$SPK_DIR/ui" ]; then
    cp -r "$SPK_DIR/ui" "$TEMP_SPK_DIR/"
    echo "✅ ui/ copied (DSM desktop icon)"
else
    echo "⚠️  Warning: ui/ directory not found - no desktop icon will be shown"
fi

# Update INFO file with correct architecture
sed -i '' "s/^arch=\".*\"/arch=\"${INFO_ARCH}\"/" "$TEMP_SPK_DIR/INFO" 2>/dev/null || \
    sed -i "s/^arch=\".*\"/arch=\"${INFO_ARCH}\"/" "$TEMP_SPK_DIR/INFO" 2>/dev/null || true

# Make scripts executable (all files in scripts directory)
find "$TEMP_SPK_DIR/scripts" -type f -exec chmod +x {} \;

# Ensure INFO file has proper formatting (Unix line endings, WITH trailing newline)
# Remove Windows line endings (CRLF -> LF)
dos2unix "$TEMP_SPK_DIR/INFO" 2>/dev/null || \
    sed -i '' 's/\r$//' "$TEMP_SPK_DIR/INFO" 2>/dev/null || true

# Remove empty fields from INFO (Synology doesn't like empty firmware="" or support_url="")
sed -i '' '/^firmware=""$/d' "$TEMP_SPK_DIR/INFO" 2>/dev/null || true
sed -i '' '/^support_url=""$/d' "$TEMP_SPK_DIR/INFO" 2>/dev/null || true

# Ensure INFO file ends properly (remove trailing newline - conflicting info, try without)
# Some sources say no trailing newline, others say yes - try without first
perl -pi -e 'chomp if eof' "$TEMP_SPK_DIR/INFO" 2>/dev/null || \
    sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$TEMP_SPK_DIR/INFO" 2>/dev/null || true

# Create the final .spk file (tar.gz of INFO + package.tgz + scripts/)
# Synology expects standard tar.gz format with INFO first
echo "📦 Creating .spk file..."
cd "$TEMP_SPK_DIR"

# Create SPK as plain tar (NOT gzipped - Synology expects uncompressed tar)
# Use ustar format for maximum compatibility
# Ensure INFO is the first file (Synology reads this first)
echo "📦 Creating .spk file (plain tar, not gzipped)..."
if command -v gtar &> /dev/null; then
    TAR_CMD="gtar"
else
    TAR_CMD="tar"
fi

# Build the list of files to include
SPK_FILES="INFO PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG package.tgz scripts/"
[ -d "conf" ] && SPK_FILES="$SPK_FILES conf/"
[ -d "ui" ] && SPK_FILES="$SPK_FILES ui/"

$TAR_CMD --format=ustar -cf "$BUILD_DIR/$SPK_FILENAME" $SPK_FILES 2>/dev/null || \
$TAR_CMD -cf "$BUILD_DIR/$SPK_FILENAME" $SPK_FILES

# Verify SPK file
if [ ! -f "$BUILD_DIR/$SPK_FILENAME" ]; then
    echo "❌ Failed to create SPK file"
    exit 1
fi

SPK_SIZE=$(ls -lh "$BUILD_DIR/$SPK_FILENAME" | awk '{print $5}')

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "✅ SPK package created successfully!"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "📦 Package: $SPK_FILENAME"
echo "📊 Size: $SPK_SIZE"
echo "📁 Location: $BUILD_DIR/$SPK_FILENAME"
echo ""
echo "📋 Package contents:"
echo "   - INFO: Package metadata"
echo "   - conf/privilege: DSM 7 privilege configuration"
echo "   - conf/resource: Portal/webservice configuration"
echo "   - ui/config: DSM desktop icon configuration"
echo "   - scripts/start-stop-status: Service control script"
echo "   - package.tgz/backend/dsvideo-backend: Go binary (${SPK_ARCH})"
echo ""
echo "📥 Installation:"
echo "   1. Upload $SPK_FILENAME to your Synology NAS"
echo "   2. Open Package Center → Manual Install"
echo "   3. Select the .spk file and install"
echo "   4. Configure library paths after installation"
echo ""
echo "⚠️  Note: This is an unsigned package. DSM may show a warning."
echo "   You can install it by enabling 'Allow installation of packages from"
echo "   Synology Inc. and trusted publishers' in Package Center settings."
echo ""
