#!/bin/bash
# Complete SSH-based installation script for DS Video Server
# This bypasses Package Center's file browser limitation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPK_FILE="$REPO_ROOT/build/spk/DSVideoServer-0.1.0-x64.spk"

# Configuration
NAS_USER="ryan"
NAS_IP="192.168.50.146"
NAS_TEMP="/tmp"
PACKAGE_NAME="DSVideoServer"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "DS Video Server - SSH Installation Script"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Check if SPK exists
if [ ! -f "$SPK_FILE" ]; then
    echo "❌ SPK file not found: $SPK_FILE"
    echo "   Run: ./spk/build-spk-docker.sh amd64"
    exit 1
fi

echo "📦 SPK file: $SPK_FILE"
echo "📊 Size: $(ls -lh "$SPK_FILE" | awk '{print $5}')"
echo ""

# Step 1: Clean up any existing installation
echo "Step 1: Cleaning up any existing installation..."
echo "───────────────────────────────────────────────────────────────────────────────"
echo "SSH into NAS and run cleanup:"
echo ""
echo "  ssh ${NAS_USER}@${NAS_IP}"
echo "  sudo rm -rf /var/packages/${PACKAGE_NAME}"
echo "  sudo rm -rf /volume1/@appdata/${PACKAGE_NAME}"
echo "  sudo rm -f /var/log/packages/${PACKAGE_NAME}.log"
echo ""
read -p "Press Enter after cleanup (or Ctrl+C to skip)..."
echo ""

# Step 2: Upload SPK
echo "Step 2: Uploading SPK to NAS..."
echo "───────────────────────────────────────────────────────────────────────────────"
echo "Uploading $SPK_FILE to ${NAS_USER}@${NAS_IP}:${NAS_TEMP}/"
echo ""

if scp "$SPK_FILE" "${NAS_USER}@${NAS_IP}:${NAS_TEMP}/DSVideoServer-0.1.0-x64.spk"; then
    echo "✅ Upload successful!"
else
    echo "❌ Upload failed!"
    echo ""
    echo "Alternative: Upload via File Station web interface:"
    echo "  1. Open DSM → File Station"
    echo "  2. Navigate to /tmp/"
    echo "  3. Upload: $SPK_FILE"
    echo ""
    read -p "Press Enter after manual upload..."
fi
echo ""

# Step 3: Install via SSH
echo "Step 3: Installing package via SSH..."
echo "───────────────────────────────────────────────────────────────────────────────"
echo "Run these commands on your NAS:"
echo ""
echo "  ssh ${NAS_USER}@${NAS_IP}"
echo "  sudo synopkg install ${NAS_TEMP}/DSVideoServer-0.1.0-x64.spk"
echo ""
echo "If installation succeeds:"
echo "  sudo synopkg start ${PACKAGE_NAME}"
echo "  sudo synopkg status ${PACKAGE_NAME}"
echo ""
echo "View logs:"
echo "  tail -f /var/log/packages/${PACKAGE_NAME}.log"
echo ""

# Option to run commands automatically
read -p "Do you want to run the install command automatically? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "🔧 Running installation command..."
    ssh "${NAS_USER}@${NAS_IP}" "sudo synopkg install ${NAS_TEMP}/DSVideoServer-0.1.0-x64.spk" || {
        echo ""
        echo "❌ Installation failed. Check the error message above."
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check logs: ssh ${NAS_USER}@${NAS_IP} 'sudo tail -20 /var/log/synopkg.log'"
        echo "  2. Verify SPK: ssh ${NAS_USER}@${NAS_IP} 'file ${NAS_TEMP}/DSVideoServer-0.1.0-x64.spk'"
        echo "  3. Check permissions: ssh ${NAS_USER}@${NAS_IP} 'ls -lh ${NAS_TEMP}/DSVideoServer-0.1.0-x64.spk'"
        exit 1
    }
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "Starting service..."
    ssh "${NAS_USER}@${NAS_IP}" "sudo synopkg start ${PACKAGE_NAME}" || true
    
    echo ""
    echo "Checking status..."
    ssh "${NAS_USER}@${NAS_IP}" "sudo synopkg status ${PACKAGE_NAME}"
    
    echo ""
    echo "📋 Service Management Commands:"
    echo "  sudo synopkg start ${PACKAGE_NAME}    # Start service"
    echo "  sudo synopkg stop ${PACKAGE_NAME}     # Stop service"
    echo "  sudo synopkg status ${PACKAGE_NAME}   # Check status"
    echo "  tail -f /var/log/packages/${PACKAGE_NAME}.log  # View logs"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Installation script complete!"
echo "═══════════════════════════════════════════════════════════════════════════════"
