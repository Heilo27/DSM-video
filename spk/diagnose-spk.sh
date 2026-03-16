#!/bin/bash
# Diagnose SPK file to help identify installation issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPK_FILE="${1:-$REPO_ROOT/build/spk/DSVideoServer-0.1.0-armv8.spk}"

# Convert to absolute path if relative
if [[ "$SPK_FILE" != /* ]]; then
    SPK_FILE="$REPO_ROOT/$SPK_FILE"
fi

if [ ! -f "$SPK_FILE" ]; then
    echo "❌ SPK file not found: $SPK_FILE"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "SPK File Diagnostics: $(basename "$SPK_FILE")"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

cd "$TEMP_DIR"
SPK_FORMAT="unknown"
if tar -tf "$SPK_FILE" >/dev/null 2>&1; then
    tar -xf "$SPK_FILE"
    SPK_FORMAT="tar"
    echo "✅ SPK file is valid plain tar"
elif tar -tzf "$SPK_FILE" >/dev/null 2>&1; then
    tar -xzf "$SPK_FILE"
    SPK_FORMAT="tar.gz"
    echo "⚠️  SPK file is a tar.gz (outer archive should be plain tar for DSM)"
else
    echo "❌ Failed to extract SPK file (corrupted or wrong format?)"
    exit 1
fi

# Determine package root (some broken archives include an extra DSVideoServer/ prefix).
ROOT="."
if [ ! -f "INFO" ] && [ -f "DSVideoServer/INFO" ]; then
    ROOT="DSVideoServer"
fi
if [ ! -f "${ROOT}/INFO" ]; then
    FOUND_INFO="$(find . -maxdepth 2 -name INFO -print -quit 2>/dev/null || true)"
    if [ -n "${FOUND_INFO}" ]; then
        ROOT="$(dirname "${FOUND_INFO}")"
    fi
fi
echo ""

# Check structure
echo "📋 SPK Structure:"
ls -la "${ROOT}"
echo ""

# Check INFO file
if [ -f "${ROOT}/INFO" ]; then
    echo "📄 INFO File:"
    cat "${ROOT}/INFO"
    echo ""
    
    # Extract key fields
    PACKAGE=$(grep '^package=' "${ROOT}/INFO" | cut -d'"' -f2 || true)
    VERSION=$(grep '^version=' "${ROOT}/INFO" | cut -d'"' -f2 || true)
    ARCH=$(grep '^arch=' "${ROOT}/INFO" | cut -d'"' -f2 || true)
    DSM_VER=$(grep '^os_min_ver=' "${ROOT}/INFO" | cut -d'"' -f2 || true)
    
    echo "   Package: $PACKAGE"
    echo "   Version: $VERSION"
    echo "   Architecture: $ARCH"
    echo "   Minimum DSM: $DSM_VER"
    echo ""
else
    echo "❌ INFO file missing!"
fi

# Check scripts
if [ -d "${ROOT}/scripts" ]; then
    echo "📜 Scripts Directory:"
    ls -la "${ROOT}/scripts/"
    echo ""
    
    if [ -f "${ROOT}/scripts/start-stop-status" ]; then
        if [ -x "${ROOT}/scripts/start-stop-status" ]; then
            echo "   ✅ start-stop-status is executable"
        else
            echo "   ⚠️  start-stop-status is NOT executable"
        fi
    fi
else
    echo "⚠️  scripts/ directory missing"
fi

# Check package.tgz
if [ -f "${ROOT}/package.tgz" ]; then
    echo "📦 package.tgz Contents:"
    tar -tzf "${ROOT}/package.tgz" | head -15
    echo ""
    
    # Check for binary
    if tar -tzf "${ROOT}/package.tgz" | grep -q "backend/dsvideo-backend"; then
        echo "   ✅ Go binary found in package"
        
        # Extract and check binary
        tar -xzf "${ROOT}/package.tgz" backend/dsvideo-backend 2>/dev/null || true
        if [ -f "backend/dsvideo-backend" ]; then
            echo "   Binary size: $(ls -lh backend/dsvideo-backend | awk '{print $5}')"
            echo "   Binary type: $(file backend/dsvideo-backend | cut -d: -f2)"
        fi
    else
        echo "   ❌ Go binary NOT found in package"
    fi
else
    echo "❌ package.tgz missing!"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "💡 Troubleshooting Tips:"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "1. Check NAS Architecture:"
echo "   SSH into your NAS and run: uname -m"
echo "   - arm64/aarch64 → Use: ./build-spk-macos.sh arm64"
echo "   - x86_64/amd64 → Use: ./build-spk-macos.sh amd64"
echo ""
echo "2. Check DSM Version:"
echo "   DSM → Control Panel → Info Center"
echo "   Requires: DSM >= ${DSM_VER:-<see INFO os_min_ver>}"
echo ""
echo "3. Enable Unsigned Packages:"
echo "   Package Center → Settings → General"
echo "   Check: 'Allow installation of packages from any publisher'"
echo ""
echo "4. If architecture mismatch, rebuild:"
echo "   ./spk/build-spk-macos.sh <correct-arch>"
echo ""

if [ "$SPK_FORMAT" = "tar.gz" ]; then
    echo "5. If Repair fails, rebuild as plain tar:"
    echo "   DSM expects the outer .spk archive to be an uncompressed tar (see spk/SPK-PACKAGING.md)."
    echo ""
fi
