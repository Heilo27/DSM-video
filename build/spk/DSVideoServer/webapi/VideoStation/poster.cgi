#!/bin/sh
# CGI proxy for DS Video - handles poster image requests (binary responses)
# The official DS Video app calls /webapi/VideoStation/poster.cgi directly

BACKEND="http://127.0.0.1:8090/webapi/VideoStation/poster.cgi"

if [ -n "$QUERY_STRING" ]; then
    URL="${BACKEND}?${QUERY_STRING}"
else
    URL="$BACKEND"
fi

# Use a temp file for binary content
TMPFILE=$(mktemp /tmp/dsvideo_poster.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

# Fetch the image from our backend
HTTP_CODE=$(curl -s -o "$TMPFILE" -w '%{http_code}' -H "X-DSM-Proxy: true" "$URL")

if [ "$HTTP_CODE" = "200" ]; then
    # Detect content type from file
    printf 'Content-Type: image/jpeg\r\n'
    printf '\r\n'
    cat "$TMPFILE"
else
    # Return a transparent 1x1 pixel on error
    printf 'Content-Type: image/png\r\n'
    printf 'Status: 404 Not Found\r\n'
    printf '\r\n'
fi
