# Video Station API Discovery

## Current Status

✅ **Video Station Found**: `http://192.168.50.146:5000`
✅ **WebAPI Available**: `/webapi/entry.cgi`
❌ **App Connection**: Failing due to API format mismatch

## Problem

- **iOS App**: Uses REST API (`/api/v1/auth/login`)
- **Video Station**: Uses Synology WebAPI (`/webapi/entry.cgi?api=SYNO.API.*`)

## Solution: Discover Video Station APIs

### Step 1: Query Available APIs

```bash
curl "http://192.168.50.146:5000/webapi/entry.cgi?api=SYNO.API.Info&version=1&method=query"
```

This will show all available APIs. Look for `SYNO.API.VideoStation.*` entries.

### Step 2: Test Authentication

```bash
# Login
curl "http://192.168.50.146:5000/webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=login&account=<USERNAME>&passwd=<PASSWORD>"

# Response should include:
# {
#   "success": true,
#   "data": {
#     "sid": "abc123...",
#     "synotoken": "xyz789..."
#   }
# }
```

### Step 3: Discover Video Station Endpoints

Once logged in, try to discover Video Station APIs:

```bash
# Get Video Station API info
curl "http://192.168.50.146:5000/webapi/entry.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.VideoStation"&_sid=<SESSION_ID>

# Try common Video Station endpoints:
# - SYNO.API.VideoStation.Library
# - SYNO.API.VideoStation.Video
# - SYNO.API.VideoStation.List
```

### Step 4: Use Official DS Video App

The easiest way is to:
1. Install official DS Video app from App Store
2. Connect to Video Station
3. Use Charles Proxy to capture API calls
4. See exactly what endpoints and format it uses

## Next Steps

1. **Discover Video Station APIs** (see commands above)
2. **Update iOS app** to use WebAPI format, or
3. **Create compatibility layer** in backend to translate REST → WebAPI

## Created Files

- `DSVideo/Networking/VideoStationWebAPIClient.swift` - WebAPI client (partial implementation)
- This document - Discovery guide
