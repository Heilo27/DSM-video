# Video Station SPK Analysis Findings

## Date: 2026-01-14

## Package Information

**File**: `VideoStation-x86_64-3.1.1-3168.spk`
**Size**: 27MB
**Format**: Custom binary format (not standard tar.gz)

## Extracted INFO File

```
package="VideoStation"
version="3.1.1-3168"
maintainer="Synology Inc."
arch="x86_64"
firmware="7.2-64570"
dsmuidir="ui"
dsmappname="SYNO.SDS.VideoStation.AppInstance"
allow_altport="true"
support_center="yes"
install_dep_services="pgsql-adapter.service"
startstop_restart_services="nginx.service"
start_dep_services="pgsql-adapter.service"
silent_install="yes"
silent_upgrade="yes"
silent_uninstall="yes"
support_aaprofile="yes"
os_min_ver="7.2-64570"
log_whitelist="/var/packages/VideoStation/target/etc/log_whitelist"
```

### Key Observations

1. **UI Directory**: `ui` - Web interface files likely here
2. **App Name**: `SYNO.SDS.VideoStation.AppInstance` - Synology's app framework
3. **Dependencies**: 
   - `pgsql-adapter.service` - PostgreSQL database
   - `nginx.service` - Web server
4. **Installation Path**: `/var/packages/VideoStation/`

## File Format Analysis

- **Magic bytes**: `68 ad be ef 41 40 00 00` (custom header)
- **Not standard tar.gz**: Cannot extract with standard tools
- **Contains compressed data**: Found gzip and bzip2 signatures, but in custom format
- **Requires Synology tools**: Likely needs `pkgscripts-ng` to extract properly

## Alternative Approaches

Since direct extraction is challenging, here are alternative methods to understand Video Station:

### 1. Install and Examine on NAS

```bash
# On your DS923+ (DSM 7.2.1)
# Install Video Station SPK
# Then examine installed files:
ssh ryan@192.168.50.146
sudo ls -la /var/packages/VideoStation/
sudo find /var/packages/VideoStation/ -type f -name "*.php" -o -name "*.py" -o -name "*.js" | head -20
```

### 2. Network Traffic Analysis

Monitor API calls between DS Video iOS app and Video Station:

- Use Charles Proxy or Wireshark
- Capture HTTP/HTTPS requests
- Document API endpoints and formats
- Analyze request/response structures

### 3. iOS App Analysis

Examine your DS Video iOS app code:
- `DS Video clone/DSVideo/Networking/APIClient.swift` - API client
- `DS Video clone/DSVideo/Models/APIModels.swift` - Data models
- Understand expected API format from client side

### 4. Synology WebAPI Documentation

Use Synology's WebAPI documentation:
- Base format: `/webapi/entry.cgi?api=SYNO.API.*`
- Video Station likely uses: `SYNO.API.VideoStation.*`
- See: `docs/explorations/EXP-Synology-WebAPI-Auth-and-FileStation.md`

## Recommended Next Steps

1. **Install Video Station on NAS** and examine installed files
2. **Network analysis** - Capture API traffic
3. **Document API protocol** based on network traffic and iOS app
4. **Implement compatible API** in Go backend

## Files Created

- `INFO` - Extracted INFO file
- `FINDINGS.md` - This document
- `../EXTRACTION_NOTES.md` - Extraction attempts and notes
