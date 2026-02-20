# Video Station Reverse Engineering Guide

## Goal

Reverse engineer Video Station to understand:
1. **API endpoints** it exposes to DS Video iOS app
2. **Communication protocol** (HTTP/HTTPS, WebSocket, etc.)
3. **Data formats** (JSON, XML, etc.)
4. **Authentication mechanism**
5. **Streaming protocol** (HLS, DASH, direct streaming, etc.)
6. **Database schema** (metadata storage)

## Step 1: Download Video Station SPK

Video Station packages are available from Synology's archive:

- **Archive URL**: https://archive.synology.com/download/Package/VideoStation/
- **Recommended Version**: 3.1.1-3168 (last version before DSM 7.3)
- **Architecture**: x86_64 (for DS923+)

### Automated Download

Use the download script:

```bash
cd "/Users/home/Documents/DS Video"
./spk/download-videostation.sh x64
```

This will download `VideoStation-x64-3.1.1-3168.spk` to `spk/videostation-downloads/`

### Manual Download Links:
- **x86_64**: https://archive.synology.com/download/Package/VideoStation/3.1.1-3168/VideoStation-x64-3.1.1-3168.spk
- **ARM64**: https://archive.synology.com/download/Package/VideoStation/3.1.1-3168/VideoStation-armv8-3.1.1-3168.spk

### Alternative: Use Community Script
There's a community script that installs Video Station on DSM 7.2.2+:
- **GitHub**: https://github.com/007revad/Video_Station_for_DSM_722
- This script may also provide insights into Video Station's structure

## Step 2: Extract and Analyze SPK

Use the analysis script:

```bash
cd "/Users/home/Documents/DS Video"
./spk/analyze-video-station.sh /path/to/VideoStation-x64-3.1.1-3168.spk
```

This will:
1. Extract the SPK package
2. Extract `package.tgz` contents
3. Identify scripts, web files, and API files
4. Create an analysis report

## Step 3: Key Areas to Investigate

### 3.1 API Endpoints

Video Station likely uses **Synology WebAPI** format (`SYNO.API.*`), similar to other Synology packages.

**Based on your existing research** (`docs/explorations/EXP-Synology-WebAPI-Auth-and-FileStation.md`):
- Base endpoint: `/webapi/entry.cgi`
- API format: `?api=SYNO.API.VideoStation.*&version=X&method=...`
- Authentication: Uses `SYNO.API.Auth` (session ID `sid`)

Look for:
- PHP files in `web/` or `ui/` directories handling `/webapi/entry.cgi`
- Python files in `scripts/` or `bin/` directories
- JavaScript files that make API calls
- Configuration files that define routes

**Common locations:**
- `/webapi/entry.cgi` - Synology's standard API endpoint pattern
- `SYNO.VideoStation.*` - Video Station specific APIs
- PHP files handling WebAPI requests

### 3.2 Communication Protocol

Video Station likely uses:
- **Synology WebAPI** (`SYNO.API.*`) - Synology's standard API format
- **REST API** - JSON over HTTP/HTTPS
- **WebSocket** - For real-time updates (playback progress, etc.)

**Investigation steps:**
1. Monitor network traffic between DS Video iOS app and Video Station
2. Use browser dev tools if Video Station has a web interface
3. Inspect API request/response formats in code

### 3.3 Authentication

Video Station likely:
- Uses DSM authentication (`SYNO.API.Auth`)
- Issues session tokens
- Supports QuickConnect

**Look for:**
- Authentication scripts
- Token generation/validation code
- Session management

### 3.4 Streaming Protocol

Video Station likely supports:
- **Direct streaming** - Serves video files directly
- **Transcoding** - Converts video on-the-fly
- **HLS** - HTTP Live Streaming
- **Progressive download** - Standard HTTP range requests

**Investigation:**
- Check transcoding scripts
- Look for FFmpeg or similar tools
- Inspect streaming endpoint handlers

### 3.5 Database Schema

Video Station stores:
- Video metadata (title, description, duration, etc.)
- Library structure (Movies, TV Shows, etc.)
- Playback progress
- User preferences

**Look for:**
- SQLite database files
- Database initialization scripts
- Schema definitions

## Step 4: Network Traffic Analysis

### Using iOS App

1. **Enable network logging** in Xcode:
   - Run DS Video iOS app in simulator
   - Use Network Link Conditioner or Charles Proxy
   - Capture all HTTP/HTTPS requests

2. **Analyze requests:**
   - Identify API endpoints
   - Document request/response formats
   - Note authentication headers

### Using Browser Dev Tools

If Video Station has a web interface:
1. Open Video Station in browser
2. Use browser DevTools → Network tab
3. Capture API calls
4. Document endpoints and payloads

## Step 5: Document Findings

Create documentation for:
1. **API Endpoint Reference** - All endpoints, methods, parameters
2. **Data Models** - Request/response structures
3. **Authentication Flow** - How login/session works
4. **Streaming Protocol** - How video streaming works
5. **Database Schema** - Tables and relationships

## Step 6: Recreate Functionality

Based on findings, implement in your Go backend:
1. **API endpoints** matching Video Station's interface
2. **Authentication** compatible with DS Video iOS app
3. **Streaming** that works with iOS video players
4. **Metadata** storage matching expected format

## Resources

- **Synology WebAPI Documentation**: https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/WebAPI/enu/20170309_Web_API_Developer_Guide.pdf
- **Video Station Community Script**: https://github.com/007revad/Video_Station_for_DSM_722
- **Synology Developer Guide**: https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Developer_Guide_7_enu.pdf

## Legal Considerations

⚠️ **Important**: 
- Video Station is proprietary software
- Reverse engineering is for **interoperability purposes** only
- Do not redistribute Video Station code
- Create your own implementation based on protocol understanding
- This is for creating a compatible replacement, not copying Video Station

## Current Project Status

Your DS Video clone already has:
- ✅ API structure defined (`docs/api/DSVideoBackendAPI.md`)
- ✅ iOS app with API client (`DS Video clone/DSVideo/Networking/APIClient.swift`)
- ✅ Go backend with basic endpoints (`backend/cmd/dsvideo-backend/main.go`)

**Next steps:**
1. Analyze Video Station SPK to understand exact API format
2. Update backend to match Video Station's API protocol
3. Ensure iOS app compatibility with both old Video Station and new backend
