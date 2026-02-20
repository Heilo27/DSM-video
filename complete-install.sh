#!/bin/bash
# Complete installation script - uploads and installs in one go
# This will prompt for your NAS password

set -euo pipefail

NAS_USER="ryan"
NAS_IP="192.168.50.146"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "DS Video Server - Complete Installation"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Check files exist
BINARY="$REPO_ROOT/build/spk/DSVideoServer/target/backend/dsvideo-backend"
SCRIPT="$REPO_ROOT/install-on-nas.sh"

if [ ! -f "$BINARY" ]; then
    echo "❌ Binary not found. Building..."
    cd "$REPO_ROOT"
    bash spk/build-spk.sh x86_64
fi

if [ ! -f "$BINARY" ] || [ ! -f "$SCRIPT" ]; then
    echo "❌ Required files not found"
    exit 1
fi

echo "✅ Files ready:"
echo "   Binary: $BINARY"
echo "   Script: $SCRIPT"
echo ""

# Step 1: Upload files
echo "Step 1: Uploading files to NAS..."
echo "───────────────────────────────────────────────────────────────────────────────"
echo "You will be prompted for your NAS password (twice - once for each file)..."
echo ""

echo "📤 Uploading binary..."
if scp "$BINARY" "${NAS_USER}@${NAS_IP}:/tmp/dsvideo-backend"; then
    echo "   ✅ Binary uploaded"
else
    echo "   ❌ Binary upload failed"
    echo ""
    echo "   💡 Alternative: Upload via File Station:"
    echo "      1. Open DSM → File Station"
    echo "      2. Go to /tmp/"
    echo "      3. Upload: $BINARY"
    echo "      4. Rename to: dsvideo-backend"
    echo ""
    read -p "Press Enter after manual upload, or Ctrl+C to cancel..."
fi

echo ""
echo "📤 Uploading install script..."
if scp "$SCRIPT" "${NAS_USER}@${NAS_IP}:/tmp/install-on-nas.sh"; then
    echo "   ✅ Script uploaded"
else
    echo "   ❌ Script upload failed"
    echo ""
    echo "   💡 Alternative: Upload via File Station:"
    echo "      1. Open DSM → File Station"
    echo "      2. Go to /tmp/"
    echo "      3. Upload: $SCRIPT"
    echo ""
    read -p "Press Enter after manual upload, or Ctrl+C to cancel..."
fi

echo ""

# Step 2: Verify files on NAS
echo "Step 2: Verifying files on NAS..."
echo "───────────────────────────────────────────────────────────────────────────────"
if ssh "${NAS_USER}@${NAS_IP}" "test -f /tmp/dsvideo-backend && test -f /tmp/install-on-nas.sh && echo 'OK'"; then
    echo "✅ Both files are on the NAS"
else
    echo "❌ Files not found on NAS"
    echo ""
    echo "Please verify files are uploaded:"
    echo "   ssh ${NAS_USER}@${NAS_IP}"
    echo "   ls -lh /tmp/dsvideo-backend /tmp/install-on-nas.sh"
    exit 1
fi

echo ""

# Step 3: Run installation
echo "Step 3: Running installation on NAS..."
echo "───────────────────────────────────────────────────────────────────────────────"
echo "You will be prompted for your NAS password (for sudo)..."
echo ""

ssh "${NAS_USER}@${NAS_IP}" << 'REMOTEEOF'
set -e

echo "Making script executable..."
chmod +x /tmp/install-on-nas.sh

echo "Running installation..."
sudo /tmp/install-on-nas.sh
REMOTEEOF

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "✅ Installation Complete!"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "🌐 Backend URL: http://192.168.50.146:8080"
echo "📱 iOS App: Set base URL to http://192.168.50.146:8080"
echo ""
echo "🧪 Test the backend:"
echo "   curl http://192.168.50.146:8080/api/v1/admin/status"
