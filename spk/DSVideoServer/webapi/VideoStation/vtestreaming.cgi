#!/bin/sh
# CGI proxy for DS Video - handles video streaming requests
# The official DS Video app calls /webapi/VideoStation/vtestreaming.cgi/DTV.mov

BACKEND="http://127.0.0.1:8080/webapi/VideoStation/vtestreaming.cgi"

# Append PATH_INFO (e.g., /DTV.mov)
TARGET_PATH="$BACKEND"
if [ -n "$PATH_INFO" ]; then
    TARGET_PATH="${TARGET_PATH}${PATH_INFO}"
fi

if [ -n "$QUERY_STRING" ]; then
    URL="${TARGET_PATH}?${QUERY_STRING}"
else
    URL="$TARGET_PATH"
fi

# For streaming, we pipe directly (no temp file - could be huge)
# Output NPH (Non-Parsed Headers) style - let curl handle headers
printf 'Content-Type: video/mp4\r\n'
printf 'Transfer-Encoding: chunked\r\n'
printf '\r\n'

# Stream the response body directly to stdout
curl -s -H "X-DSM-Proxy: true" "$URL"
