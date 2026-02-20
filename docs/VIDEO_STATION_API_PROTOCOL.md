# Video Station API Protocol Analysis

## Overview

This document captures findings from reverse engineering Video Station to understand how DS Video iOS app communicates with the server.

## API Format: Synology WebAPI

Video Station uses Synology's standard WebAPI format, similar to File Station and other Synology packages.

### Base Endpoint

```
GET/POST /webapi/entry.cgi
```

### Request Format

```
GET /webapi/entry.cgi?api=SYNO.API.VideoStation.<Method>&version=<version>&method=<action>&<params>
```

### Authentication

Video Station uses DSM authentication via `SYNO.API.Auth`:

1. **Login**:
   ```
   GET /webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=login&account=<USERNAME>&passwd=<PASSWORD>
   ```

2. **Response includes**:
   - `sid`: Session ID (use as `&_sid=<sid>` in subsequent requests)
   - `synotoken`: CSRF token (use as `&SynoToken=<token>`)

3. **Subsequent API calls**:
   ```
   GET /webapi/entry.cgi?api=SYNO.API.VideoStation.List&version=1&method=list&_sid=<sid>&SynoToken=<token>
   ```

## Expected Video Station APIs

Based on DS Video iOS app functionality, Video Station likely exposes:

### Library Management

- `SYNO.API.VideoStation.Library` - List libraries (Movies, TV Shows, etc.)
- `SYNO.API.VideoStation.Library.List` - List items in a library
- `SYNO.API.VideoStation.Library.Info` - Get library information

### Video Metadata

- `SYNO.API.VideoStation.Video.List` - List videos
- `SYNO.API.VideoStation.Video.Info` - Get video details
- `SYNO.API.VideoStation.Video.Search` - Search videos

### Playback

- `SYNO.API.VideoStation.Video.Stream` - Get streaming URL
- `SYNO.API.VideoStation.Video.Transcode` - Request transcoding
- `SYNO.API.VideoStation.Video.Progress` - Get/set playback progress

### Thumbnails/Artwork

- `SYNO.API.VideoStation.Thumb` - Get thumbnail images
- `SYNO.API.VideoStation.Poster` - Get poster images

## Investigation Steps

### 1. Extract SPK and Find API Files

```bash
cd "/Users/home/Documents/DS Video"
./spk/download-videostation.sh x64
./spk/analyze-video-station.sh spk/videostation-downloads/VideoStation-x64-3.1.1-3168.spk
```

### 2. Search for API Definitions

After extraction, search for:
- PHP files with `SYNO.API.VideoStation`
- JavaScript files making API calls
- Configuration files defining API routes

### 3. Network Traffic Analysis

**Using DS Video iOS app:**
1. Run app in Xcode simulator
2. Enable network logging
3. Connect to Video Station
4. Capture all HTTP requests
5. Document API calls and responses

**Using browser (if Video Station has web UI):**
1. Open Video Station in browser
2. Use DevTools → Network tab
3. Capture API calls
4. Document endpoints

### 4. Reverse Engineer from iOS App

Your iOS app (`DS Video clone/DSVideo/Networking/APIClient.swift`) may already have clues:
- Check what endpoints it expects
- Look for API path patterns
- Identify request/response formats

## Current Backend Compatibility

Your Go backend (`backend/cmd/dsvideo-backend/main.go`) currently uses:
- REST API format: `/api/v1/...`
- JSON request/response
- JWT authentication

**To make it compatible with DS Video iOS app**, you may need to:

1. **Option A**: Add WebAPI compatibility layer
   - Implement `/webapi/entry.cgi` endpoint
   - Support `SYNO.API.VideoStation.*` format
   - Maintain REST API for new features

2. **Option B**: Update iOS app to use new REST API
   - Modify `APIClient.swift` to use `/api/v1/...` endpoints
   - Keep Video Station compatibility for migration period

3. **Option C**: Dual API support
   - Support both WebAPI and REST API
   - Gradually migrate iOS app to REST API

## Next Steps

1. ✅ Download Video Station SPK
2. ✅ Extract and analyze structure
3. ⏳ Identify API endpoints in code
4. ⏳ Document request/response formats
5. ⏳ Test with DS Video iOS app
6. ⏳ Implement compatible API in Go backend

## Resources

- **Synology WebAPI Guide**: See `docs/explorations/EXP-Synology-WebAPI-Auth-and-FileStation.md`
- **DSM Developer Guide**: https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Developer_Guide_7_enu.pdf
- **Video Station Archive**: https://archive.synology.com/download/Package/VideoStation/
