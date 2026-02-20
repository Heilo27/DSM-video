# Debugging Video Station API Responses

## Problem

Getting "Failed to decode response" error means the response format doesn't match our models.

## Solution: Capture Actual API Responses

### Step 1: Test Login API

```bash
# Replace YOUR_USER and YOUR_PASS with your DSM credentials
curl -s "http://192.168.50.146:5000/webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=login&account=YOUR_USER&passwd=YOUR_PASS" | python3 -m json.tool
```

**Expected response:**
```json
{
  "success": true,
  "data": {
    "sid": "abc123...",
    "synotoken": "xyz789..."
  }
}
```

**Save the `sid` value for next steps.**

### Step 2: Test Library API

```bash
# Replace SESSION_ID with the sid from login
curl -s "http://192.168.50.146:5000/webapi/entry.cgi?api=SYNO.VideoStation2.Library&version=1&method=list&_sid=SESSION_ID" | python3 -m json.tool > library_response.json
```

**Check the structure:**
- Does it have `data.libraries` array?
- What fields does each library have?
- Are IDs integers or strings?

### Step 3: Test Movie/TV Show API

```bash
# Get a library ID from step 2, then:
curl -s "http://192.168.50.146:5000/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=list&library_id=1&limit=5&_sid=SESSION_ID" | python3 -m json.tool > movie_response.json
```

**Check the structure:**
- Does it have `data.items` or `data.movies`?
- What fields does each item have?
- Are IDs integers or strings?

### Step 4: Check Console Logs

When you run the app, check Xcode console for:
```
⚠️ Failed to decode response. URL: ...
⚠️ Response: ...
```

This will show the actual response that failed to decode.

## Common Issues

### Issue 1: Response structure is different

**Solution:** Update the data models in `VideoStationWebAPIClient.swift` to match the actual structure.

### Issue 2: Field names are different

**Solution:** The models now try multiple field names. If still failing, check the actual response and add the correct field name.

### Issue 3: Data types don't match

**Solution:** The models now handle both Int and String for IDs. If other fields have type mismatches, update the models.

## Quick Fix Script

Save this as `test-videostation-api.sh`:

```bash
#!/bin/bash
NAS_IP="192.168.50.146"
read -p "DSM Username: " USERNAME
read -sp "DSM Password: " PASSWORD
echo ""

# Login
echo "Logging in..."
LOGIN_RESPONSE=$(curl -s "http://${NAS_IP}:5000/webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=login&account=${USERNAME}&passwd=${PASSWORD}")
echo "$LOGIN_RESPONSE" | python3 -m json.tool

# Extract session ID
SID=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['sid'])" 2>/dev/null)

if [ -z "$SID" ]; then
    echo "❌ Login failed!"
    exit 1
fi

echo ""
echo "✅ Session ID: $SID"
echo ""

# Test Library API
echo "Testing Library API..."
curl -s "http://${NAS_IP}:5000/webapi/entry.cgi?api=SYNO.VideoStation2.Library&version=1&method=list&_sid=${SID}" | python3 -m json.tool > library_response.json
echo "✅ Saved to library_response.json"

# Test Movie API (if library exists)
echo ""
echo "Testing Movie API..."
curl -s "http://${NAS_IP}:5000/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=list&library_id=1&limit=5&_sid=${SID}" | python3 -m json.tool > movie_response.json
echo "✅ Saved to movie_response.json"

echo ""
echo "📋 Review the JSON files to see the actual response structure"
```

## Next Steps

1. **Run the test script** to capture actual responses
2. **Compare with models** in `VideoStationWebAPIClient.swift`
3. **Update models** to match actual structure
4. **Test again** in the app
