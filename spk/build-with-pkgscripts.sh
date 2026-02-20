#!/bin/bash
# Build SPK using Synology's pkgscripts-ng (requires Docker)
# Based on Synology's official documentation

set -euo pipefail

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Building SPK with Synology's Official Toolchain (pkgscripts-ng)"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "This requires Docker and will download Synology's toolkit."
echo ""

# Check Docker
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running"
    echo "   Please start Docker Desktop and try again"
    exit 1
fi

# Build using Docker with pkgscripts-ng
bash spk/build-spk-docker.sh amd64

echo ""
echo "✅ If build succeeded, the SPK should be in: build/spk/DSVideoServer-0.1.0-x64.spk"
