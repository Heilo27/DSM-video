#!/bin/bash
# Start network capture for Video Station API analysis

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPTURE_DIR="$REPO_ROOT/tools/captures"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

mkdir -p "$CAPTURE_DIR"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Starting Network Capture for Video Station API"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Check for Charles Proxy
if [ -d "/Applications/Charles.app" ]; then
    echo "✅ Charles Proxy found"
    echo ""
    echo "📋 Instructions:"
    echo "   1. Open Charles Proxy"
    echo "   2. Go to Proxy → Clear Session (to start fresh)"
    echo "   3. Ensure recording is enabled (should be on by default)"
    echo "   4. Configure SSL Proxying for 192.168.50.146"
    echo "   5. Run DS Video iOS app in Xcode Simulator"
    echo "   6. Connect to Video Station and perform actions"
    echo "   7. Export session: File → Export → JSON"
    echo "   8. Save to: $CAPTURE_DIR/videostation-api-$TIMESTAMP.json"
    echo ""
    echo "🚀 Opening Charles Proxy..."
    open -a Charles
    echo ""
    echo "⏳ Waiting for you to start capture in Charles..."
    echo "   Press Enter when ready to continue..."
    read -r
elif command -v mitmproxy &> /dev/null; then
    echo "✅ mitmproxy found"
    echo ""
    echo "📋 Starting mitmproxy..."
    echo "   Press 'w' to save capture when done"
    echo "   Save to: $CAPTURE_DIR/videostation-api-$TIMESTAMP.flow"
    echo ""
    mitmproxy -p 8888 -s "$SCRIPT_DIR/mitmproxy-save.py" --set confdir="$CAPTURE_DIR"
else
    echo "❌ No network capture tool found"
    echo ""
    echo "📥 Install Charles Proxy:"
    echo "   brew install --cask charles"
    echo ""
    echo "   Or install mitmproxy:"
    echo "   brew install mitmproxy"
    echo ""
    exit 1
fi

echo ""
echo "✅ Capture session ready!"
echo "   Remember to export/save your capture when done."
