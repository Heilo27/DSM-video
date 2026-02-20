#!/bin/bash
# Installation commands for DS923+ (ryan@192.168.50.146)

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "DS Video Server - Installation Commands"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPK_FILE="$REPO_ROOT/build/spk/DSVideoServer-0.1.0-x64.spk"

if [ ! -f "$SPK_FILE" ]; then
    echo "❌ SPK file not found: $SPK_FILE"
    echo "   Run: ./spk/build-spk-macos.sh amd64"
    exit 1
fi

echo "📦 SPK file: $SPK_FILE"
echo ""

echo "Step 1: Upload SPK to NAS"
echo "───────────────────────────────────────────────────────────────────────────────"
echo "Run this command:"
echo ""
echo "  scp \"$SPK_FILE\" ryan@192.168.50.146:/tmp/"
echo ""
read -p "Press Enter after uploading..."

echo ""
echo "Step 2: SSH into NAS and Install"
echo "───────────────────────────────────────────────────────────────────────────────"
echo "Run these commands:"
echo ""
echo "  ssh ryan@192.168.50.146"
echo "  sudo synopkg install /tmp/DSVideoServer-0.1.0-x64.spk"
echo ""
echo "If installation succeeds, start the service:"
echo "  sudo synopkg start DSVideoServer"
echo ""
echo "Check status:"
echo "  sudo synopkg status DSVideoServer"
echo ""
echo "View logs:"
echo "  tail -f /var/log/packages/DSVideoServer.log"
echo ""
