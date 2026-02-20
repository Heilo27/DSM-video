#!/bin/bash
# Script to examine Video Station installation on NAS

set -euo pipefail

NAS_USER="ryan"
NAS_IP="192.168.50.146"
VS_PATH="/var/packages/VideoStation"
OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/videostation-nas-analysis"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Examining Video Station Installation on NAS"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "📡 NAS: ${NAS_USER}@${NAS_IP}"
echo "📁 Video Station path: ${VS_PATH}"
echo "💾 Output directory: ${OUTPUT_DIR}"
echo ""

mkdir -p "$OUTPUT_DIR"

echo "🔍 Gathering Video Station information..."
echo ""

# Create analysis script to run on NAS
cat > /tmp/analyze-vs.sh << 'NASSCRIPT'
#!/bin/sh
VS_PATH="/var/packages/VideoStation"
OUTPUT="/tmp/vs-analysis"

mkdir -p "$OUTPUT"

echo "=== Video Station Directory Structure ===" > "$OUTPUT/structure.txt"
find "$VS_PATH" -type d | head -50 >> "$OUTPUT/structure.txt"

echo "" >> "$OUTPUT/structure.txt"
echo "=== All Files ===" >> "$OUTPUT/structure.txt"
find "$VS_PATH" -type f | head -100 >> "$OUTPUT/structure.txt"

echo "=== PHP Files ===" > "$OUTPUT/php-files.txt"
find "$VS_PATH" -name "*.php" >> "$OUTPUT/php-files.txt"

echo "=== Python Files ===" > "$OUTPUT/python-files.txt"
find "$VS_PATH" -name "*.py" >> "$OUTPUT/python-files.txt"

echo "=== JavaScript Files ===" > "$OUTPUT/js-files.txt"
find "$VS_PATH" -name "*.js" >> "$OUTPUT/js-files.txt"

echo "=== API References ===" > "$OUTPUT/api-references.txt"
grep -r "SYNO.API.VideoStation" "$VS_PATH" 2>/dev/null | head -50 >> "$OUTPUT/api-references.txt"
grep -r "webapi" "$VS_PATH" 2>/dev/null | head -50 >> "$OUTPUT/api-references.txt"
grep -r "/api/" "$VS_PATH" 2>/dev/null | head -50 >> "$OUTPUT/api-references.txt"

echo "=== UI Directory Contents ===" > "$OUTPUT/ui-contents.txt"
if [ -d "$VS_PATH/ui" ]; then
    find "$VS_PATH/ui" -type f | head -50 >> "$OUTPUT/ui-contents.txt"
fi

echo "=== Configuration Files ===" > "$OUTPUT/config-files.txt"
find "$VS_PATH" -name "*.conf" -o -name "*.json" -o -name "*.xml" -o -name "*.ini" | head -30 >> "$OUTPUT/config-files.txt"

echo "Analysis complete. Files saved to $OUTPUT"
NASSCRIPT

echo "📤 Uploading analysis script to NAS..."
scp /tmp/analyze-vs.sh "${NAS_USER}@${NAS_IP}:/tmp/analyze-vs.sh"

echo "🔧 Running analysis on NAS..."
ssh "${NAS_USER}@${NAS_IP}" "chmod +x /tmp/analyze-vs.sh && sudo /tmp/analyze-vs.sh"

echo "📥 Downloading analysis results..."
scp "${NAS_USER}@${NAS_IP}:/tmp/vs-analysis/*" "$OUTPUT_DIR/" 2>/dev/null || {
    # Try with sudo
    ssh "${NAS_USER}@${NAS_IP}" "sudo tar -czf /tmp/vs-analysis.tar.gz -C /tmp vs-analysis"
    scp "${NAS_USER}@${NAS_IP}:/tmp/vs-analysis.tar.gz" "$OUTPUT_DIR/"
    cd "$OUTPUT_DIR" && tar -xzf vs-analysis.tar.gz && mv vs-analysis/* . && rmdir vs-analysis 2>/dev/null || true
}

echo ""
echo "✅ Analysis complete!"
echo "📁 Results saved to: $OUTPUT_DIR"
echo ""
echo "📋 Files created:"
ls -lh "$OUTPUT_DIR" | tail -n +2 | awk '{print "   " $9 " (" $5 ")"}'

echo ""
echo "🔍 Next steps:"
echo "   1. Review structure.txt for directory layout"
echo "   2. Check api-references.txt for API endpoints"
echo "   3. Examine ui-contents.txt for web interface files"
echo "   4. Review php-files.txt, python-files.txt, js-files.txt for code files"
