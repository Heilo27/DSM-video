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
# mk_proc <pid> <exe-target|-> <comm> <argv0> <uid> [pgrp=pid] [state=S]: a process with every
# identity field set independently, so a test can make exe, comm and argv0 disagree.
# exe "-" means /proc/PID/exe is unreadable (another user's process).
mk_proc() {
  mkdir -p "${P}/$1/fd"
  [ "$2" = "-" ] || ln -s "$2" "${P}/$1/exe"
  printf '%s' "$3" | cut -c1-15 > "${P}/$1/comm"          # the kernel truncates comm to 15
  printf '%s\0--port\0%s\0' "$4" "8090" > "${P}/$1/cmdline"
  printf 'Name:\t%s\nState:\t%s\nPPid:\t1\nUid:\t%s\t%s\t%s\t%s\n' "$3" "${7:-S (sleeping)}" "$5" "$5" "$5" "$5" > "${P}/$1/status"
  printf '%s (%s) S 1 %s %s 0\n' "$1" "$3" "${6:-$1}" "${6:-$1}" > "${P}/$1/stat"
}
BK=/volume1/@appstore/DSVideoServer/backend
mode() { ls -l "$1" | cut -c1-10; }

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
      last="${last#-}"                       # "kill -15 -PGID": the leader's pid dir
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
{ tcp_row 4 1F9A 0A "${ME}" 7001; tcp_row 4 1F9A 0A "${OTHER}" 7002; } >> "${P}/net/tcp"; add_proc 7100 dsvideo-backend "${ME}" 7001
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
out="$(run_in_script 'verify_manifest dsvideo-backend; echo "rc=$?"')"
expect "intact manifest verifies" "rc=0" "${out}"
printf 'tampered' > "${B}/target/dsvideo-backend"
out="$(run_in_script 'verify_manifest dsvideo-backend; echo "rc=$?"')"
expect "modified binary fails the manifest (start must refuse)" "rc=1" "${out}"
expect_contains "mismatch is logged loudly" "integrity check FAILED" "$(cat "${B}/var/DSVideoServer.log")"
rm -f "${B}/target/MANIFEST.sha256"
out="$(run_in_script 'verify_manifest dsvideo-backend; echo "rc=$?"')"
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

# =========================================================================================
# Regression tests for the TASK-1080 QA defects (D1-D4, D6-D8; D5 is a decision, not a bug).
# Each test is given / when / then. They all use the same fixtures and stubs as above.
# =========================================================================================

alive_of() { printf 'pid_alive %s && echo yes || echo no' "$1"; }

echo "== D1: a same-uid look-alike is not ours (comm is cut to 15 chars) =="
# given: a process of OUR uid whose exe is dsvideo-backend-old / dsvideo-backend.bak; the
#        kernel truncates its comm to "dsvideo-backend", identical to the real one
# when:  pid_alive, the port classifier, ensure_port_free and stop look at it
# then:  it is not ours: not alive, port foreign, and nothing is signalled
for lookalike in dsvideo-backend-old dsvideo-backend.bak; do
  new_proc "d1_${lookalike}"
  tcp_row 4 1F9A 0A "${ME}" 1111 >> "${P}/net/tcp"; add_proc 4242 "${lookalike}" "${ME}" 1111
  expect "D1 ${lookalike}: comm is the truncated 'dsvideo-backend' (fixture sanity)" "dsvideo-backend" "$(cat "${P}/4242/comm")"
  expect "D1 ${lookalike}: pid_alive says no" "no" "$(run_in_script "$(alive_of 4242)")"
  expect "D1 ${lookalike}: the port holder is foreign" "foreign" "$(run_in_script 'classify_port_holder; echo "$HOLDER_STATE"')"
  expect "D1 ${lookalike}: ensure_port_free refuses and kills nothing" "rc=1 kills=0" \
    "$(run_in_script 'ensure_port_free; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
  expect "D1 ${lookalike}: stop leaves it alone" "kills=0" \
    "$(run_in_script '(stop) >/dev/null 2>&1; echo "kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
done

# given: readable exe naming another program, but comm and argv0 both claim dsvideo-backend
# then:  the exe link wins; it is not ours
new_proc d1_exe_wins
mk_proc 4250 /usr/bin/python3 dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
expect "D1 a readable exe of another program wins over a claimed comm and argv0" "no" "$(run_in_script "$(alive_of 4250)")"

# given: exe unreadable (EPERM, another user's process or a hardened /proc)
new_proc d1_unreadable
mk_proc 4251 - dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
mk_proc 4252 - dsvideo-backend "${BK}/dsvideo-backend-old" "${ME}"
mk_proc 4253 - dsvideo-backend "${BK}/dsvideo-backend.bak" "${ME}"
expect "D1 exe unreadable, comm and argv0 name the backend: ours" "yes" "$(run_in_script "$(alive_of 4251)")"
expect "D1 exe unreadable, argv0 is dsvideo-backend-old: not ours" "no" "$(run_in_script "$(alive_of 4252)")"
expect "D1 exe unreadable, argv0 is dsvideo-backend.bak: not ours" "no" "$(run_in_script "$(alive_of 4253)")"

# given: an emulation layer (Rosetta, qemu-user): exe is the emulator, comm is the program
new_proc d1_emulated
mk_proc 4260 /run/rosetta/rosetta dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
mk_proc 4261 /run/rosetta/rosetta dsvideo-backend "${BK}/dsvideo-backend-old" "${ME}"
mk_proc 4262 /usr/bin/qemu-x86_64 dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
mk_proc 4263 /run/rosetta/rosetta dsvideo-backend /run/rosetta/rosetta "${ME}"
printf '%s\0%s\0--port\0' /run/rosetta/rosetta "${BK}/dsvideo-backend" > "${P}/4263/cmdline"   # emulator is argv[0]
expect "D1 under Rosetta, argv0 is the backend: ours" "yes" "$(run_in_script "$(alive_of 4260)")"
expect "D1 under Rosetta, argv0 is dsvideo-backend-old: not ours" "no" "$(run_in_script "$(alive_of 4261)")"
expect "D1 under qemu-user, argv0 is the backend: ours" "yes" "$(run_in_script "$(alive_of 4262)")"
expect "D1 emulator as argv[0], backend as argv[1]: ours" "yes" "$(run_in_script "$(alive_of 4263)")"

# given: the real thing, and the real thing after an in-place upgrade ("(deleted)")
new_proc d1_real
mk_proc 4270 "${BK}/dsvideo-backend" dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
mk_proc 4271 "${BK}/dsvideo-backend (deleted)" dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
expect "D1 the real backend is ours" "yes" "$(run_in_script "$(alive_of 4270)")"
expect "D1 the real backend after an upgrade (exe '(deleted)') is ours" "yes" "$(run_in_script "$(alive_of 4271)")"

echo "== D3: no signal to a process that is not ours, from any path =="
# given: a dsvideo-backend running as ANOTHER uid (the original outage: a root-run leftover)
# when:  every path that can signal is pointed at it
# then:  no kill is issued, whatever the path; the refusal is logged
new_proc d3_term
add_proc 5151 dsvideo-backend "${OTHER}" 4444
out="$(run_in_script 'terminate_pid 5151 1; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D3 terminate_pid refuses a foreign-uid process (rc=1, no kill)" "rc=1 kills=0" "${out}"
expect_contains "D3 the refusal is logged with the uid" "REFUSING to signal pid 5151" "$(cat "${B}/var/DSVideoServer.log")"
out="$(run_in_script 'signal_pid 5151 KILL; r1=$?; signal_pid 5151 TERM group; r2=$?; echo "rc=$r1,$r2 kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D3 signal_pid refuses KILL and group TERM as well" "rc=1,1 kills=0" "${out}"

new_proc d3_split_uid
mk_proc 5160 "${BK}/dsvideo-backend" dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
printf 'Name:\tdsvideo-backend\nState:\tS (sleeping)\nPPid:\t1\nUid:\t%s\t%s\t%s\t%s\n' "${ME}" "${OTHER}" "${ME}" "${ME}" > "${P}/5160/status"
out="$(run_in_script 'signal_pid 5160 TERM; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D3 real uid ours but effective uid not: refused (both must match)" "rc=1 kills=0" "${out}"

new_proc d3_special
out="$(run_in_script 'signal_pid 0 TERM; a=$?; signal_pid 1 KILL; b=$?; signal_pid "" TERM; c=$?; signal_pid "12x" TERM; d=$?; echo "rc=$a$b$c$d kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D3 pids 0, 1, empty and non-numeric are never signalled" "rc=1111 kills=0" "${out}"

# given: pid 1 and pid 0 "owned by us" (a root-run script: init is uid 0 too). kill 0 would hit
#        our own process group, kill 1 is init: neither is ever a valid target
new_proc d3_init
mk_proc 1 /sbin/init init init "${ME}"
mk_proc 0 /sbin/init init init "${ME}"
out="$(run_in_script 'signal_pid 1 KILL; a=$?; signal_pid 0 TERM group; b=$?; echo "rc=$a$b kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D3 pid 1 and pid 0 are refused even when they look owned by us" "rc=11 kills=0" "${out}"

new_proc d3_pidfile
add_proc 5151 dsvideo-backend "${OTHER}" 4444
echo 5151 > "${B}/var/server.pid"
out="$(run_in_script 'owned_pidfile_pid; echo "rc=$?"')"
expect "D3 start/stop pidfile path: a foreign-uid pid in the pidfile is not ours" "rc=1" "${out}"
expect_contains "D3 and it is said so in the log" "not ours" "$(cat "${B}/var/DSVideoServer.log")"
out="$(run_in_script '(stop) >/dev/null 2>&1; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D3 stop with a pidfile naming a foreign-uid backend: no kill" "rc=0 kills=0" "${out}"

new_proc d3_watchdog
mk_proc 5170 /bin/busybox sh "/var/packages/DSVideoServer/scripts/start-stop-status" "${OTHER}"
echo 5170 > "${B}/var/watchdog.pid"
out="$(run_in_script 'stop_watchdog; echo "kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D3 stop_watchdog: a foreign-uid pid in watchdog.pid is not signalled" "kills=0" "${out}"

new_proc d3_children
add_proc 5180 dsvideo-backend "${OTHER}" 1; printf 'PPid:\t5190\n' >> "${P}/5180/status"
out="$(run_in_script 'sweep_children "5180"; echo "kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D3 sweep_children does not signal a foreign-uid process" "kills=0" "${out}"

new_proc d3_ours
add_proc 4242 dsvideo-backend "${ME}" 1111
out="$(run_in_script 'terminate_pid 4242 1; echo "rc=$? kills=$(cat "$KILLLOG" | tr "\n" ",")"')"
expect "D3 (control) our own backend is still terminated" "rc=0 kills=4242," "${out}"

echo "== D2: a child that has not exec'd yet is alive, and dies with its group =="
# given: the launched child is still the launching shell (comm 'sh', exe busybox) -- between
#        fork and exec -- so it is not yet a dsvideo-backend
# when:  the gate watches it, and when the gate fails
# then:  it is not read as dead; on failure its whole process group is killed
new_proc d2_preexec
mk_proc 4300 /bin/busybox sh sh "${ME}"
expect "D2 fixture: a pre-exec child is not a backend (pid_alive no) but is running" "no" "$(run_in_script "$(alive_of 4300)")"
out="$(run_in_script 'echo 0 > "${B}/n"; health_probe() { c=$(cat "${B}/n"); echo $((c+1)) > "${B}/n"; [ "$c" -ge 2 ] && echo "ok"; }
  wait_healthy 4300 30; echo "rc=$?"')"
expect "D2 wait_healthy keeps waiting on a pre-exec child and succeeds when healthz answers" "rc=0" "$(printf '%s' "${out}" | tail -1)"

out="$(run_in_script 'pid_running() { return 1; }; health_probe() { return 1; }; wait_healthy 4300 30; echo "rc=$?"')"
expect "D2 a child that is really gone fails the gate" "rc=1" "${out}"
expect_contains "D2 and the log says it exited during startup" "exited during startup" "$(cat "${B}/var/DSVideoServer.log")"

# given: one /proc read that wrongly says "gone" (race), the next says it is there
out="$(run_in_script 'echo 0 > "${B}/n"; pid_running() { c=$(cat "${B}/n"); echo $((c+1)) > "${B}/n"; [ "$c" -ne 0 ]; }
  health_probe() { echo ok; }; wait_healthy 4300 30; echo "rc=$?"')"
expect "D2 grace: one unlucky /proc read does not fail the start" "rc=0" "$(printf '%s' "${out}" | tail -1)"

# gate failure kills the group
out="$(run_in_script 'terminate_pid 4300 5 group; echo "rc=$? kills=$(cat "$KILLLOG" | tr "\n" ",")"')"
expect "D2 gate failure: the pre-exec child's process group is killed (kill -15 -PGID)" "rc=0 kills=-15 -4300," "${out}"
mk_proc 4301 /bin/busybox sh sh "${ME}" 99      # does not lead its group
out="$(run_in_script 'terminate_pid 4301 5 group; echo "rc=$? kills=$(cat "$KILLLOG" | tr "\n" ",")"')"
expect "D2 a child that does not lead a group is signalled by pid only (never someone else's group)" "rc=0 kills=4301," "${out}"
mk_proc 4302 /bin/busybox sh sh "${OTHER}"
out="$(run_in_script 'terminate_pid 4302 5 group; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D2 group scope still never signals a process that is not ours" "rc=1 kills=0" "${out}"

echo "== R1: a recycled pid in the pidfile is never signalled =="
# [mutation: make pid_is_backend accept any process of our uid, or drop pid_alive from
#  owned_pidfile_pid -> the "survives" cases below go red]
# given: the backend crashed; its pid was recycled by an unrelated process of OUR OWN uid
#        (python3 here), and the stale pidfile still names it
# when:  status, stop and the pidfile reader look at that pid
# then:  it is not our backend: status says not running, stop issues no signal, the process
#        survives, and the stale pidfile is cleaned up
new_proc r1_recycled
mk_proc 6000 /usr/bin/python3 python3 python3 "${ME}"
echo 6000 > "${B}/var/server.pid"
expect "R1 the pidfile reader does not own an unrelated same-uid process" "rc=1" "$(run_in_script 'owned_pidfile_pid >/dev/null; echo "rc=$?"')"
expect "R1 status reports not running (rc=1)" "rc=1" "$(run_in_script '(status) >/dev/null 2>&1; echo "rc=$?"')"
expect "R1 stop sends nothing, exits 0, and the stale pidfile is gone" "rc=0 kills=0 pidfile=gone" \
  "$(run_in_script '(stop) >/dev/null 2>&1; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ") pidfile=$([ -e "${PIDFILE}" ] && echo present || echo gone)"')"
expect "R1 the unrelated process is still there" "yes" "$([ -d "${P}/6000" ] && echo yes || echo no)"
# the same recycled pid, but the unrelated process is a root-owned one (stop runs as the package user)
new_proc r1_recycled_root
mk_proc 6001 /usr/sbin/sshd sshd sshd 0
echo 6001 > "${B}/var/server.pid"
expect "R1 a recycled pid owned by root: no signal, pidfile cleaned up" "kills=0 pidfile=gone" \
  "$(run_in_script '(stop) >/dev/null 2>&1; echo "kills=$(wc -l < "$KILLLOG" | tr -d " ") pidfile=$([ -e "${PIDFILE}" ] && echo present || echo gone)"')"
# control: the same pidfile naming our real backend is stopped, so the checks above can fail
new_proc r1_control
mk_proc 6002 "${BK}/dsvideo-backend" dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
echo 6002 > "${B}/var/server.pid"
expect "R1 (control) the same stop terminates our real backend" "kills=6002," \
  "$(run_in_script '(stop) >/dev/null 2>&1; echo "kills=$(cat "$KILLLOG" | tr "\n" ",")"')"

echo "== R2: the target exits between the ownership check and the signal =="
# [mutation: delete the "_tp_alive || return 0" line after a refused signal in terminate_pid
#  -> terminate_pid returns 1 and stop reports an error]
# given: our backend passes the uid/identity check, then exits before kill delivers: kill
#        reports ESRCH (non-zero) and the process is gone
# when:  terminate_pid and stop run under set -e (the script runs with set -eu)
# then:  both treat "already gone" as success: rc 0, the script is not aborted, the pidfile is
#        removed and the port is reported free
new_proc r2_race
mk_proc 6100 "${BK}/dsvideo-backend" dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
out="$(run_in_script 'kill() { echo "$*" >> "$KILLLOG"; rm -rf "${P:?}/6100"; return 1; }
  set -e; terminate_pid 6100 1; echo "rc=$? kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "R2 terminate_pid: kill fails because the target just exited -> still success, script not aborted" "rc=0 kills=1" "${out}"
new_proc r2_race_stop
mk_proc 6101 "${BK}/dsvideo-backend" dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
echo 6101 > "${B}/var/server.pid"
out="$(run_in_script 'kill() { echo "$*" >> "$KILLLOG"; rm -rf "${P:?}/6101"; return 1; }
  set -e; (stop) >/dev/null 2>&1; echo "rc=$? pidfile=$([ -e "${PIDFILE}" ] && echo present || echo gone)"')"
expect "R2 stop: target vanishes mid-signal -> exit 0 and the pidfile is removed" "rc=0 pidfile=gone" "${out}"
expect_contains "R2 and the log does not call it an error" "stopped (port 8090 is free)" "$(cat "${B}/var/DSVideoServer.log")"

echo "== start(), end to end on a fake tree (D2 launch, D4, D6) =="
# new_start <name>: a package tree with an executable stand-in binary; setsid is stubbed away
# (the launched "child" is a function subshell), nothing real is run.
new_start() {
  new_proc "$1"
  mkdir -p "${B}/target/backend"
  printf '#!/bin/sh\nexit 0\n' > "${B}/target/backend/dsvideo-backend"; chmod 755 "${B}/target/backend/dsvideo-backend"
}
START_STUBS='setsid() { :; }'

# D2 end to end: gate fails while the child sits pre-exec
new_start start_gatefail
out="$(run_in_script "${START_STUBS}"'; wait_healthy() { mk_proc "$1" /bin/busybox sh sh "$ME"; return 1; }
  (start) >/dev/null 2>&1; echo "rc=$? pidfile=$([ -e "$PIDFILE" ] && echo kept || echo none) groupkills=$(grep -c "^-15 -[0-9][0-9]*\$" "$KILLLOG") kills=$(wc -l < "$KILLLOG" | tr -d " ")"')"
expect "D2 start: gate failure kills the pre-exec child's group, writes no pidfile, exits 1" "rc=1 pidfile=none groupkills=1 kills=1" "${out}"

# D4 end to end: a manifest that does not list the backend
new_start start_nomanifestline
printf 'other-bytes' > "${B}/target/other"; ( cd "${B}/target" && sha256sum other > MANIFEST.sha256 )
out="$(run_in_script "${START_STUBS}"'; (start) >/dev/null 2>&1; echo "rc=$? pidfile=$([ -e "$PIDFILE" ] && echo kept || echo none)"')"
expect "D4 start refuses when the manifest exists but does not list the backend" "rc=1 pidfile=none" "${out}"
expect_contains "D4 the refusal says which file is missing from the manifest" "does not list backend/dsvideo-backend" "$(cat "${B}/var/DSVideoServer.log")"
case "$(cat "${B}/var/DSVideoServer.log")" in *"launched pid"*) bad "D4 the binary was launched anyway" ;; *) ok "D4 and the binary is never launched" ;; esac

# D6 end to end
new_start start_modes
out="$(run_in_script "${START_STUBS}"'; wait_healthy() { return 0; }; umask 000; (start) >/dev/null 2>&1; sleep() { :; }
  cd "$VAR"; echo "server.pid=$(mode server.pid) watchdog.pid=$(mode watchdog.pid) jwt=$(mode .jwt_secret)"')"
expect "D6 start leaves server.pid, watchdog.pid and the JWT secret 0600 (caller umask 000)" \
  "server.pid=-rw------- watchdog.pid=-rw------- jwt=-rw-------" "${out}"

new_proc d6_overwrite
printf 'old' > "${B}/var/wd.pid"; chmod 644 "${B}/var/wd.pid"
out="$(run_in_script 'umask 000; write_private "${VAR}/wd.pid" 77; mode "${VAR}/wd.pid"; cat "${VAR}/wd.pid"')"
expect "D6 write_private replaces an older world-readable file and writes the new content" "-rw------- 77" "$(printf '%s' "${out}" | tr '\n' ' ' | sed 's/ $//')"

echo "== D7: the rotated log is 0600 =="
# given: a log past the size cap, a caller umask of 022 (what start() pins)
# when:  rotate_log runs
# then:  the new log is 0600 (the old one is kept as .1)
new_proc d7
printf 'xxxxxxxxxxxx' > "${B}/var/DSVideoServer.log"; chmod 644 "${B}/var/DSVideoServer.log"
out="$(run_in_script 'LOG_MAX_BYTES=5; umask 022; rotate_log; echo "$(mode "$LOG") $(ls "$VAR" | grep -c "DSVideoServer.log.1")"')"
expect "D7 rotated log is 0600 and the previous generation is kept" "-rw------- 1" "${out}"

echo "== D8: the start timeout is wall-clock =="
# given: DSVIDEO_START_TIMEOUT=3, a child that stays alive, and a probe that burns its whole
#        timeout every time (a hung healthz)
# when:  the gate runs with real sleeps
# then:  it gives up after about 3 seconds in total (the old loop took 3 x (2s probe + 1s) = 9s)
new_proc d8
mk_proc 4400 "${BK}/dsvideo-backend" dsvideo-backend "${BK}/dsvideo-backend" "${ME}"
t0="$(date +%s)"
out="$(run_in_script 'unset -f sleep; health_probe() { sleep "${2%s}"; echo "no answer"; return 1; }; wait_healthy 4400 3; echo "rc=$?"')"
t1="$(date +%s)"
expect "D8 the gate fails when healthz never answers" "rc=1" "${out}"
elapsed=$((t1 - t0))
if [ "${elapsed}" -le 5 ]; then ok "D8 START_TIMEOUT=3 with a hanging probe took ${elapsed}s (<= 5s; the old loop took 9s)"; else bad "D8 START_TIMEOUT=3 took ${elapsed}s"; fi
expect_contains "D8 and the log reports the timeout" "not healthy after 3s" "$(cat "${B}/var/DSVideoServer.log")"


echo
echo "passed=${PASS} failed=${FAIL}"
[ "${FAIL}" -eq 0 ]
