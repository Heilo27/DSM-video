#!/bin/bash
# Debug script to check file on NAS

NAS_USER="ryan"
NAS_IP="192.168.50.146"

echo "🔍 Checking files on NAS..."
echo ""

ssh "${NAS_USER}@${NAS_IP}" << 'REMOTEEOF'
echo "Checking /tmp/dsvideo-backend:"
if [ -f "/tmp/dsvideo-backend" ]; then
    echo "✅ File exists"
    ls -lh /tmp/dsvideo-backend
    file /tmp/dsvideo-backend
    echo ""
    echo "File size: $(stat -c%s /tmp/dsvideo-backend 2>/dev/null || stat -f%z /tmp/dsvideo-backend 2>/dev/null) bytes"
else
    echo "❌ File does NOT exist at /tmp/dsvideo-backend"
    echo ""
    echo "Searching for it..."
    find /tmp /volume* -name "dsvideo-backend" 2>/dev/null | head -5
fi

echo ""
echo "Checking script location:"
ls -lh /volume2/Data/tmp/install-on-nas.sh 2>/dev/null || echo "Script not found at /volume2/Data/tmp/install-on-nas.sh"

echo ""
echo "Current user: $(whoami)"
echo "Can read /tmp?: $(test -r /tmp && echo 'yes' || echo 'no')"
REMOTEEOF
