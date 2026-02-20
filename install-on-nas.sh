#!/bin/bash
# Installation script to run ON THE NAS (after uploading binary)
# This version checks multiple possible locations for the files

set -e

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "DS Video Server - NAS Installation Script"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Find binary in common locations
BINARY_LOCATIONS=(
    "/tmp/dsvideo-backend"
    "/Data/tmp/dsvideo-backend"
    "/volume1/tmp/dsvideo-backend"
    "/volume1/Data/tmp/dsvideo-backend"
    "/volume2/tmp/dsvideo-backend"
    "/volume2/Data/tmp/dsvideo-backend"
)

BINARY_PATH=""
for loc in "${BINARY_LOCATIONS[@]}"; do
    if [ -f "$loc" ]; then
        BINARY_PATH="$loc"
        echo "✅ Found binary at: $BINARY_PATH"
        break
    fi
done

if [ -z "$BINARY_PATH" ]; then
    echo "❌ Binary not found in common locations"
    echo ""
    echo "Searched in:"
    for loc in "${BINARY_LOCATIONS[@]}"; do
        echo "   - $loc"
    done
    echo ""
    echo "Please upload the binary to one of these locations, or specify the path:"
    echo "   Usage: $0 [path-to-binary]"
    echo ""
    echo "Example:"
    echo "   sudo $0 /Data/tmp/dsvideo-backend"
    exit 1
fi

# Allow override via command line argument
if [ -n "${1:-}" ] && [ -f "$1" ]; then
    BINARY_PATH="$1"
    echo "✅ Using binary from command line: $BINARY_PATH"
fi

echo ""

# Create directories
echo "📦 Creating package directories..."
sudo mkdir -p /var/packages/DSVideoServer/target/backend
sudo mkdir -p /var/packages/DSVideoServer/var
sudo mkdir -p /var/packages/DSVideoServer/scripts

# Copy binary
echo "📋 Copying binary from $BINARY_PATH..."
sudo cp "$BINARY_PATH" /var/packages/DSVideoServer/target/backend/dsvideo-backend
sudo chmod +x /var/packages/DSVideoServer/target/backend/dsvideo-backend
echo "✅ Binary installed"

# Create start script
echo "📜 Creating start script..."
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
echo "✅ Start script created"

# Stop any existing instance
echo "🛑 Stopping any existing instance..."
sudo /var/packages/DSVideoServer/scripts/start-stop-status stop 2>/dev/null || true
sleep 1

# Start service
echo "🚀 Starting service..."
sudo /var/packages/DSVideoServer/scripts/start-stop-status start

sleep 3

# Check status
echo "📊 Checking status..."
if sudo /var/packages/DSVideoServer/scripts/start-stop-status status; then
    echo "✅ Service is running!"
    echo ""
    PID=$(cat /var/packages/DSVideoServer/var/server.pid 2>/dev/null || echo "N/A")
    echo "📋 Service info:"
    echo "   PID: $PID"
    echo "   Log: /var/log/packages/DSVideoServer.log"
    echo "   Binary: /var/packages/DSVideoServer/target/backend/dsvideo-backend"
    echo ""
    echo "🌐 Backend URL: http://192.168.50.146:8080"
    echo ""
    echo "🧪 Testing backend..."
    sleep 2
    if curl -s http://192.168.50.146:8080/api/v1/admin/status > /dev/null 2>&1; then
        echo "✅ Backend is responding!"
        echo ""
        echo "📱 iOS App Configuration:"
        echo "   Base URL: http://192.168.50.146:8080"
    else
        echo "⚠️  Backend may not be responding yet"
        echo "   Check logs: tail -f /var/log/packages/DSVideoServer.log"
    fi
else
    echo "❌ Service failed to start"
    echo "📋 Checking logs:"
    sudo tail -30 /var/log/packages/DSVideoServer.log 2>/dev/null || echo "No log file found"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "✅ Installation Complete!"
echo "═══════════════════════════════════════════════════════════════════════════════"
