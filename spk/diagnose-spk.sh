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
tar -xzf "$SPK_FILE" 2>&1 || {
    echo "❌ Failed to extract SPK file (corrupted?)"
    exit 1
}

echo "✅ SPK file is valid tar.gz"
echo ""

# Check structure
echo "📋 SPK Structure:"
ls -la
echo ""

# Check INFO file
if [ -f "INFO" ]; then
    echo "📄 INFO File:"
    cat INFO
    echo ""
    
    # Extract key fields
    PACKAGE=$(grep '^package=' INFO | cut -d'"' -f2)
    VERSION=$(grep '^version=' INFO | cut -d'"' -f2)
    ARCH=$(grep '^arch=' INFO | cut -d'"' -f2)
    DSM_VER=$(grep '^os_min_ver=' INFO | cut -d'"' -f2)
    
    echo "   Package: $PACKAGE"
    echo "   Version: $VERSION"
    echo "   Architecture: $ARCH"
    echo "   Minimum DSM: $DSM_VER"
    echo ""
else
    echo "❌ INFO file missing!"
fi

# Check scripts
if [ -d "scripts" ]; then
    echo "📜 Scripts Directory:"
    ls -la scripts/
    echo ""
    
    if [ -f "scripts/start-stop-status" ]; then
        if [ -x "scripts/start-stop-status" ]; then
            echo "   ✅ start-stop-status is executable"
        else
            echo "   ⚠️  start-stop-status is NOT executable"
        fi
    fi
else
    echo "⚠️  scripts/ directory missing"
fi

# Check package.tgz
if [ -f "package.tgz" ]; then
    echo "📦 package.tgz Contents:"
    tar -tzf package.tgz | head -10
    echo ""
    
    # Check for binary
    if tar -tzf package.tgz | grep -q "dsvideo-backend"; then
        echo "   ✅ Go binary found in package"
        
        # Extract and check binary
        tar -xzf package.tgz target/backend/dsvideo-backend 2>/dev/null || true
        if [ -f "target/backend/dsvideo-backend" ]; then
            echo "   Binary size: $(ls -lh target/backend/dsvideo-backend | awk '{print $5}')"
            echo "   Binary type: $(file target/backend/dsvideo-backend | cut -d: -f2)"
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
echo "   Requires: DSM 7.2 or higher"
echo ""
echo "3. Enable Unsigned Packages:"
echo "   Package Center → Settings → General"
echo "   Check: 'Allow installation of packages from any publisher'"
echo ""
echo "4. If architecture mismatch, rebuild:"
echo "   ./spk/build-spk-macos.sh <correct-arch>"
echo ""
