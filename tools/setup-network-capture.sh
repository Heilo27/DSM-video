#!/bin/bash
# Setup script for network capture tools to analyze Video Station API

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Network Capture Setup for Video Station API Analysis"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "📦 Installing Homebrew (if needed)..."
    echo "   Visit: https://brew.sh"
    echo "   Or run: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo ""
fi

echo "🔍 Checking for network capture tools..."
echo ""

# Check for Charles Proxy
if [ -d "/Applications/Charles.app" ]; then
    echo "✅ Charles Proxy is installed"
    CHARLES_INSTALLED=true
else
    echo "❌ Charles Proxy is not installed"
    echo "   Download from: https://www.charlesproxy.com/download/"
    echo "   Or install via Homebrew: brew install --cask charles"
    CHARLES_INSTALLED=false
fi

# Check for Wireshark
if command -v wireshark &> /dev/null || [ -d "/Applications/Wireshark.app" ]; then
    echo "✅ Wireshark is installed"
    WIRESHARK_INSTALLED=true
else
    echo "❌ Wireshark is not installed"
    echo "   Install via Homebrew: brew install --cask wireshark"
    WIRESHARK_INSTALLED=false
fi

# Check for mitmproxy
if command -v mitmproxy &> /dev/null; then
    echo "✅ mitmproxy is installed"
    MITMPROXY_INSTALLED=true
else
    echo "❌ mitmproxy is not installed"
    echo "   Install via Homebrew: brew install mitmproxy"
    MITMPROXY_INSTALLED=false
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Installation Recommendations"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

if [ "$CHARLES_INSTALLED" = false ]; then
    echo "📥 Install Charles Proxy (Recommended for iOS Simulator):"
    echo "   brew install --cask charles"
    echo ""
fi

if [ "$WIRESHARK_INSTALLED" = false ]; then
    echo "📥 Install Wireshark (Alternative for network capture):"
    echo "   brew install --cask wireshark"
    echo ""
fi

if [ "$MITMPROXY_INSTALLED" = false ]; then
    echo "📥 Install mitmproxy (Command-line alternative):"
    echo "   brew install mitmproxy"
    echo ""
fi

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Next Steps"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "1. Install missing tools (if any)"
echo "2. Follow setup guide: docs/NETWORK_CAPTURE_GUIDE.md"
echo "3. Start capturing: ./tools/start-capture.sh"
echo "4. Run DS Video iOS app and connect to Video Station"
echo "5. Analyze captured traffic: ./tools/analyze-capture.sh"
echo ""
