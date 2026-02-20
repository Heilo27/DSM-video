#!/bin/bash
# Create a minimal test SPK to isolate the issue

set -euo pipefail

# Calculate paths before changing directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/spk"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

cd "$TEMP_DIR"

echo "Creating minimal test SPK..."

# Create minimal INFO file (only required fields)
cat > INFO << 'EOF'
package="DSVideoServer"
version="0.1.0"
arch="x86_64"
os_min_ver="7.2-00000"
maintainer="Test"
displayname="DS Video Server"
description="Test"
startable="yes"
thirdparty="yes"
EOF

# Create minimal package.tgz (just an empty var directory)
mkdir -p var
tar czf package.tgz var/

# Create minimal scripts
mkdir -p scripts
cat > scripts/start-stop-status << 'EOF'
#!/bin/sh
case "$1" in
  start) echo "started" ;;
  stop) echo "stopped" ;;
  status) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x scripts/start-stop-status

# Create SPK
tar -cf test-minimal.tar INFO package.tgz scripts/
gzip test-minimal.tar
mv test-minimal.tar.gz test-minimal.spk

# Save to project build directory
mkdir -p "$BUILD_DIR"
cp test-minimal.spk "$BUILD_DIR/"

echo ""
echo "✅ Minimal test SPK created: $BUILD_DIR/test-minimal.spk"
echo ""
echo "Try installing this minimal SPK to see if it works."
echo "If this works, the issue is with our package contents."
echo "If this fails, the issue is with the basic SPK format."
