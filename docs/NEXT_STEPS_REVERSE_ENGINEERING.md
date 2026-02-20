# Next Steps for Video Station Reverse Engineering

## Current Status

✅ **Downloaded**: Video Station SPK (3.1.1-3168, x86_64, 27MB)
✅ **Extracted**: INFO file with package metadata
❌ **Full extraction**: SPK uses custom format, requires Synology tools

## Recommended Approach

Since direct SPK extraction is challenging, we'll use a **multi-pronged approach**:

### Step 1: Install Video Station on NAS and Examine Files

**On your DS923+ (DSM 7.2.1):**

```bash
# 1. Install Video Station SPK (if not already installed)
# Upload via Package Center or SSH

# 2. SSH into NAS
ssh ryan@192.168.50.146

# 3. Examine installed files
sudo ls -la /var/packages/VideoStation/
sudo find /var/packages/VideoStation/ -type f | head -50

# 4. Find API/web files
sudo find /var/packages/VideoStation/ -type f \( -name "*.php" -o -name "*.py" -o -name "*.js" \) | head -30

# 5. Look for WebAPI handlers
sudo grep -r "SYNO.API.VideoStation" /var/packages/VideoStation/ 2>/dev/null | head -20

# 6. Check UI directory (from INFO: dsmuidir="ui")
sudo ls -la /var/packages/VideoStation/ui/
sudo find /var/packages/VideoStation/ui/ -name "*.php" -o -name "*.js" | head -20
```

**Copy relevant files for analysis:**
```bash
# Create analysis directory
mkdir -p ~/videostation-analysis

# Copy API files
sudo cp -r /var/packages/VideoStation/ui/ ~/videostation-analysis/
sudo find /var/packages/VideoStation/ -name "*api*" -o -name "*webapi*" | xargs -I {} sudo cp {} ~/videostation-analysis/ 2>/dev/null
```

### Step 2: Network Traffic Analysis

**Capture API calls between DS Video iOS app and Video Station:**

1. **Using Charles Proxy** (recommended):
   - Install Charles Proxy on Mac
   - Configure iOS simulator to use proxy
   - Run DS Video iOS app
   - Connect to Video Station
   - Capture all HTTP/HTTPS requests
   - Document endpoints, methods, parameters, responses

2. **Using Wireshark**:
   - Capture network traffic on NAS or router
   - Filter for HTTP/HTTPS to Video Station port
   - Analyze API calls

3. **Using browser DevTools** (if Video Station has web UI):
   - Open Video Station in browser
   - Use DevTools → Network tab
   - Capture API calls

### Step 3: Analyze iOS App Code

**Examine your DS Video iOS app to understand expected API:**

```bash
cd "/Users/home/Documents/DS Video/DS Video clone"
```

**Key files to examine:**
- `DSVideo/Networking/APIClient.swift` - API client implementation
- `DSVideo/Models/APIModels.swift` - Data models (shows expected response format)
- `DSVideo/Views/*.swift` - UI code (shows what data is needed)

**Look for:**
- API endpoint patterns
- Request/response formats
- Authentication mechanism
- Data structures

### Step 4: Document API Protocol

Create comprehensive API documentation:

1. **API Endpoint Reference** (`docs/VIDEO_STATION_API_REFERENCE.md`):
   - List all endpoints
   - Request/response formats
   - Authentication requirements
   - Example requests/responses

2. **Data Models** (`docs/VIDEO_STATION_DATA_MODELS.md`):
   - Video metadata structure
   - Library structure
   - User/session data
   - Playback progress

3. **Authentication Flow** (`docs/VIDEO_STATION_AUTH.md`):
   - Login process
   - Session management
   - Token handling

### Step 5: Implement Compatible API

Update your Go backend to match Video Station's API:

**Option A: WebAPI Compatibility Layer**
- Add `/webapi/entry.cgi` endpoint
- Support `SYNO.API.VideoStation.*` format
- Maintain REST API for new features

**Option B: Update iOS App**
- Modify iOS app to use new REST API (`/api/v1/...`)
- Keep Video Station compatibility during migration

**Option C: Dual API Support**
- Support both WebAPI and REST API
- Gradually migrate iOS app

## Tools Created

- ✅ `spk/download-videostation.sh` - Download SPK
- ✅ `spk/analyze-video-station.sh` - Analyze SPK structure
- ✅ `spk/videostation-analysis/INFO` - Extracted INFO file
- ✅ `docs/VIDEO_STATION_REVERSE_ENGINEERING.md` - Complete guide
- ✅ `docs/VIDEO_STATION_API_PROTOCOL.md` - API protocol analysis

## Immediate Action Items

1. **Install Video Station on NAS** (if not already)
2. **Examine installed files** at `/var/packages/VideoStation/`
3. **Set up network capture** (Charles Proxy or Wireshark)
4. **Run DS Video iOS app** and capture API calls
5. **Document findings** in API reference documents

## Expected API Format

Based on Synology WebAPI standard:

```
GET /webapi/entry.cgi?api=SYNO.API.VideoStation.List&version=1&method=list&_sid=<session_id>
```

Your backend currently uses:
```
GET /api/v1/libraries
```

You'll need to either:
- Add WebAPI compatibility layer, or
- Update iOS app to use REST API

## Resources

- **Synology WebAPI Guide**: `docs/explorations/EXP-Synology-WebAPI-Auth-and-FileStation.md`
- **Video Station Analysis**: `spk/videostation-analysis/FINDINGS.md`
- **Extraction Notes**: `spk/EXTRACTION_NOTES.md`
