#!/bin/bash
# Download Video Station SPK from Synology archive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_DIR="$SCRIPT_DIR/videostation-downloads"
ARCH="${1:-x64}"  # x64 or arm

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Video Station SPK Downloader"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"

# Video Station versions
VERSION="3.1.1-3168"
BASE_URL="https://global.synologydownload.com/download/Package/spk/VideoStation"

echo "📥 Downloading Video Station $VERSION for $ARCH..."
echo ""

# Determine architecture-specific URL
if [ "$ARCH" = "x64" ] || [ "$ARCH" = "x86_64" ]; then
    SPK_NAME="VideoStation-x86_64-${VERSION}.spk"
    ARCH_SUFFIX="x86_64"
elif [ "$ARCH" = "arm" ] || [ "$ARCH" = "arm64" ] || [ "$ARCH" = "armv8" ]; then
    SPK_NAME="VideoStation-armv8-${VERSION}.spk"
    ARCH_SUFFIX="armv8"
else
    echo "❌ Unknown architecture: $ARCH"
    echo "   Use: x64 or arm"
    exit 1
fi

FULL_URL="${BASE_URL}/${VERSION}/${SPK_NAME}"

echo "   URL: $FULL_URL"
echo "   Destination: $DOWNLOAD_DIR/$SPK_NAME"
echo ""

# Check if already downloaded
if [ -f "$SPK_NAME" ]; then
    echo "✅ File already exists: $SPK_NAME"
    echo "   Size: $(ls -lh "$SPK_NAME" | awk '{print $5}')"
    echo ""
    read -p "Download again? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Using existing file."
        exit 0
    fi
    rm -f "$SPK_NAME"
fi

# Download
echo "⏳ Downloading..."
if curl -L -o "$SPK_NAME" "$FULL_URL"; then
    echo ""
    echo "✅ Download complete!"
    echo "   File: $DOWNLOAD_DIR/$SPK_NAME"
    echo "   Size: $(ls -lh "$SPK_NAME" | awk '{print $5}')"
    echo ""
    echo "📋 Next steps:"
    echo "   1. Analyze the SPK:"
    echo "      ./spk/analyze-video-station.sh $DOWNLOAD_DIR/$SPK_NAME"
    echo ""
    echo "   2. Or extract manually:"
    echo "      mkdir -p videostation-extracted"
    echo "      cd videostation-extracted"
    echo "      tar -xzf $DOWNLOAD_DIR/$SPK_NAME"
else
    echo ""
    echo "❌ Download failed!"
    echo ""
    echo "⚠️  Manual download required:"
    echo "   1. Visit: https://archive.synology.com/download/Package/VideoStation/"
    echo "   2. Find version $VERSION"
    echo "   3. Download $SPK_NAME"
    echo "   4. Save to: $DOWNLOAD_DIR/"
    exit 1
fi
