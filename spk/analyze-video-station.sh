#!/bin/bash
# Extract and analyze Video Station SPK package to understand its structure and API

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYSIS_DIR="$SCRIPT_DIR/videostation-analysis"
SPK_URL="https://archive.synology.com/download/Package/VideoStation/3.1.1-3168"
SPK_FILE=""

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Video Station SPK Analysis Tool"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Check if SPK file is provided as argument
if [ $# -ge 1 ] && [ -f "$1" ]; then
    SPK_FILE="$1"
    echo "📦 Using provided SPK: $SPK_FILE"
else
    echo "📥 Downloading Video Station SPK from Synology archive..."
    echo "   URL: $SPK_URL"
    echo ""
    echo "⚠️  Note: You may need to download manually from:"
    echo "   https://archive.synology.com/download/Package/VideoStation/"
    echo ""
    read -p "Enter path to Video Station SPK file (or press Enter to skip download): " SPK_FILE
    if [ -z "$SPK_FILE" ] || [ ! -f "$SPK_FILE" ]; then
        echo "❌ No valid SPK file provided. Exiting."
        echo ""
        echo "To download manually:"
        echo "  1. Visit: https://archive.synology.com/download/Package/VideoStation/"
        echo "  2. Download a version (e.g., 3.1.1-3168 for x86_64)"
        echo "  3. Run: $0 /path/to/VideoStation-x64-3.1.1-3168.spk"
        exit 1
    fi
fi

# Create analysis directory
mkdir -p "$ANALYSIS_DIR"
cd "$ANALYSIS_DIR"

echo ""
echo "🔍 Extracting SPK package..."
tar -xzf "$SPK_FILE" 2>/dev/null || {
    echo "❌ Failed to extract SPK. It may be corrupted or in a different format."
    exit 1
}

echo "✅ Extraction complete!"
echo ""

# Analyze structure
echo "📋 Package Structure:"
echo "───────────────────────────────────────────────────────────────────────────────"
ls -la
echo ""

# Extract package.tgz if it exists
if [ -f "package.tgz" ]; then
    echo "📦 Extracting package.tgz..."
    mkdir -p package-contents
    cd package-contents
    tar -xzf ../package.tgz
    cd ..
    echo "✅ Package contents extracted!"
    echo ""
fi

# Analyze INFO file
if [ -f "INFO" ]; then
    echo "📄 INFO File:"
    echo "───────────────────────────────────────────────────────────────────────────────"
    cat INFO
    echo ""
fi

# Find and analyze scripts
echo "🔧 Scripts:"
echo "───────────────────────────────────────────────────────────────────────────────"
if [ -d "scripts" ]; then
    find scripts -type f -executable | head -20
    echo ""
    
    # Look for API-related scripts
    echo "🔍 Searching for API/Web endpoints..."
    grep -r "api\|endpoint\|/webapi\|SYNO" scripts/ 2>/dev/null | head -20 || echo "   (No API references found in scripts)"
    echo ""
fi

# Find web/API files
echo "🌐 Web/API Files:"
echo "───────────────────────────────────────────────────────────────────────────────"
if [ -d "package-contents" ]; then
    find package-contents -type f \( -name "*.php" -o -name "*.py" -o -name "*.js" -o -name "*api*" -o -name "*web*" \) | head -30
    echo ""
    
    # Look for API endpoints
    echo "🔍 Searching for API endpoints..."
    find package-contents -type f \( -name "*.php" -o -name "*.py" -o -name "*.js" \) -exec grep -l "api\|endpoint\|SYNO\|/webapi" {} \; 2>/dev/null | head -10 || echo "   (No API files found)"
    echo ""
fi

# Find configuration files
echo "⚙️  Configuration Files:"
echo "───────────────────────────────────────────────────────────────────────────────"
find . -type f \( -name "*.conf" -o -name "*.json" -o -name "*.xml" -o -name "*.ini" \) 2>/dev/null | head -20
echo ""

# Create summary report
echo "📊 Creating analysis report..."
cat > "$ANALYSIS_DIR/ANALYSIS_REPORT.md" << 'EOF'
# Video Station SPK Analysis Report

## Package Structure

EOF

echo "## Extracted Files" >> "$ANALYSIS_DIR/ANALYSIS_REPORT.md"
find . -type f | head -50 >> "$ANALYSIS_DIR/ANALYSIS_REPORT.md"

cat >> "$ANALYSIS_DIR/ANALYSIS_REPORT.md" << 'EOF'

## Key Findings

### API Endpoints
(To be filled in after manual inspection)

### Communication Protocol
(To be filled in after manual inspection)

### Database Schema
(To be filled in after manual inspection)

## Next Steps

1. Inspect web/API files to understand endpoints
2. Analyze communication protocol with DS Video iOS app
3. Document API structure for recreation
EOF

echo "✅ Analysis complete!"
echo ""
echo "📁 Analysis results saved to: $ANALYSIS_DIR"
echo "📄 Report: $ANALYSIS_DIR/ANALYSIS_REPORT.md"
echo ""
echo "🔍 Next steps:"
echo "   1. Inspect package-contents/ for web/API files"
echo "   2. Look for PHP/Python/JavaScript files that handle API requests"
echo "   3. Check for database schemas or configuration files"
echo "   4. Analyze communication protocol with DS Video iOS app"
