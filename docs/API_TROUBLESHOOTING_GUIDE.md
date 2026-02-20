# Video Station API Troubleshooting Guide

Since we can't use Charles Proxy, here's a systematic approach to diagnose and fix the API issues.

## Current Issues

1. **Poster API**: Returns "type required" error even though we're sending `type=poster`
2. **getinfo API**: Returns empty arrays `{"data":{"movie":[]}}`
3. **Streaming API**: Returns error 1101 (file not found)

## Diagnostic Tools

### 1. Test Script
Use the test script to test API calls directly:
```bash
./tools/test-videostation-api.sh <NAS_IP> <USERNAME> <PASSWORD> [ITEM_ID]
```

This will test all API endpoints and show exact responses.

### 2. Browser Developer Tools
1. Open Video Station web interface in browser
2. Open Developer Tools (F12)
3. Go to Network tab
4. Navigate to a movie, try to play it, view poster
5. Look for `/webapi/entry.cgi` requests
6. Inspect request parameters and responses

### 3. Direct cURL Testing
Test individual API calls:
```bash
# Login
curl "http://NAS_IP:5000/webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=login&account=USERNAME&passwd=PASSWORD"

# Get poster (with type)
curl -I "http://NAS_IP:5000/webapi/entry.cgi?api=SYNO.VideoStation2.Poster&version=1&method=get&id=MAPPER_ID&type=poster&_sid=SID"

# Get item detail
curl "http://NAS_IP:5000/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=getinfo&id=ITEM_ID&library_id=0&_sid=SID"
```

## Potential Issues & Solutions

### Issue 1: Poster API "type required" Error

**Possible Causes:**
- Parameter encoding issue
- Wrong parameter name
- API version mismatch
- Missing required parameter

**Things to Try:**
1. Check if `type` parameter needs to be URL-encoded differently
2. Try `type=1` or `type=2` instead of `type=poster`
3. Check Video Station web interface to see what it sends
4. Try without `width` parameter
5. Verify we're using the correct `id` (should be `mapper_id`)

### Issue 2: getinfo Returns Empty Arrays

**Possible Causes:**
- Items not fully indexed
- Metadata not loaded
- Wrong API parameters
- Items exist but have no metadata

**Things to Try:**
1. Check Video Station web interface - do items show details there?
2. Verify items are fully indexed (check Video Station settings)
3. Try using `mapper_id` instead of `id` (though previous capture showed this fails)
4. Check if Video Info Plugin is installed and working
5. Try re-indexing the library

### Issue 3: Streaming Error 1101 (File Not Found)

**Possible Causes:**
- File not indexed/accessible
- Wrong file path
- Permissions issue
- File format not supported
- Transcoding not available

**Things to Try:**
1. Verify file exists and is accessible via File Station
2. Check file permissions
3. Verify Video Station has access to the file location
4. Check if file format is supported
5. Try a different file/item
6. Check Video Station logs on NAS

## Next Steps

1. **Run Test Script**: Execute `./tools/test-videostation-api.sh` to see exact API responses
2. **Inspect Web Interface**: Use browser dev tools to see how Video Station web UI makes API calls
3. **Check NAS Logs**: Look at Video Station logs on the NAS for errors
4. **Verify Configuration**: Ensure Video Station is properly configured and indexed

## Alternative Approaches

If API issues persist:

1. **Check Video Station Version**: Ensure you're using a compatible version
2. **Re-index Library**: Force Video Station to re-index all media
3. **Check Permissions**: Ensure Video Station service has proper file access
4. **Install Video Info Plugin**: May be required for metadata
5. **Check File Formats**: Ensure files are in supported formats

## Resources

- Synology File Station API Guide (similar structure): https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf
- Community libraries: `syno` npm package, `synologydsm-api` Python package
- Video Info Plugin: https://github.com/C5H12O5/syno-videoinfo-plugin
