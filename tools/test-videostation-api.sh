#!/bin/bash
# Test Video Station API calls directly
# Usage: ./test-videostation-api.sh <NAS_IP> <USERNAME> <PASSWORD> [ITEM_ID]

set -e

NAS_IP="${1:-192.168.50.146}"
USERNAME="${2}"
PASSWORD="${3}"
ITEM_ID="${4:-909}"  # Default to item 909

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Usage: $0 <NAS_IP> <USERNAME> <PASSWORD> [ITEM_ID]"
    exit 1
fi

BASE_URL="http://${NAS_IP}:5000"

echo "🔐 Step 1: Login..."
LOGIN_RESPONSE=$(curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=login&account=${USERNAME}&passwd=${PASSWORD}")
echo "$LOGIN_RESPONSE" | python3 -m json.tool
SID=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data', {}).get('sid', ''))")

if [ -z "$SID" ]; then
    echo "❌ Login failed!"
    exit 1
fi

echo ""
echo "✅ Login successful! SID: ${SID:0:20}..."
echo ""

echo "📚 Step 2: Get Libraries..."
curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Library&version=1&method=list&_sid=${SID}" | python3 -m json.tool
echo ""

echo "🎬 Step 3: Get Items (first 5)..."
curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=list&library_id=0&limit=5&offset=0&_sid=${SID}" | python3 -m json.tool | head -50
echo ""

echo "🔍 Step 4: Get Item Detail (id=${ITEM_ID})..."
echo "Attempt 1: id with library_id"
curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=getinfo&id=${ITEM_ID}&library_id=0&_sid=${SID}" | python3 -m json.tool
echo ""

echo "Attempt 2: id without library_id"
curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=getinfo&id=${ITEM_ID}&_sid=${SID}" | python3 -m json.tool
echo ""

# Get mapper_id from items list
echo "Getting mapper_id for item ${ITEM_ID}..."
ITEMS_RESPONSE=$(curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=list&library_id=0&limit=200&offset=0&_sid=${SID}")
MAPPER_ID=$(echo "$ITEMS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('data', {}).get('movie', [])
for item in items:
    if str(item.get('id')) == '${ITEM_ID}':
        print(item.get('mapper_id', ''))
        break
")

if [ -n "$MAPPER_ID" ]; then
    echo "Attempt 3: mapper_id=${MAPPER_ID} with library_id"
    curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=getinfo&mapper_id=${MAPPER_ID}&library_id=0&_sid=${SID}" | python3 -m json.tool
    echo ""
    
    echo "🖼️ Step 5: Get Poster (mapper_id=${MAPPER_ID})..."
    echo "Attempt 1: id=${MAPPER_ID}, type=poster"
    curl -I -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Poster&version=1&method=get&id=${MAPPER_ID}&type=poster&width=400&_sid=${SID}" | head -10
    echo ""
    
    echo "Attempt 2: id=${MAPPER_ID}, no type parameter"
    curl -I -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Poster&version=1&method=get&id=${MAPPER_ID}&width=400&_sid=${SID}" | head -10
    echo ""
fi

echo "🎥 Step 6: Test Streaming (id=${ITEM_ID})..."
echo "Attempt 1: method=open with id"
curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Streaming&version=2&method=open&id=${ITEM_ID}&_sid=${SID}" | python3 -m json.tool
echo ""

echo "Attempt 2: method=open with file JSON"
curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Streaming&version=2&method=open&file=%7B%22id%22:${ITEM_ID}%7D&_sid=${SID}" | python3 -m json.tool
echo ""

echo "Attempt 3: method=open with file JSON + library_id"
curl -s "${BASE_URL}/webapi/entry.cgi?api=SYNO.VideoStation2.Streaming&version=2&method=open&file=%7B%22id%22:${ITEM_ID},%22library_id%22:0%7D&_sid=${SID}" | python3 -m json.tool
echo ""

echo "✅ Testing complete!"
