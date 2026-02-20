# Network Capture Guide for Video Station API Analysis

## Overview

This guide helps you capture and analyze API communication between the DS Video iOS app and Video Station running on your NAS.

## Tools

### Option 1: Charles Proxy (Recommended for iOS Simulator)

**Why Charles Proxy?**
- Easy to use GUI
- Great for iOS Simulator
- Can export requests/responses
- SSL/TLS decryption support

**Installation:**
```bash
brew install --cask charles
```

**Setup:**
1. Open Charles Proxy
2. Go to **Proxy → Proxy Settings**
   - Port: `8888` (default)
   - Enable "Enable transparent HTTP proxying"
3. Go to **Proxy → SSL Proxying Settings**
   - Enable "Enable SSL Proxying"
   - Add your NAS IP: `192.168.50.146` (port `443` or `5001`)
4. Configure iOS Simulator:
   ```bash
   # Set proxy for iOS Simulator
   export http_proxy=http://127.0.0.1:8888
   export https_proxy=http://127.0.0.1:8888
   ```

**Capturing:**
1. Start Charles Proxy
2. Clear existing sessions (Proxy → Clear Session)
3. Start recording (should be on by default)
4. Run DS Video iOS app in Xcode Simulator
5. Connect to Video Station on NAS
6. Perform actions (login, browse libraries, play video)
7. Stop recording
8. Export sessions: **File → Export → JSON** or **File → Export → HAR**

### Option 2: mitmproxy (Command-line)

**Installation:**
```bash
brew install mitmproxy
```

**Setup:**
1. Start mitmproxy:
   ```bash
   mitmproxy -p 8888
   ```
2. Configure iOS Simulator to use proxy (same as Charles)
3. Capture traffic
4. Save to file: Press `w` in mitmproxy, enter filename

### Option 3: Wireshark (Advanced)

**Installation:**
```bash
brew install --cask wireshark
```

**Setup:**
1. Open Wireshark
2. Select network interface (usually `en0` for Wi-Fi)
3. Set filter: `host 192.168.50.146`
4. Start capture
5. Run DS Video iOS app
6. Stop capture and save

## iOS Simulator Proxy Configuration

### Method 1: Environment Variables

```bash
# In terminal before launching Xcode
export http_proxy=http://127.0.0.1:8888
export https_proxy=http://127.0.0.1:8888

# Launch Xcode
open -a Xcode
```

### Method 2: Charles Proxy Auto-Configure

Charles Proxy can automatically configure the iOS Simulator:
1. Open Charles Proxy
2. Go to **Help → SSL Proxying → Install Charles Root Certificate in iOS Simulators**
3. Follow the prompts

### Method 3: Manual Simulator Settings

1. Open iOS Simulator
2. Go to **Settings → Wi-Fi**
3. Tap the network (usually "iPhone" or "iPad")
4. Scroll to **HTTP Proxy**
5. Select **Manual**
6. Server: `127.0.0.1`
7. Port: `8888`

## Capturing Video Station API Calls

### Step 1: Prepare

1. **Start network capture tool** (Charles Proxy recommended)
2. **Clear existing sessions**
3. **Start recording**

### Step 2: Connect DS Video App to Video Station

1. **Run DS Video iOS app** in Xcode Simulator
2. **Enter NAS details**:
   - Base URL: `http://192.168.50.146:5000` (or Video Station port)
   - Username: Your DSM username
   - Password: Your DSM password
3. **Login** to Video Station

### Step 3: Perform Actions

Capture these key actions:

1. **Login/Authentication**
   - Watch for login API calls
   - Note session token/cookie handling

2. **Library Listing**
   - Browse libraries (Movies, TV Shows, etc.)
   - Note API endpoints for library listing

3. **Video Listing**
   - List videos in a library
   - Note pagination, filtering

4. **Video Details**
   - Select a video
   - Note metadata API calls

5. **Playback**
   - Start video playback
   - Note streaming URL/endpoint
   - Note progress tracking

6. **Search**
   - Search for videos
   - Note search API format

### Step 4: Export and Analyze

**Charles Proxy:**
1. **File → Export → JSON** (for programmatic analysis)
2. **File → Export → HAR** (for browser analysis)
3. Save to: `tools/captures/videostation-api-YYYYMMDD-HHMMSS.json`

**mitmproxy:**
1. Press `w` to save
2. Enter filename: `tools/captures/videostation-api-YYYYMMDD-HHMMSS.flow`

## Analyzing Captured Traffic

### Key Things to Document

1. **API Endpoints**
   - Base URL pattern
   - Endpoint paths
   - HTTP methods (GET, POST, etc.)

2. **Request Format**
   - Query parameters
   - Headers
   - Body format (JSON, form data, etc.)

3. **Response Format**
   - Response structure
   - Data models
   - Error formats

4. **Authentication**
   - How login works
   - Session management
   - Token format

5. **API Pattern**
   - Is it WebAPI format? (`/webapi/entry.cgi?api=SYNO.API.*`)
   - Or REST API? (`/api/v1/...`)
   - Or custom format?

### Example Analysis

```json
{
  "request": {
    "method": "GET",
    "url": "http://192.168.50.146:5000/webapi/entry.cgi?api=SYNO.API.VideoStation.Library&version=1&method=list&_sid=abc123",
    "headers": {
      "Cookie": "id=abc123"
    }
  },
  "response": {
    "status": 200,
    "body": {
      "data": {
        "libraries": [...]
      },
      "success": true
    }
  }
}
```

## Tools for Analysis

### Automated Analysis Script

Use the provided script to analyze captured traffic:

```bash
./tools/analyze-capture.sh tools/captures/videostation-api-*.json
```

This will:
- Extract API endpoints
- Document request/response formats
- Generate API reference documentation

### Manual Analysis

1. **Filter by Video Station**:
   - In Charles: Filter by `192.168.50.146`
   - Look for `/webapi/` or `/api/` paths

2. **Group by Endpoint**:
   - Group similar requests
   - Identify patterns

3. **Document Findings**:
   - Update `docs/VIDEO_STATION_API_REFERENCE.md`
   - Add endpoint documentation
   - Document data models

## Troubleshooting

### iOS Simulator Not Using Proxy

1. Check environment variables are set
2. Restart Xcode and Simulator
3. Verify proxy settings in Simulator Settings

### SSL/TLS Errors

1. Install Charles Root Certificate in Simulator
2. Enable SSL Proxying for your NAS IP
3. Trust the certificate in Simulator Settings

### No Traffic Captured

1. Verify proxy is running
2. Check proxy port (default 8888)
3. Verify iOS Simulator is using proxy
4. Check firewall settings

## Next Steps

After capturing traffic:

1. **Document API endpoints** in `docs/VIDEO_STATION_API_REFERENCE.md`
2. **Create data models** in `docs/VIDEO_STATION_DATA_MODELS.md`
3. **Update Go backend** to match Video Station API
4. **Test compatibility** with DS Video iOS app

## Resources

- **Charles Proxy Docs**: https://www.charlesproxy.com/documentation/
- **mitmproxy Docs**: https://docs.mitmproxy.org/
- **Wireshark Docs**: https://www.wireshark.org/docs/
