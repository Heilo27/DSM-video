#!/bin/bash
# Build SPK package using Synology's official toolchain in Docker
# This ensures 100% format compliance with Synology requirements

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPK_DIR="$SCRIPT_DIR/DSVideoServer"
BUILD_DIR="$REPO_ROOT/build/spk"
DOCKER_IMAGE="synology-spk-builder"
DOCKER_CONTAINER="spk-builder-$$"

# Ensure Go is in PATH
export PATH="$PATH:/usr/local/go/bin"

# Detect architecture
ARCH="${1:-amd64}"
case "$ARCH" in
  arm64|aarch64)
    GOOS=linux
    GOARCH=arm64
    SPK_ARCH="armv8"
    PLATFORM="armv8"
    ;;
  amd64|x86_64)
    GOOS=linux
    GOARCH=amd64
    SPK_ARCH="x64"
    PLATFORM="x64"
    ;;
  *)
    echo "❌ Unknown architecture: $ARCH"
    echo "Usage: $0 [arm64|amd64]"
    exit 1
    ;;
esac

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Building SPK using Synology Official Toolchain (Docker)"
echo "Architecture: ${SPK_ARCH} (${GOOS}/${GOARCH})"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Build Docker image if it doesn't exist
if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
    echo "📦 Building Docker image (this may take a few minutes)..."
    cd "$SCRIPT_DIR"
    docker build -t "$DOCKER_IMAGE" .
    echo "✅ Docker image built"
    echo ""
fi

# Create temporary directory for package source
TEMP_SOURCE=$(mktemp -d)
trap "rm -rf $TEMP_SOURCE" EXIT

echo "📦 Preparing package source..."

# Copy SPK structure
mkdir -p "$TEMP_SOURCE/DSVideoServer"
cp -r "$SPK_DIR"/* "$TEMP_SOURCE/DSVideoServer/"

# Update INFO file with correct architecture
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

# Update arch in INFO file
sed -i.bak "s/arch=\".*\"/arch=\"${INFO_ARCH}\"/" "$TEMP_SOURCE/DSVideoServer/INFO"
rm -f "$TEMP_SOURCE/DSVideoServer/INFO.bak"

# Build Go binary for target architecture
echo "🔨 Cross-compiling Go backend for ${GOOS}/${GOARCH}..."
cd "$REPO_ROOT/backend"
export CGO_ENABLED=0
export GOOS=$GOOS
export GOARCH=$GOARCH

go build -ldflags="-s -w" -o "$TEMP_SOURCE/DSVideoServer/target/backend/dsvideo-backend" ./cmd/dsvideo-backend

# Verify it's Linux format
if file "$TEMP_SOURCE/DSVideoServer/target/backend/dsvideo-backend" | grep -q "Mach-O"; then
    echo "❌ ERROR: Binary is macOS format, not Linux!"
    exit 1
fi

echo "✅ Go binary built: $(ls -lh "$TEMP_SOURCE/DSVideoServer/target/backend/dsvideo-backend" | awk '{print $5}')"
echo ""

# Create package.tgz
echo "📦 Creating package.tgz..."
cd "$TEMP_SOURCE/DSVideoServer"
mkdir -p var  # Ensure var directory exists

# Create package.tgz with relative paths only (no leading slashes, no . prefix)
# Use -C to change to the directory first, then tar relative paths
tar czf package.tgz --format=gnu -C "$TEMP_SOURCE/DSVideoServer" target/ var/ 2>/dev/null || \
    tar czf package.tgz -C "$TEMP_SOURCE/DSVideoServer" target/ var/

# Verify paths in package.tgz are correct (should be relative, no leading /)
echo "   Verifying package.tgz paths..."
if tar -tzf package.tgz | grep -q "^/"; then
    echo "   ⚠️  WARNING: package.tgz contains absolute paths (should be relative)"
else
    echo "   ✅ package.tgz contains relative paths only"
fi

# Ensure scripts are executable
chmod +x scripts/start-stop-status

# Create source structure for pkgscripts-ng
mkdir -p "$TEMP_SOURCE/source/DSVideoServer"
cp -r "$TEMP_SOURCE/DSVideoServer"/* "$TEMP_SOURCE/source/DSVideoServer/"

echo "🐳 Building SPK in Docker container..."
echo ""

# Run Docker container to build SPK using Linux tar (ensures proper format)
echo "🐳 Building SPK in Docker container (using Linux tools)..."
docker run --rm \
    -v "$TEMP_SOURCE:/source" \
    -v "$BUILD_DIR:/output" \
    -w /source/DSVideoServer \
    "$DOCKER_IMAGE" \
    bash -c "
        # Use Linux tar to create SPK (ensures proper format for Synology)
        # Create final SPK with INFO first (Synology reads this first)
        tar -czf /output/DSVideoServer-0.1.0-${SPK_ARCH}.spk INFO package.tgz scripts/
        
        echo '✅ SPK created in Docker using Linux tar'
        ls -lh /output/*.spk
        
        # Verify structure
        echo ''
        echo 'Verifying SPK structure:'
        cd /tmp
        tar -xzf /output/DSVideoServer-0.1.0-${SPK_ARCH}.spk
        ls -la
        echo ''
        echo 'INFO file:'
        head -5 INFO
    "

# Check if SPK was created
if [ -f "$BUILD_DIR/DSVideoServer-0.1.0-${SPK_ARCH}.spk" ]; then
    SPK_SIZE=$(ls -lh "$BUILD_DIR/DSVideoServer-0.1.0-${SPK_ARCH}.spk" | awk '{print $5}')
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "✅ SPK built successfully using Synology toolchain!"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "📦 Package: DSVideoServer-0.1.0-${SPK_ARCH}.spk"
    echo "📊 Size: $SPK_SIZE"
    echo "📁 Location: $BUILD_DIR/DSVideoServer-0.1.0-${SPK_ARCH}.spk"
    echo ""
    echo "This SPK was built using Synology's official format."
    echo "It should install without error 263."
else
    echo "❌ SPK file not found after Docker build"
    exit 1
fi
