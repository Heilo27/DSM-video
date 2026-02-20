# Official DS Video App API Analysis

Analysis of Charles Proxy session (`ds video.chlsj`) showing communication between official DS Video app and Video Station.

## Key Findings

### 1. Streaming API - **DIFFERENT ENDPOINT!**

**Official App Uses:**
- **Endpoint**: `/webapi/VideoStation/vtestreaming.cgi/DTV.mov` (NOT `/webapi/entry.cgi`)
- **Method**: GET
- **Query Parameters**: 
  - `api=SYNO.VideoStation.Streaming`
  - `version=1` (NOT version 2!)
  - `method=stream`
  - `id=<stream_id>` (format: `835a107de0363f99687e1f9c23d1ba45_ndABbbGk` - hash with suffix)
  - `format=raw`
  - `_sid=<session_id>`

**Example:**
```
GET /webapi/VideoStation/vtestreaming.cgi/DTV.mov?api=SYNO.VideoStation.Streaming&version=1&method=stream&id=835a107de0363f99687e1f9c23d1ba45_ndABbbGk&format=raw&_sid=...
```

**Our Implementation:**
- Uses `/webapi/entry.cgi` with `SYNO.VideoStation2.Streaming` (version 2)
- This is **WRONG** - we need to use the vtestreaming.cgi endpoint!

### 2. Streaming "Open" Call

**Official App:**
- **Endpoint**: `/webapi/VideoStation/vtestreaming.cgi`
- **Method**: POST
- **Content-Type**: `application/x-www-form-urlencoded`
- **Body**: 110 bytes (form data - likely contains the item ID to get stream_id)

**Our Implementation:**
- Uses `/webapi/entry.cgi` with `method=open`
- This is **WRONG** - we need to use POST to vtestreaming.cgi!

### 3. API Calls Use POST with Form Data

**Official App Pattern:**
- Many API calls use **POST** with `application/x-www-form-urlencoded` body
- Parameters are in the request body, not query string
- Uses cookies for session (`id=<session_id>`)

**Our Implementation:**
- Uses GET with query parameters
- This might work, but POST with form data is the official format

### 4. Session Management

**Official App:**
- Uses **cookies** for session: `id=<session_id>`
- Cookie format: `id=troCObfkuZKsGGcqAUui6BkTlcvqQGu3_xJvFNfHUbkUrpaQLxgX6QWr96UPyq3Do0C6lq_FQvBCHpEqMtx4ik`
- Also uses `_sid` in query parameters for some calls

**Our Implementation:**
- Uses `_sid` in query parameters only
- Should also set cookies for compatibility

### 5. User-Agent

**Official App:**
- User-Agent: `Synology-DS_video_3.4.5_iPhone_iOS_26.3 (iPhone; iOS 26.3)`

**Our Implementation:**
- Uses default URLSession user-agent
- Should match official app's user-agent

## Critical Differences

1. **Streaming endpoint**: `/webapi/VideoStation/vtestreaming.cgi` NOT `/webapi/entry.cgi`
2. **Streaming version**: `version=1` NOT `version=2`
3. **Streaming API name**: `SYNO.VideoStation.Streaming` NOT `SYNO.VideoStation2.Streaming`
4. **Streaming method**: POST to vtestreaming.cgi for "open", then GET to vtestreaming.cgi/DTV.mov for "stream"
5. **Session**: Uses cookies (`id=<session_id>`) in addition to `_sid` query parameter

## What We Need to Fix

1. ✅ Update streaming endpoint to use `/webapi/VideoStation/vtestreaming.cgi`
2. ✅ Change streaming API version from 2 to 1
3. ✅ Change streaming API name from `SYNO.VideoStation2.Streaming` to `SYNO.VideoStation.Streaming`
4. ✅ Implement POST to vtestreaming.cgi for "open" call
5. ✅ Add cookie support for session management
6. ⚠️ Poster API - still need to find the correct format (body data not in capture)

## Next Steps

1. Update streaming implementation to match official app
2. Add cookie-based session management
3. Try POST requests for other APIs (libraries, items, etc.) if GET doesn't work
4. Check Video Station web UI for Poster API format
