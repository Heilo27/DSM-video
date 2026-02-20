#!/bin/bash
# Helper script to find uploaded files on NAS

NAS_USER="ryan"
NAS_IP="192.168.50.146"

echo "🔍 Searching for uploaded files on NAS..."
echo ""

ssh "${NAS_USER}@${NAS_IP}" << 'REMOTEEOF'
echo "Searching common locations..."
echo ""

# Common locations to check
LOCATIONS=(
    "/tmp"
    "/Data/tmp"
    "/volume1/tmp"
    "/volume1/Data/tmp"
    "/volume1/homes/${USER}/tmp"
    "/var/services/homes/${USER}/tmp"
)

for loc in "${LOCATIONS[@]}"; do
    if [ -d "$loc" ]; then
        echo "📁 Checking: $loc"
        ls -lh "$loc"/*.sh "$loc"/dsvideo-backend 2>/dev/null | grep -E "(install-on-nas|dsvideo-backend)" || echo "   (no matching files)"
        echo ""
    fi
done

echo "🔍 Searching entire filesystem for install-on-nas.sh..."
find /volume* /tmp /Data -name "install-on-nas.sh" 2>/dev/null | head -10

echo ""
echo "🔍 Searching for dsvideo-backend binary..."
find /volume* /tmp /Data -name "dsvideo-backend" 2>/dev/null | head -10

echo ""
echo "📋 Current directory and common paths:"
pwd
echo ""
echo "Shared folders (if accessible):"
ls -ld /volume*/ 2>/dev/null | head -5
REMOTEEOF
