#!/bin/bash
# Create minimal SPK that Synology can parse
# Based on Synology's requirements

set -euo pipefail

cd build/spk

echo "🔧 Creating minimal SPK with Synology-compatible format..."
echo ""

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Create INFO file with exact format (no trailing newline, Unix LF)
cat > "$TEMP_DIR/INFO" << 'INFOEOF'
package="DSVideoServer"
version="0.1.0"
arch="x86_64"
os_min_ver="7.2-00000"
maintainer="DS Video Clone"
displayname="DS Video Server"
description="DS Video Server backend"
support_center="no"
reloadui="yes"
startable="yes"
ctl_stop="yes"
ctl_uninstall="yes"
install_type="install"
thirdparty="yes"
INFOEOF

# Remove trailing newline
perl -pi -e 'chomp if eof' "$TEMP_DIR/INFO"

# Copy scripts
cp -r DSVideoServer/scripts "$TEMP_DIR/"
chmod +x "$TEMP_DIR/scripts/start-stop-status"

# Create package.tgz
cd DSVideoServer
tar -czf "$TEMP_DIR/package.tgz" target/ var/ 2>/dev/null || tar -czf "$TEMP_DIR/package.tgz" target/
cd ..

# Create SPK using GNU tar format (more compatible)
cd "$TEMP_DIR"
# Use gzip with no timestamp for reproducibility
gzip -n -c <(tar -cf - INFO package.tgz scripts/) > "/Users/home/Documents/DS Video/build/spk/DSVideoServer-0.1.0-x64.spk"

cd "/Users/home/Documents/DS Video/build/spk"

echo "✅ Minimal SPK created!"
ls -lh DSVideoServer-0.1.0-x64.spk
echo ""
echo "📋 Structure:"
tar -tzf DSVideoServer-0.1.0-x64.spk
