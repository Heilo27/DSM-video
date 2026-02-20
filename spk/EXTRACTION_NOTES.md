# Video Station SPK Extraction Notes

## Current Status

The Video Station SPK file (`VideoStation-x86_64-3.1.1-3168.spk`) uses a **custom format** that is not a standard tar.gz archive.

### File Analysis

- **Size**: 27MB
- **Format**: Custom binary format (not standard tar.gz)
- **Magic bytes**: `68 ad be ef 41 40 00 00` (custom header)
- **INFO file**: Successfully extracted (see `videostation-analysis/INFO`)

## Extraction Methods Tried

1. ✅ **Standard tar.gz**: Failed - not a gzip file
2. ✅ **Standard tar**: Failed - unrecognized format  
3. ✅ **Python tarfile**: Failed - cannot open
4. ✅ **7zip**: Not available on system
5. ✅ **INFO extraction**: Successfully extracted INFO file content

## Possible Solutions

### Option 1: Use Synology's Official Tools

The SPK format appears to require Synology's `pkgscripts-ng` toolchain to properly extract:

```bash
# On a Linux system with pkgscripts-ng
pkgscripts-ng/PkgExtract.py VideoStation-x86_64-3.1.1-3168.spk
```

### Option 2: Install on NAS and Examine Installed Files

1. Install Video Station on your NAS (DSM 7.2.1)
2. Examine installed files at `/var/packages/VideoStation/`
3. Copy relevant files for analysis

### Option 3: Use Community Script

The community script at https://github.com/007revad/Video_Station_for_DSM_722 might have extraction methods or already extracted files.

### Option 4: Manual Binary Analysis

Since we can see file content in strings output, we could:
1. Search for specific file signatures (PHP, Python, JavaScript)
2. Extract individual files by finding their boundaries
3. Reconstruct the package structure

## Extracted INFO File

The INFO file has been successfully extracted and saved to:
- `spk/videostation-analysis/INFO`

Key information:
- Package: VideoStation
- Version: 3.1.1-3168
- Architecture: x86_64
- Minimum DSM: 7.2-64570
- UI directory: `ui`
- App name: `SYNO.SDS.VideoStation.AppInstance`

## Next Steps

1. **Try installing on NAS**: Install the SPK on your DS923+ (DSM 7.2.1) and examine `/var/packages/VideoStation/`
2. **Use Docker with pkgscripts-ng**: Build a Docker container with Synology's toolkit
3. **Network traffic analysis**: Monitor communication between DS Video iOS app and Video Station
4. **Community resources**: Check if anyone has already extracted and documented the API

## Alternative Approach

Instead of extracting the SPK, we could:
1. **Network analysis**: Use Wireshark/Charles Proxy to capture API calls
2. **iOS app analysis**: Examine the DS Video iOS app to understand expected API format
3. **Documentation**: Use Synology WebAPI documentation to understand the protocol
4. **Build compatible API**: Implement API based on protocol understanding rather than exact code
