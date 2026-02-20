# Charles Proxy Capture Analysis

Analysis of network traffic between original Video Station app and DS Video clone.

## Key Findings

### 1. Poster API (`SYNO.VideoStation2.Poster`)

**Original App Behavior:**
- Uses `mapper_id` (not item `id`) for poster requests
- Example: `id=21186` (which is `mapper_id` from list response)
- Does NOT send `type` parameter
- **But API returns error**: `{"error":{"code":120,"errors":{"name":"type","reason":"required"}},"success":false}`

**Our Implementation:**
- ✅ Now uses `mapper_id` for poster/backdrop IDs
- ✅ Added `type` parameter (required by API)
- ⚠️ Even original app gets errors - suggests Video Station on NAS may need configuration

### 2. Item Details API (`SYNO.VideoStation2.Movie/TVShow.getinfo`)

**Original App Behavior:**
- Uses `id` parameter (NOT `mapper_id`)
- Tries both with and without `library_id=0`
- Tries both Movie and TVShow APIs
- **All attempts return empty arrays**: `{"data":{"movie":[]},"success":true}`

**Our Implementation:**
- ✅ Already tries `id` with/without `library_id`
- ✅ Already tries both Movie and TVShow APIs
- ⚠️ Returns empty arrays - suggests metadata not loaded in Video Station

**Key Insight:** `mapper_id` does NOT work for getinfo - API returns error saying `id` is required.

### 3. Streaming API (`SYNO.VideoStation2.Streaming`)

**Original App Attempts (all fail):**
1. `method=open&id=1442` → Error: `file` required
2. `method=open&file={"id":1442}` → Error 1101 (file not found)
3. `method=open&file={"id":1442,"library_id":0}` → Error 1101 (file not found)
4. `method=stream&id=1442` → Error: `stream_id` required
5. Back to `method=open&id=1442` → Error: `file` required

**Our Implementation:**
- ✅ Already tries all these combinations
- ⚠️ All fail with error 1101 - suggests files not indexed or accessible

**Key Insight:** `method=open` requires `file` parameter (JSON), not `id` directly. But even with `file`, it fails with 1101.

### 4. Items List API (`SYNO.VideoStation2.Movie.list`)

**Original App Behavior:**
- ✅ Works correctly
- Returns items with both `id` and `mapper_id`
- Example response includes: `{"id":1442,"mapper_id":21186,...}`

**Our Implementation:**
- ✅ Works correctly
- ✅ Now uses `mapper_id` for poster/backdrop image IDs

## Summary

**What Works:**
- ✅ Login
- ✅ Libraries list
- ✅ Items list (with `id` and `mapper_id`)

**What Doesn't Work (even in original app):**
- ❌ Poster API - returns "type required" error
- ❌ Item details - returns empty arrays
- ❌ Streaming - all attempts fail with error 1101

**Conclusion:**
The Video Station on the NAS appears to have configuration or indexing issues. Even the original Video Station app cannot:
- Load posters (API error)
- Get item details (empty arrays)
- Stream videos (file not found errors)

**Recommendations:**
1. Check Video Station configuration on NAS
2. Verify video files are properly indexed
3. Check file permissions
4. Consider re-indexing the video library
5. Verify Video Info Plugin is installed and working

## Code Changes Made

1. **Poster/Backdrop IDs**: Changed to always prefer `mapper_id` over `poster`/`backdrop` fields
2. **Poster API**: Already includes `type` parameter (required)
3. **getinfo API**: Already uses `id` (not `mapper_id`) - correct
4. **Streaming API**: Already tries all combinations - correct

The code now matches the original app's behavior, but the underlying Video Station API issues remain.
