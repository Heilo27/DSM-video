#!/bin/bash
# Find Video Station's port and API endpoints

set -euo pipefail

NAS_IP="${1:-192.168.50.146}"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Finding Video Station Port and Configuration"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "🔍 Checking NAS: $NAS_IP"
echo ""

# Common Video Station ports
PORTS=(5000 9080 5001 9081)

echo "📡 Testing common Video Station ports..."
echo ""

for port in "${PORTS[@]}"; do
    echo -n "   Testing http://${NAS_IP}:${port}... "
    if curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://${NAS_IP}:${port}" | grep -q "200\|301\|302\|401\|403"; then
        echo "✅ RESPONDING"
        
        # Try WebAPI endpoint
        echo -n "      Testing WebAPI... "
        webapi_response=$(curl -s --max-time 2 "http://${NAS_IP}:${port}/webapi/entry.cgi?api=SYNO.API.Info&version=1&method=query" 2>/dev/null || echo "")
        if echo "$webapi_response" | grep -q "success\|SYNO"; then
            echo "✅ WebAPI available"
            echo "      Response: ${webapi_response:0:200}..."
        else
            echo "❌ No WebAPI response"
        fi
    else
        echo "❌ No response"
    fi
done

echo ""
echo "🔍 Checking via SSH (if available)..."
echo ""

# Try SSH to check Video Station status
if ssh -o ConnectTimeout=2 -o BatchMode=yes "${NAS_USER:-ryan}@${NAS_IP}" "echo 'Connected'" 2>/dev/null; then
    echo "✅ SSH connection successful"
    echo ""
    echo "📋 Video Station status:"
    ssh "${NAS_USER:-ryan}@${NAS_IP}" "sudo synopkg status VideoStation 2>/dev/null || echo 'Video Station not found or not running'" 2>/dev/null || echo "   (Could not get status)"
    echo ""
    echo "🌐 Network connections:"
    ssh "${NAS_USER:-ryan}@${NAS_IP}" "sudo netstat -tlnp 2>/dev/null | grep -i video || echo '   (Could not check network connections)'" 2>/dev/null || echo "   (Could not check)"
else
    echo "❌ SSH not available (password/key required)"
    echo "   Run manually: ssh ryan@${NAS_IP}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Manual Check"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "1. Open DSM web interface:"
echo "   http://${NAS_IP}:5000"
echo ""
echo "2. Go to Package Center → Video Station → Open"
echo "   (This will show the Video Station URL)"
echo ""
echo "3. Or check Video Station settings in DSM"
echo ""
