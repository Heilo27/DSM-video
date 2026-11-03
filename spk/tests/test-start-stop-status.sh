#!/bin/sh
# Shell-level tests for spk/DSVideoServer/scripts/start-stop-status (TASK-1080, FRD-003).
#
# No NAS, no root, no real server: the script is sourced (DSVIDEO_SSS_SOURCE_ONLY=1) with
# DSVIDEO_PROC_ROOT pointed at a fake /proc built per test, and kill/sleep stubbed so nothing
# real is signalled. Covers port-holder classification (the incident), the never-kill-a-
# foreign-holder rule, the manifest gate and the 0600 tightening.
#
# Run: sh spk/tests/test-start-stop-status.sh        (exit 0 = all passed)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${HERE}/../DSVideoServer/scripts/start-stop-status"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sss-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT INT TERM
ME="$(id -u)"
OTHER=$((ME + 1))          # a uid that is certainly not ours
[ "${OTHER}" -ne 0 ] || OTHER=1

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
expect() { # expect "description" "expected" "actual"
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
expect_contains() { # expect_contains "description" "needle" "haystack"
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no '$2' in: $3)" ;; esac
}

# ---- fixture builders -------------------------------------------------------------------
TCP_HEADER='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
# tcp_row <family:4|6> <hexport> <state> <uid> <inode>
tcp_row() {
  if [ "$1" = 4 ]; then addr="0100007F:$2"; else addr="00000000000000000000000001000000:$2"; fi
  printf '   0: %s 00000000:0000 %s 00000000:00000000 00:00000000 00000000 %5s        0 %s 1 0000000000000000 100 0 0 10 0\n' \
    "${addr}" "$3" "$4" "$5"
}
# new_proc <name>: fresh fake /proc + package base; sets P (proc root), B (pkg base)
new_proc() {
  P="${WORK}/$1/proc"; B="${WORK}/$1/pkg"
  mkdir -p "${P}/net" "${B}/var" "${B}/target"
  printf '%s\n' "${TCP_HEADER}" > "${P}/net/tcp"
  cp "${P}/net/tcp" "${P}/net/tcp6"
  printf 'version="0.3.9-0009"\n' > "${B}/INFO"
}
# add_proc <pid> <exe-name> <uid> <inode>: a process owning the socket inode
add_proc() {
  mkdir -p "${P}/$1/fd"
  ln -s "/volume1/@appstore/DSVideoServer/backend/$2" "${P}/$1/exe"
  ln -s "socket:[$4]" "${P}/$1/fd/7"
  printf '%s' "$2" | cut -c1-15 > "${P}/$1/comm"
  printf '%s\0--port\0%s\0' "/volume1/@appstore/DSVideoServer/backend/$2" "8090" > "${P}/$1/cmdline"
  printf 'Name:\t%s\nState:\tS (sleeping)\nPPid:\t1\nUid:\t%s\t%s\t%s\t%s\n' "$2" "$3" "$3" "$3" "$3" > "${P}/$1/status"
}
# run_in_script '<shell body>': source the script against the current fixture, run the body in
# a subshell with kill and sleep stubbed, print its stdout. The body is a string of shell.
run_in_script() {
  (
    export DSVIDEO_SSS_SOURCE_ONLY=1 DSVIDEO_PROC_ROOT="${P}" DSVIDEO_PKG_BASE="${B}"
    unset DSVIDEO_PORT
    . "${SCRIPT}"
    KILLLOG="${B}/kills"; : > "${KILLLOG}"
    sleep() { :; }
    # A stubbed kill that "works": it records the call and removes the process and its
    # listening socket from the fixture, the way a real kill ends both.
    kill() {
      echo "$*" >> "${KILLLOG}"
      for _a in "$@"; do last="${_a}"; done
      rm -rf "${P:?}/${last}"
      printf '%s\n' "${TCP_HEADER}" > "${P}/net/tcp"
    }
    set +e
    eval "$1"
  )
}

echo "== port hex (the incident: 0x2392 is 9106, not 8090) =="
new_proc hex
out="$(run_in_script 'printf "%04X" 8090')"
expect "8090 renders as 1F9A" "1F9A" "${out}"
out="$(run_in_script 'printf "%04X" 80')"
expect "port 80 is zero-padded to 0050" "0050" "${out}"

echo "== classification =="
new_proc free
{ tcp_row 4 2392 0A 0 555; tcp_row 4 1F9A 01 "${ME}" 556; } >> "${P}/net/tcp"   # decoy port; non-LISTEN row
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE"')"
expect "no listener on 8090 (decoy 0x2392, ESTABLISHED row ignored) is free" "free" "${out}"

new_proc ours4
tcp_row 4 1F9A 0A "${ME}" 1111 >> "${P}/net/tcp"; add_proc 4242 dsvideo-backend "${ME}" 1111
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE $HOLDER_PID $HOLDER_UID"')"
expect "own dsvideo-backend over IPv4 is ours, with pid and uid" "ours 4242 ${ME}" "${out}"

new_proc ours6
tcp_row 6 1F9A 0A "${ME}" 2222 >> "${P}/net/tcp6"; add_proc 4343 dsvideo-backend "${ME}" 2222
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE $HOLDER_PID"')"
expect "own dsvideo-backend over IPv6 (tcp6) is ours" "ours 4343" "${out}"

new_proc root
tcp_row 4 1F9A 0A 0 3333 >> "${P}/net/tcp"        # root holder: /proc/PID/fd not visible, no process dir
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE uid=$HOLDER_UID pid=[$HOLDER_PID]"')"
expect "root-owned holder is foreign, uid read from /proc/net/tcp, pid unresolvable" "foreign uid=0 pid=[]" "${out}"

new_proc otheruid
tcp_row 4 1F9A 0A "${OTHER}" 4444 >> "${P}/net/tcp"; add_proc 5151 dsvideo-backend "${OTHER}" 4444
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE $HOLDER_UID"')"
expect "a dsvideo-backend under ANOTHER uid is foreign (uid decides, not the name)" "foreign ${OTHER}" "${out}"

new_proc sameuid_other
tcp_row 4 1F9A 0A "${ME}" 5555 >> "${P}/net/tcp"; add_proc 6161 python3 "${ME}" 5555
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE $HOLDER_PID"')"
expect "our uid but another program is foreign" "foreign 6161" "${out}"

new_proc sameuid_hidden
tcp_row 4 1F9A 0A "${ME}" 6666 >> "${P}/net/tcp"
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE"')"
expect "our uid but unidentifiable process is foreign (never guess)" "foreign" "${out}"

new_proc mixed
{ tcp_row 4 1F9A 0A "${ME}" 7001; tcp_row 4 1F9A 0A 0 7002; } >> "${P}/net/tcp"; add_proc 7100 dsvideo-backend "${ME}" 7001
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE"')"
expect "if any listener on the port is not ours the port is foreign" "foreign" "${out}"

new_proc lookalike
tcp_row 4 F9A1 0A 0 8001 >> "${P}/net/tcp"; tcp_row 4 1F9B 0A 0 8002 >> "${P}/net/tcp"
out="$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE"')"
expect "ports 0xF9A1 and 0x1F9B do not match 0x1F9A" "free" "${out}"

new_proc customport
tcp_row 4 2382 0A "${ME}" 9001 >> "${P}/net/tcp"; add_proc 9100 dsvideo-backend "${ME}" 9001   # 9090
out="$(run_in_script 'PORT=9090; classify_port_holder; echo "$HOLDER_STATE"')"
expect "DSVIDEO_PORT is honoured (9090 = 0x2382)" "ours" "${out}"

echo "== start-time clearance =="
new_proc clear_foreign
tcp_row 4 1F9A 0A 0 3333 >> "${P}/net/tcp"
out="$(run_in_script 'ensure_port_free; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "foreign holder: start refuses (rc=1) and nothing is killed" "rc=1 kills=0" "${out}"
expect_contains "foreign holder: uid is logged" "uid=0" "$(cat "${B}/var/DSVideoServer.log")"
expect_contains "foreign holder: says it will not kill" "will not kill" "$(cat "${B}/var/DSVideoServer.log")"

new_proc clear_foreign_visible
tcp_row 4 1F9A 0A "${OTHER}" 4444 >> "${P}/net/tcp"; add_proc 5151 dsvideo-backend "${OTHER}" 4444
out="$(run_in_script 'ensure_port_free; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "foreign dsvideo-backend (other uid) is never killed" "rc=1 kills=0" "${out}"
expect_contains "foreign holder: pid and cmdline logged" "pid=5151" "$(cat "${B}/var/DSVideoServer.log")"
expect_contains "foreign holder: cmdline logged" "dsvideo-backend --port 8090" "$(cat "${B}/var/DSVideoServer.log")"

new_proc clear_ours
tcp_row 4 1F9A 0A "${ME}" 1111 >> "${P}/net/tcp"; add_proc 4242 dsvideo-backend "${ME}" 1111
out="$(run_in_script 'ensure_port_free; echo "rc=$? kills=$(cat "$KILLLOG" | tr "\n" ",")"')"
expect "our stale backend: TERMed (no -9 needed) and the port ends up free" "rc=0 kills=4242," "${out}"

new_proc clear_free
out="$(run_in_script 'ensure_port_free; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "free port: start proceeds, nothing killed" "rc=0 kills=0" "${out}"

echo "== stop =="
new_proc stop_foreign
tcp_row 4 1F9A 0A 0 3333 >> "${P}/net/tcp"
out="$(run_in_script 'kills=$(wc -l < "$KILLLOG"); (stop) >/dev/null 2>&1; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "stop with a foreign holder: reports, leaves it alone, exit 0" "rc=0 kills=0" "${out}"

new_proc stop_orphan
tcp_row 4 1F9A 0A "${ME}" 1111 >> "${P}/net/tcp"; add_proc 4242 dsvideo-backend "${ME}" 1111   # no pidfile
out="$(run_in_script '(stop) >/dev/null 2>&1; echo "rc=$? kills=$(cat "$KILLLOG" | tr "\n" ",")"')"
expect "stop kills our own backend even when the pidfile is lost" "rc=0 kills=4242," "${out}"

new_proc stop_pidfile
tcp_row 4 1F9A 0A "${ME}" 1111 >> "${P}/net/tcp"; add_proc 4242 dsvideo-backend "${ME}" 1111
echo 4242 > "${B}/var/server.pid"; echo 99999 > "${B}/var/watchdog.pid"
out="$(run_in_script '(stop) >/dev/null 2>&1; echo "rc=$? pidfile=$([ -e "$PIDFILE" ] && echo kept || echo gone) wd=$([ -e "$WATCHDOG_PIDFILE" ] && echo kept || echo gone)"')"
expect "stop via pidfile: exit 0, pidfile and watchdog.pid removed" "rc=0 pidfile=gone wd=gone" "${out}"

echo "== manifest =="
new_proc manifest
printf 'binary-one' > "${B}/target/dsvideo-backend"
( cd "${B}/target" && sha256sum dsvideo-backend > MANIFEST.sha256 )
out="$(run_in_script 'verify_manifest; echo "rc=$?"')"
expect "intact manifest verifies" "rc=0" "${out}"
printf 'tampered' > "${B}/target/dsvideo-backend"
out="$(run_in_script 'verify_manifest; echo "rc=$?"')"
expect "modified binary fails the manifest (start must refuse)" "rc=1" "${out}"
expect_contains "mismatch is logged loudly" "integrity check FAILED" "$(cat "${B}/var/DSVideoServer.log")"
rm -f "${B}/target/MANIFEST.sha256"
out="$(run_in_script 'verify_manifest; echo "rc=$?"')"
expect "no manifest (old build): warn and continue" "rc=0" "${out}"
expect_contains "missing manifest is logged as WARN" "WARN" "$(cat "${B}/var/DSVideoServer.log")"

echo "== 0600 =="
new_proc perms
for f in dsvideo.db dsvideo.db-wal dsvideo.db-shm DSVideoServer.log; do : > "${B}/var/${f}"; chmod 644 "${B}/var/${f}"; done
out="$(run_in_script 'DSVIDEO_DB_PATH="${VAR}/dsvideo.db"; secure_existing_files; cd "$VAR"; for f in dsvideo.db dsvideo.db-wal dsvideo.db-shm DSVideoServer.log; do ls -l "$f" | cut -c1-10; done | sort -u | tr "\n" " "')"
expect "existing DB, WAL, SHM and log are tightened to 0600" "-rw------- " "${out}"

echo "== umask scope (media-share files must stay readable) =="
new_proc umask
out="$(run_in_script 'umask 022; DSVIDEO_DB_PATH="${VAR}/dsvideo.db"; create_private_files; cd "$VAR"; for f in dsvideo.db DSVideoServer.log; do ls -l "$f" | cut -c1-10; done | sort -u | tr "\n" " "; umask')"
expect "fresh DB and log are created 0600 without a restrictive process umask" "-rw------- 0022" "${out}"
out="$(grep -c '^  umask 077' "${SCRIPT}" || true)"
expect "start() does not set a process-wide umask 077" "0" "${out}"
out="$(grep -c '^  umask 022' "${SCRIPT}" || true)"
expect "start() pins umask 022 for the backend" "1" "${out}"

echo
echo "passed=${PASS} failed=${FAIL}"
[ "${FAIL}" -eq 0 ]
