#!/bin/sh
# CGI proxy for DS Video - handles entry.cgi API calls (JSON responses)
# Invoked by DSM when SYNO.VideoStation2.* APIs are called via /webapi/entry.cgi

BACKEND="http://127.0.0.1:8090/webapi/entry.cgi"

# Build URL with query string
if [ -n "$QUERY_STRING" ]; then
    URL="${BACKEND}?${QUERY_STRING}"
else
    URL="$BACKEND"
fi

# Handle POST or GET
if [ "$REQUEST_METHOD" = "POST" ] && [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    RESPONSE=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null | \
        curl -s -X POST \
        -H "Content-Type: ${CONTENT_TYPE:-application/x-www-form-urlencoded}" \
        -H "X-DSM-Proxy: true" \
        --data-binary @- \
        "$URL")
else
    RESPONSE=$(curl -s -H "X-DSM-Proxy: true" "$URL")
fi

# Output CGI response headers + body
printf 'Content-Type: application/json; charset=utf-8\r\n'
printf '\r\n'
printf '%s' "$RESPONSE"
