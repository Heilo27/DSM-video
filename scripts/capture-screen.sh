#!/bin/bash
# Capture one design-evidence screenshot of a demo-mode screen on a booted simulator.
#
#   scripts/capture-screen.sh <udid> <screen> <out.png> [theme]
#
#   screen: home | movieDetail | showDetail | moviesGrid | showsGrid   (DSShotScreen.swift)
#   theme:  classic | redesign | cinematic (default cinematic)
#
# The app must already be installed on the simulator as a Debug build (the hook is compiled out
# of Release). The simulator must already be booted: this never boots or shuts anything down.
# It waits for the app's own "READY" log line, so the shot is of loaded content, not a skeleton.
# Look at the PNG afterwards; a ready line does not prove the picture is meaningful.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <udid> <screen> <out.png> [theme]" >&2
  exit 2
fi
udid="$1"; screen="$2"; out="$3"; theme="${4:-cinematic}"
bundle="HeiloProjects.DSReel"
if ! xcrun simctl get_app_container "$udid" "$bundle" app >/dev/null 2>&1; then
  echo "$bundle is not installed on $udid (build and install the Debug app first)" >&2
  exit 1
fi

log="$(mktemp -t dsshot)"
xcrun simctl spawn "$udid" log stream --level info --predicate 'subsystem == "com.dsm.shot"' >"$log" 2>&1 &
logpid=$!
trap 'kill "$logpid" 2>/dev/null || true; rm -f "$log"' EXIT
sleep 1

xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
xcrun simctl launch "$udid" "$bundle" -UITestDemoMode -UITestResetState \
  -dsReel.theme "$theme" -DSShotScreen "$screen" >/dev/null

for _ in $(seq 1 60); do
  if grep -q "DSShotScreen $screen READY" "$log"; then
    xcrun simctl io "$udid" screenshot "$out"
    echo "captured $out"
    exit 0
  fi
  if grep -q "FAILED" "$log"; then
    grep FAILED "$log" >&2
    exit 1
  fi
  sleep 0.5
done
echo "timed out waiting for DSShotScreen $screen READY" >&2
exit 1
