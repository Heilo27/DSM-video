# Debugging Poster API

The Poster API is returning `{"error":{"code":120,"errors":{"name":"type","reason":"type"}},"success":false}`.

## Quick Check: What Does Video Station Web UI Use?

The fastest way to figure out the correct format is to check what the Video Station web interface actually uses:

1. **Open Video Station in your browser** (http://192.168.50.146:5000)
2. **Open Developer Tools** (F12 or Cmd+Option+I)
3. **Go to Network tab**
4. **Navigate to a movie** and view its poster
5. **Look for requests to `/webapi/entry.cgi`** with `SYNO.VideoStation2.Poster`
6. **Inspect the request URL** - what parameters does it use?

## What We've Tried

- `type=poster` (string) → Error: "condition"
- `type=1` (numeric) → Error: "type"  
- `type=0` (numeric, 0-indexed) → Testing now

## Possible Solutions

1. **No type parameter** - Maybe the API doesn't need it
2. **Different type values** - Maybe it's `"poster"` and `"backdrop"` as strings but with different encoding
3. **Different API endpoint** - Maybe posters use a different API entirely
4. **Different parameter name** - Maybe it's not `type` but something else

## Next Steps

1. Check Video Station web UI network requests (see above)
2. If that doesn't work, try removing the `type` parameter entirely
3. Try different type values: `"poster"`, `"backdrop"`, `"0"`, `"1"`, `"2"`, etc.
