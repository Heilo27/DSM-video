# Video Station API Issues and Solutions

## Current Status

### ✅ Working
- **Login**: Successfully authenticates with Video Station
- **Libraries**: Successfully lists all libraries (Movie, TVShow, Home Video, TV Recording)
- **Items List**: Successfully lists movies and TV shows with metadata

### ❌ Not Working
- **Posters**: Fixed - API requires `type` parameter (now added)
- **Item Details**: `getinfo` API returns empty arrays `{"data":{"movie":[]}}`
- **Streaming**: Error 1101 ("file not found") when trying to open stream

## API Errors Found

### 1. Poster API Error
**Error**: `{"error":{"code":120,"errors":{"name":"type","reason":"required"}},"success":false}`

**Solution**: Added `type` parameter to `imageURL()` function:
- `type="poster"` for poster images
- `type="backdrop"` for backdrop images

**Status**: ✅ Fixed

### 2. Streaming API Error 1101
**Error**: `{"error":{"code":1101},"success":false}`

**Meaning**: "File not found" - The item cannot be accessed for streaming.

**Possible Causes**:
1. Items may not be fully indexed in Video Station
2. Items may not have file paths accessible
3. User permissions may not allow streaming
4. Items may need to be re-indexed

**Attempted Solutions**:
- ✅ Tried `file={"id":<id>}`
- ✅ Tried `file={"id":<id>,"library_id":0}`
- ❌ All attempts return error 1101

**Next Steps**:
1. Check Video Station indexing status
2. Verify file permissions
3. Try using actual file paths instead of IDs
4. Check if items need to be re-indexed

### 3. Item Details API Returns Empty Arrays
**Error**: `{"data":{"movie":[]},"success":true}`

**Meaning**: The API accepts the request but returns no data.

**Possible Causes**:
1. Items may not be accessible via `getinfo` API
2. Items may need different parameters
3. Items may not have metadata loaded

**Attempted Solutions**:
- ✅ Tried `id` with `library_id=0`
- ✅ Tried `id` without `library_id`
- ✅ Tried `mapper_id` (but API requires `id`)
- ❌ All attempts return empty arrays

**Next Steps**:
1. Check if items have metadata in Video Station web UI
2. Try re-indexing items in Video Station
3. Check Video Station logs for errors
4. Verify Video Info Plugin is installed and working

## Video Station Configuration Checklist

### Required for Full Functionality:
1. ✅ Video Station installed and running
2. ⚠️ Video Info Plugin installed and configured
3. ⚠️ Media folders indexed by Video Station
4. ⚠️ User has permissions to access videos
5. ⚠️ Items have metadata loaded

### How to Check:
1. **Video Info Plugin**: Video Station > Settings > Video Info Plugin
2. **Indexing**: DSM Control Panel > Indexing Service
3. **Permissions**: Control Panel > User & Group > [User] > Applications > Video Station
4. **Metadata**: Open Video Station web UI and check if movies show posters/descriptions

## API Parameter Reference

### Poster API (Fixed)
```
GET /webapi/entry.cgi?api=SYNO.VideoStation2.Poster&version=1&method=get&id=<id>&type=poster&width=400&_sid=<sid>
```

### Streaming API (Still Investigating)
```
POST /webapi/entry.cgi?api=SYNO.VideoStation2.Streaming&version=2&method=open&file={"id":<id>}&_sid=<sid>
```

### Item Details API (Still Investigating)
```
GET /webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=getinfo&id=<id>&library_id=0&_sid=<sid>
```

## Recommendations

1. **Check Video Station Web UI**: Verify that items show posters, descriptions, and can be played in the web interface
2. **Re-index Library**: Try re-indexing the video library in Video Station
3. **Check Logs**: Review Video Station logs for any errors
4. **Verify Permissions**: Ensure the user account has full access to Video Station
5. **Test with Official DS Video App**: If available, test if the official DS Video app works with your Video Station

## Next Steps

1. ✅ Fixed poster API (added `type` parameter)
2. ⏳ Investigate streaming error 1101 - may require Video Station configuration
3. ⏳ Investigate item details empty arrays - may require Video Station configuration
4. ⏳ Test with Video Station web UI to verify items are accessible
