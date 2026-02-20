# Quick Start: Network Capture for Video Station API

## Step 1: Install Charles Proxy

```bash
brew install --cask charles
```

## Step 2: Configure Charles Proxy

1. **Open Charles Proxy**
   ```bash
   open -a Charles
   ```

2. **Configure SSL Proxying** (to decrypt HTTPS):
   - Go to **Proxy → SSL Proxying Settings**
   - Check **"Enable SSL Proxying"**
   - Click **"Add"**
   - Host: `192.168.50.146`
   - Port: `443` (or `5001` for DSM)
   - Click **"OK"**

3. **Clear existing sessions**:
   - Go to **Proxy → Clear Session**

## Step 3: Configure iOS Simulator

**Option A: Auto-configure (Easiest)**
1. In Charles: **Help → SSL Proxying → Install Charles Root Certificate in iOS Simulators**
2. Follow the prompts

**Option B: Manual**
1. In iOS Simulator: **Settings → Wi-Fi**
2. Tap your network
3. Scroll to **HTTP Proxy**
4. Select **Manual**
5. Server: `127.0.0.1`
6. Port: `8888`

## Step 4: Start Capturing

1. **Ensure Charles is recording** (should be on by default)
2. **Run DS Video iOS app** in Xcode Simulator
3. **Connect to Video Station**:
   - Base URL: `http://192.168.50.146:5000` (or your Video Station port)
   - Login with your DSM credentials
4. **Perform actions**:
   - Browse libraries
   - List videos
   - Play a video
   - Search for content

## Step 5: Export Capture

1. **Stop recording** in Charles
2. **Export session**:
   - **File → Export → JSON**
   - Save to: `tools/captures/videostation-api-YYYYMMDD-HHMMSS.json`

## Step 6: Analyze Capture

```bash
./tools/analyze-capture.sh tools/captures/videostation-api-*.json
```

This will generate `docs/api-analysis/api-analysis.md` with API endpoint documentation.

## Alternative: Examine Video Station Files on NAS

If you want to examine Video Station's installed files directly:

```bash
./tools/examine-videostation-nas.sh
```

This will:
- SSH into your NAS
- Find Video Station files
- Extract API references
- Download analysis results to `docs/videostation-nas-analysis/`

## Troubleshooting

### Charles Proxy Not Capturing

1. Check proxy is running (should show "Recording" in status bar)
2. Verify iOS Simulator proxy settings
3. Check firewall isn't blocking port 8888

### SSL/TLS Errors

1. Install Charles Root Certificate in Simulator
2. Trust the certificate in Simulator Settings → General → About → Certificate Trust Settings

### No Traffic to Video Station

1. Verify Video Station is running on NAS
2. Check the correct port (usually 5000 or 9080)
3. Verify network connectivity

## Next Steps

After capturing:
1. Review `docs/api-analysis/api-analysis.md`
2. Update `docs/VIDEO_STATION_API_REFERENCE.md` with findings
3. Implement compatible API in Go backend
