#!/bin/bash
# Smoke-test DSVideoServer's Video Station WebAPI compatibility layer against a NAS.
#
# This exercises the same high-level flow the official DS Video iOS app uses:
# - WebAPI discovery (query.cgi)
# - Login (SYNO.API.Auth)
# - Library + movie listing (SYNO.VideoStation2.*)
# - Streaming open -> vtestreaming.cgi range fetch
#
# Usage: ./tools/test-dsvideo-webapi.sh <NAS_IP> <USERNAME> <PASSWORD> [http|https]
set -euo pipefail

NAS_IP="${1:-192.168.50.146}"
USERNAME="${2:-}"
PASSWORD="${3:-}"
SCHEME="${4:-https}" # DS Video typically uses https

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
  echo "Usage: $0 <NAS_IP> <USERNAME> <PASSWORD> [http|https]" >&2
  exit 1
fi

UA="DS.video iOS"
PORT_HTTP=5000
PORT_HTTPS=5001

if [ "$SCHEME" = "http" ]; then
  BASE_URL="http://${NAS_IP}:${PORT_HTTP}"
  CURL_TLS=()
else
  BASE_URL="https://${NAS_IP}:${PORT_HTTPS}"
  CURL_TLS=(-k)
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cookies="$tmpdir/cookies.txt"
hdrs="$tmpdir/headers.txt"

echo "== 1) query.cgi discovery (UA=$UA) =="
query_json="$tmpdir/query.json"
curl -sS "${CURL_TLS[@]}" -A "$UA" \
  "${BASE_URL}/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all" \
  -o "$query_json"
python3 - "$query_json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path))
apis=data.get("data",{}) if data.get("success") else {}
need=["SYNO.VideoStation2.Library","SYNO.VideoStation2.Movie","SYNO.VideoStation2.Streaming"]
for n in need:
  if n not in apis:
    raise SystemExit(f"missing API in discovery: {n}")
print("ok: discovery includes VideoStation2 APIs")
PY

echo "== 2) login (SYNO.API.Auth) =="
login_json="$tmpdir/login.json"
curl -sS "${CURL_TLS[@]}" -A "$UA" -D "$hdrs" -c "$cookies" \
  --data-urlencode "api=SYNO.API.Auth" \
  --data-urlencode "version=7" \
  --data-urlencode "method=login" \
  --data-urlencode "account=${USERNAME}" \
  --data-urlencode "passwd=${PASSWORD}" \
  --data-urlencode "session=VideoStation" \
  --data-urlencode "format=sid" \
  "${BASE_URL}/webapi/entry.cgi" >"$login_json"

SID="$(python3 - <<PY
import json
print(json.load(open("$login_json")).get("data",{}).get("sid",""))
PY
)"
if [ -z "$SID" ]; then
  echo "Login failed:" >&2
  cat "$login_json" >&2
  exit 2
fi
echo "ok: sid=${SID:0:12}..."

echo "== 3) library.list =="
libs_json="$tmpdir/libs.json"
curl -sS "${CURL_TLS[@]}" -A "$UA" -b "$cookies" \
  "${BASE_URL}/webapi/DSVideoServer/entry.cgi?api=SYNO.VideoStation2.Library&version=1&method=list&_sid=${SID}" \
  -o "$libs_json"
python3 -m json.tool <"$libs_json" | sed -n '1,80p'

echo "== 4) movie.list (first 5) =="
movies_json="$tmpdir/movies.json"
curl -sS "${CURL_TLS[@]}" -A "$UA" -b "$cookies" \
  "${BASE_URL}/webapi/DSVideoServer/entry.cgi?api=SYNO.VideoStation2.Movie&version=1&method=list&library_id=0&limit=5&offset=0&_sid=${SID}" \
  >"$movies_json"
python3 -m json.tool <"$movies_json" | sed -n '1,120p'

ITEM_ID="$(python3 - <<PY
import json
data=json.load(open("$movies_json"))
items=data.get("data",{}).get("movie",[])
print(items[0].get("id","") if items else "")
PY
)"
if [ -z "$ITEM_ID" ]; then
  echo "No movies returned; skipping streaming test." >&2
  exit 0
fi
echo "picked item id=$ITEM_ID"

echo "== 5) streaming.open (file JSON) =="
open_json="$tmpdir/open.json"
curl -sS "${CURL_TLS[@]}" -A "$UA" -b "$cookies" \
  --data-urlencode "api=SYNO.VideoStation2.Streaming" \
  --data-urlencode "version=2" \
  --data-urlencode "method=open" \
  --data-urlencode "file={\"id\":${ITEM_ID}}" \
  --data-urlencode "_sid=${SID}" \
  "${BASE_URL}/webapi/DSVideoServer/entry.cgi" >"$open_json"

STREAM_ID="$(python3 - <<PY
import json
print(json.load(open("$open_json")).get("data",{}).get("stream_id",""))
PY
)"
if [ -z "$STREAM_ID" ]; then
  echo "stream open failed:" >&2
  cat "$open_json" >&2
  exit 3
fi
echo "ok: stream_id=${STREAM_ID:0:12}..."

echo "== 6) vtestreaming.cgi range fetch (expects 206) =="
status="$(curl -sS "${CURL_TLS[@]}" -A "$UA" -b "$cookies" \
  -H "Range: bytes=0-1023" \
  -o /dev/null -w "%{http_code}" \
  "${BASE_URL}/webapi/VideoStation/vtestreaming.cgi/DTV.mov?api=SYNO.VideoStation.Streaming&method=stream&id=${STREAM_ID}&format=raw&_sid=${SID}")"
echo "http_status=$status"
if [ "$status" != "206" ] && [ "$status" != "200" ]; then
  exit 4
fi

echo "ok: WebAPI compatibility flow completed"
