#!/bin/bash
# Fix Error 263: Rebuild SPK with correct format

set -euo pipefail

cd build/spk

echo "🔧 Fixing Error 263: Rebuilding SPK with correct format..."
echo ""

# Clean up test directory
rm -rf test_error263

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Fix INFO file - ensure no trailing newline and correct format
echo "📄 Fixing INFO file..."
cp DSVideoServer/INFO "$TEMP_DIR/INFO"

# Remove trailing newline
perl -pi -e 'chomp if eof' "$TEMP_DIR/INFO"

# Ensure arch is x86_64
sed -i '' 's/arch="noarch"/arch="x86_64"/' "$TEMP_DIR/INFO" 2>/dev/null || \
sed -i '' 's/arch="noarch"/arch="x86_64"/' "$TEMP_DIR/INFO"

# Verify INFO
echo "INFO file (first 5 lines):"
head -5 "$TEMP_DIR/INFO"
echo ""

# Copy scripts
echo "📜 Copying scripts..."
cp -r DSVideoServer/scripts "$TEMP_DIR/"
chmod +x "$TEMP_DIR/scripts/start-stop-status"

# Create package.tgz
echo "📦 Creating package.tgz..."
cd DSVideoServer
tar -czf "$TEMP_DIR/package.tgz" target/ var/ 2>/dev/null || tar -czf "$TEMP_DIR/package.tgz" target/
cd ..

# Create SPK with correct order: INFO first, then package.tgz, then scripts
echo "📦 Creating SPK..."
cd "$TEMP_DIR"
tar -czf "/Users/home/Documents/DS Video/build/spk/DSVideoServer-0.1.0-x64.spk" \
    --format=ustar \
    INFO package.tgz scripts/

cd "/Users/home/Documents/DS Video/build/spk"

echo "✅ SPK rebuilt!"
echo ""
echo "📋 Verifying structure:"
tar -tzf DSVideoServer-0.1.0-x64.spk
echo ""
echo "📊 File size:"
ls -lh DSVideoServer-0.1.0-x64.spk
