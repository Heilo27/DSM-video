#!/bin/bash
# Automated installation script for DS Video Server backend
# This script will keep trying until successful

set -euo pipefail

NAS_USER="ryan"
NAS_IP="192.168.50.146"
BINARY_PATH="build/spk/DSVideoServer/target/backend/dsvideo-backend"
SCRIPT_PATH="spk/DSVideoServer/scripts/start-stop-status"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "DS Video Server - Automated Installation"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Check if binary exists
if [ ! -f "$REPO_ROOT/$BINARY_PATH" ]; then
    echo "❌ Binary not found: $REPO_ROOT/$BINARY_PATH"
    echo "   Building binary first..."
    cd "$REPO_ROOT"
    bash spk/build-spk.sh x86_64
fi

if [ ! -f "$REPO_ROOT/$BINARY_PATH" ]; then
    echo "❌ Binary still not found after build attempt"
    exit 1
fi

echo "✅ Binary found: $REPO_ROOT/$BINARY_PATH"
echo ""

# Step 1: Upload binary (with password prompt)
echo "Step 1: Uploading binary to NAS..."
echo "───────────────────────────────────────────────────────────────────────────────"
echo "You will be prompted for your NAS password..."
echo ""

if scp "$REPO_ROOT/$BINARY_PATH" "${NAS_USER}@${NAS_IP}:/tmp/dsvideo-backend"; then
    echo "✅ Upload successful!"
else
    echo "❌ Upload failed"
    echo ""
    echo "💡 Alternative: Upload via File Station web interface:"
    echo "   1. Open DSM → File Station"
    echo "   2. Navigate to /tmp/"
    echo "   3. Upload: $REPO_ROOT/$BINARY_PATH"
    echo "   4. Rename to: dsvideo-backend"
    echo ""
    read -p "Press Enter after manual upload, or Ctrl+C to cancel..."
fi

echo ""

# Step 2: Install via SSH
echo "Step 2: Installing backend on NAS..."
echo "───────────────────────────────────────────────────────────────────────────────"
echo "You will be prompted for your NAS password again..."
echo ""

# Create installation commands
INSTALL_SCRIPT=$(cat << 'INSTALLEOF'
#!/bin/bash
set -e

echo "📦 Creating package directories..."
sudo mkdir -p /var/packages/DSVideoServer/target/backend
sudo mkdir -p /var/packages/DSVideoServer/var
sudo mkdir -p /var/packages/DSVideoServer/scripts

echo "📋 Copying binary..."
if [ -f /tmp/dsvideo-backend ]; then
    sudo cp /tmp/dsvideo-backend /var/packages/DSVideoServer/target/backend/
    sudo chmod +x /var/packages/DSVideoServer/target/backend/dsvideo-backend
    echo "✅ Binary copied"
else
    echo "❌ Binary not found at /tmp/dsvideo-backend"
    exit 1
fi

echo "📜 Setting up start script..."
sudo tee /var/packages/DSVideoServer/scripts/start-stop-status > /dev/null << 'SCRIPTEOF'
#!/bin/sh
set -eu

PACKAGE="DSVideoServer"
BASE="/var/packages/${PACKAGE}"
VAR="${BASE}/var"
LOG="/var/log/packages/${PACKAGE}.log"
PIDFILE="${VAR}/server.pid"
GO_BINARY="${BASE}/target/backend/dsvideo-backend"

start() {
  mkdir -p "${VAR}"
  if [ ! -x "${GO_BINARY}" ]; then
    echo "[${PACKAGE}] Binary not found" >> "${LOG}"
    exit 1
  fi
  if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    echo "[${PACKAGE}] already running" >> "${LOG}"
    exit 0
  fi
  export DSVIDEO_PORT="${DSVIDEO_PORT:-8080}"
  export DSVIDEO_BASE_URL="${DSVIDEO_BASE_URL:-http://192.168.50.146:${DSVIDEO_PORT}}"
  export DSVIDEO_DB_PATH="${DSVIDEO_DB_PATH:-${VAR}/dsvideo.db}"
  export DSVIDEO_MOVIES_PATH="${DSVIDEO_MOVIES_PATH:-/volume1/video/Movies}"
  export DSVIDEO_TV_PATH="${DSVIDEO_TV_PATH:-/volume1/video/TV}"
  export DSVIDEO_HOME_PATH="${DSVIDEO_HOME_PATH:-/volume1/video/Home}"
  nohup "${GO_BINARY}" >> "${LOG}" 2>&1 &
  echo $! > "${PIDFILE}"
  echo "[${PACKAGE}] started (pid $(cat "${PIDFILE}"))" >> "${LOG}"
}

stop() {
  if [ ! -f "${PIDFILE}" ]; then
    exit 0
  fi
  PID="$(cat "${PIDFILE}")" || true
  if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" || true
  fi
  rm -f "${PIDFILE}"
  echo "[${PACKAGE}] stopped" >> "${LOG}"
}

status() {
  if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    exit 0
  fi
  exit 1
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|status}" ; exit 2 ;;
esac
SCRIPTEOF
sudo chmod +x /var/packages/DSVideoServer/scripts/start-stop-status

echo "🛑 Stopping any existing instance..."
sudo /var/packages/DSVideoServer/scripts/start-stop-status stop 2>/dev/null || true
sleep 1

echo "🚀 Starting service..."
sudo /var/packages/DSVideoServer/scripts/start-stop-status start

sleep 3

echo "📊 Checking status..."
if sudo /var/packages/DSVideoServer/scripts/start-stop-status status; then
    echo "✅ Service is running!"
    echo ""
    echo "📋 Service info:"
    echo "   Binary: /var/packages/DSVideoServer/target/backend/dsvideo-backend"
    echo "   Log: /var/log/packages/DSVideoServer.log"
    PID=$(cat /var/packages/DSVideoServer/var/server.pid 2>/dev/null || echo "N/A")
    echo "   PID: $PID"
    echo ""
    echo "🌐 Backend URL: http://192.168.50.146:8080"
    echo ""
    echo "📝 To check logs:"
    echo "   tail -f /var/log/packages/DSVideoServer.log"
    echo ""
    echo "📝 To stop:"
    echo "   sudo /var/packages/DSVideoServer/scripts/start-stop-status stop"
    echo ""
    echo "📝 To restart:"
    echo "   sudo /var/packages/DSVideoServer/scripts/start-stop-status stop && sudo /var/packages/DSVideoServer/scripts/start-stop-status start"
    echo ""
    echo "🧪 Testing backend..."
    sleep 1
    if curl -s http://192.168.50.146:8080/api/v1/admin/status > /dev/null 2>&1; then
        echo "✅ Backend is responding!"
    else
        echo "⚠️  Backend may not be responding yet. Check logs:"
        echo "   tail -20 /var/log/packages/DSVideoServer.log"
    fi
else
    echo "❌ Service failed to start"
    echo "📋 Checking logs:"
    sudo tail -30 /var/log/packages/DSVideoServer.log 2>/dev/null || echo "No log file found"
    exit 1
fi
INSTALLEOF
)

# Execute installation
echo "Running installation commands on NAS..."
if ssh "${NAS_USER}@${NAS_IP}" "bash -s" <<< "$INSTALL_SCRIPT"; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "✅ Installation Complete!"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "🌐 Backend URL: http://192.168.50.146:8080"
    echo "📱 iOS App: Set base URL to http://192.168.50.146:8080"
    echo ""
    echo "🧪 Test the backend:"
    echo "   curl http://192.168.50.146:8080/api/v1/admin/status"
    echo ""
    echo "✅ The backend is now running and ready for the iOS app!"
else
    echo ""
    echo "❌ Installation failed. Check the error messages above."
    echo ""
    echo "🔍 Troubleshooting:"
    echo "   1. Check if binary exists: ssh ${NAS_USER}@${NAS_IP} 'ls -lh /tmp/dsvideo-backend'"
    echo "   2. Check logs: ssh ${NAS_USER}@${NAS_IP} 'sudo tail -50 /var/log/packages/DSVideoServer.log'"
    echo "   3. Try manual installation (see MANUAL_INSTALL.md)"
    exit 1
fi
