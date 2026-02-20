#!/bin/bash
# Helper script to upload files to NAS

set -euo pipefail

NAS_USER="ryan"
NAS_IP="192.168.50.146"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "📤 Uploading files to NAS..."
echo ""

# Upload binary
echo "1. Uploading binary..."
if scp "$REPO_ROOT/build/spk/DSVideoServer/target/backend/dsvideo-backend" \
    "${NAS_USER}@${NAS_IP}:/tmp/dsvideo-backend" 2>/dev/null; then
    echo "   ✅ Binary uploaded"
else
    echo "   ⚠️  Binary upload failed (you may need to enter password)"
    echo "   💡 Or upload via File Station: build/spk/DSVideoServer/target/backend/dsvideo-backend → /tmp/dsvideo-backend"
fi

echo ""

# Upload install script
echo "2. Uploading install script..."
if scp "$REPO_ROOT/install-on-nas.sh" \
    "${NAS_USER}@${NAS_IP}:/tmp/install-on-nas.sh" 2>/dev/null; then
    echo "   ✅ Install script uploaded"
else
    echo "   ⚠️  Script upload failed (you may need to enter password)"
    echo "   💡 Or upload via File Station: install-on-nas.sh → /tmp/install-on-nas.sh"
fi

echo ""
echo "✅ Upload complete!"
echo ""
echo "Now SSH and run:"
echo "   ssh ${NAS_USER}@${NAS_IP}"
echo "   ls -lh /tmp/dsvideo-backend /tmp/install-on-nas.sh"
echo "   chmod +x /tmp/install-on-nas.sh"
echo "   sudo /tmp/install-on-nas.sh"
