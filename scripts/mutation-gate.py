#!/usr/bin/env python3
"""Mutation gate — DSVideo.

Proves the test suite can FAIL. For each entry below it breaks one behavior in the product
code, runs the unit suite, and records whether any test noticed.

    KILLED   = a test caught it. The test is real.
    SURVIVED = nothing noticed. The test is fake, or absent. THIS FAILS THE GATE.

Usage:
    python3 scripts/mutation-gate.py              # every mutation
    python3 scripts/mutation-gate.py M5-upsert    # one or more by id

Exit 0 only when every applied mutation was KILLED.

History: the 2026-09-12 retrofit found 9 of 13 mutations surviving a green 105-test suite —
87% of the destructive surface unprotected. All 13 are killed now. This script is what stops
that regressing. See docs/retrofit/R6-final.md.

TWO RULES, both learned the hard way in that session (docs/retrofit/R6-harness-incident.md):

1. Revert ONE FILE, never a directory. A directory-wide `git checkout` destroys uncommitted
   work — it wiped the test seams mid-run and turned five build failures into false KILLEDs.
2. A build failure is NEVER a kill. If the mutant does not compile, the run proves nothing
   about the tests. Reported as BUILD_FAILED, which also fails the gate (a stale anchor needs
   fixing, it is not a pass).

A kill materially faster than a clean suite run is the cheapest signal that a result is lying.
A clean run here is ~24s; every genuine kill in the final census took 28-43s.
"""
import json, subprocess, sys, os, shutil, time

ROOT = "/Users/ryan/Documents/Development/DSVideo"
SRC = f"{ROOT}/DS Video clone/DSM Video/DSM Video"
PROJ = f"{ROOT}/DS Video clone/DSM Video.xcodeproj"
SP = "/tmp/claude-501/-Users-ryan-Documents-Development-DSVideo/39ce9cb9-90ba-4bb5-83e9-e57391f433c1/scratchpad"
DD = f"{SP}/dd-r6"
SIM = "04994E04-5670-4E8D-9923-3F86E067F600"

# (id, tier, symbol, file, find, replace, note)
MUTATIONS = [
    # ---- T-B: symbols the existing suite claims to cover. These SHOULD be killed. ----
    ("M2-priv", "T-B", "AppState.isPrivateLANAddress", "App/AppState.swift",
     'if host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("169.254.") { return true }',
     'if host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("169.254.") { return false }',
     "invert the private-range verdict"),

    ("M3-finish", "T-B", "PlaybackProgress.isFinished", "App/PlaybackProgress.swift",
     None, None, "off-by-one the watched-ratio boundary"),

    ("M4-err", "T-B", "APIError.userMessage(401/403)", "Networking/APIClient.swift",
     'return "Your session expired. Sign in again."',
     'return "Network error."',
     "swap the auth error message for the wrong cause"),

    ("M2-perm", "T-B", "APIError.isPermanentRejection", "Networking/APIClient.swift",
     "return code == 400 || code == 404 || code == 410 || code == 422",
     "return false",
     "no status is permanent -> outbox retries forever"),

    ("M2-reach", "T-B", "APIError.serverReached", "Networking/APIClient.swift",
     "case .server, .http, .converting, .decode: return true",
     "case .server, .http, .converting, .decode: return false",
     "invert server-reached"),

    ("M1-redact", "T-A", "DiagnosticLog.redact", "Networking/DiagnosticLog.swift",
     None, None, "return the secret verbatim (credential leak)"),

    # ---- T-A: the destructive / persistence surface. Census expects SURVIVED. ----
    ("M5-upsert", "T-A", "LocalStore.upsertSingleProgress", "Networking/LocalStore.swift",
     None, None, "skip the progress write entirely"),

    ("M6-delitems", "T-A", "LocalStore.deleteItems", "Networking/LocalStore.swift",
     None, None, "delete nothing"),

    ("M1-clearall", "T-A", "LocalStore.clearAll", "Networking/LocalStore.swift",
     None, None, "clearAll does nothing"),

    ("M1-delete-dl", "T-A", "DownloadManager.deleteDownload", "Networking/DownloadManager.swift",
     None, None, "deleteDownload does nothing"),

    ("M5-resume", "T-A", "DownloadManager.updateResumePosition", "Networking/DownloadManager.swift",
     None, None, "skip the offline resume-position write"),

    ("M2-httpfail", "T-A", "DownloadManager.shouldAcceptResponse", "Networking/DownloadManager.swift",
     "    return (200...299).contains(status)",
     "    return !(200...299).contains(status)",
     "invert the download status gate (the 1.3.6 P0)"),

    ("M2-ready", "T-A", "LocalStore.isUnavailable", "Networking/LocalStore.swift",
     "setupFailure != nil || db == nil",
     "false",
     "store always claims healthy"),
]

# Whole-body no-op mutations, applied by locating `func <name>` and inserting an early return.
BODY_NOOP = {
    "M1-redact":    ("Networking/DiagnosticLog.swift", "static func redact(_ secret: String?) -> String {", '    if true { return secret ?? "" }'),
    "M5-upsert":    ("Networking/LocalStore.swift", "func upsertSingleProgress(itemId: String, positionSeconds: Int, durationSeconds: Int) {", "    if true { return }"),
    "M6-delitems":  ("Networking/LocalStore.swift", "func deleteItems(_ ids: [String]) {", "    if true { return }"),
    "M1-clearall":  ("Networking/LocalStore.swift", "func clearAll() {", "    if true { return }"),
    "M1-delete-dl": ("Networking/DownloadManager.swift", "func deleteDownload(itemId: String) {", "    if true { return }"),
    "M5-resume":    ("Networking/DownloadManager.swift", "func updateResumePosition(itemId: String, positionSeconds: Int) {", "    if true { return }"),
    "M3-finish":    ("App/PlaybackProgress.swift", "static func isFinished(positionSeconds: Int, durationSeconds: Int) -> Bool {", "    if true { return false }"),
}


def run_suite(timeout=300):
    """Run the unit suite. Returns True if PASSED (mutation SURVIVED)."""
    cmd = ["xcodebuild", "test", "-project", PROJ, "-scheme", "DSM Video",
           "-destination", f"platform=iOS Simulator,id={SIM}",
           "-derivedDataPath", DD, "-only-testing:DSM VideoTests"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = r.stdout
        # A mutation that does not COMPILE proves nothing about the tests. Treat a build
        # failure as BUILD_FAILED, never as a kill — that conflation produced five false
        # KILLEDs in this very run, all in 4-5s against a suite that needs ~24s.
        if " error:" in out and "Test Suite" not in out:
            return "BUILD_FAILED", out[-4000:]
        return r.returncode == 0, out[-4000:]
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"


def apply_body_noop(relpath, signature, injected):
    path = os.path.join(SRC, relpath)
    src = open(path).read()
    if signature not in src:
        return False, f"signature not found: {signature[:60]}"
    # insert the injected line immediately after the signature's opening brace
    src2 = src.replace(signature, signature + "\n" + injected, 1)
    open(path, "w").write(src2)
    return True, "ok"


def apply_textual(relpath, find, repl):
    path = os.path.join(SRC, relpath)
    src = open(path).read()
    if src.count(find) != 1:
        return False, f"find-string count={src.count(find)} (need exactly 1)"
    open(path, "w").write(src.replace(find, repl, 1))
    return True, "ok"


def revert(relpath=None):
    """Revert ONLY the mutated file.

    Originally this reverted the whole "DS Video clone/DSM Video/DSM Video" directory, which
    destroyed every UNCOMMITTED change under it — including the test seams a concurrent agent
    had just written, leaving its tests in place and the build broken with 91 errors. Every
    "KILLED" in that run was a compile failure, not a test failure.

    Restoring a single file by path cannot collateral-damage anything else. A mutation is one
    file by construction, so nothing is lost by narrowing this.
    """
    if relpath is None:
        return
    target = f"DS Video clone/DSM Video/DSM Video/{relpath}"
    subprocess.run(["git", "checkout", "--", target], cwd=ROOT, capture_output=True)


def main():
    only = sys.argv[1:] or None
    results = []
    for mid, tier, symbol, relpath, find, repl, note in MUTATIONS:
        if only and mid not in only:
            continue
        print(f"\n=== {mid} [{tier}] {symbol} — {note} ===", flush=True)
        if mid in BODY_NOOP:
            rp, sig, inj = BODY_NOOP[mid]
            mutated_path = rp
            revert(mutated_path)
            ok, msg = apply_body_noop(rp, sig, inj)
        else:
            mutated_path = relpath
            revert(mutated_path)
            ok, msg = apply_textual(relpath, find, repl)
        if not ok:
            print(f"  SKIP — could not apply: {msg}", flush=True)
            results.append({"id": mid, "tier": tier, "symbol": symbol,
                            "result": "NOT_APPLIED", "note": note, "reason": msg})
            revert(mutated_path)
            continue
        t0 = time.time()
        passed, tail = run_suite()
        # A TIMEOUT here is nearly always xcodebuild hanging on simulator acquisition (idle,
        # 0% CPU, no booted device) rather than anything about the mutation. Failing the gate
        # on that would make it flaky, and a flaky gate gets switched off — which costs more
        # than the bug it would have caught. Retry once against a freshly booted simulator and
        # only believe a second timeout.
        if passed is None:
            print("     TIMEOUT — retrying once (suspected simulator hang, not a result)", flush=True)
            subprocess.run(["xcrun", "simctl", "shutdown", "all"], capture_output=True)
            subprocess.run(["xcrun", "simctl", "boot", SIM], capture_output=True)
            time.sleep(10)
            passed, tail = run_suite()
        dt = int(time.time() - t0)
        revert(mutated_path)
        if passed is None:
            verdict = "TIMEOUT"
        elif passed == "BUILD_FAILED":
            verdict = "BUILD_FAILED"
        else:
            verdict = "SURVIVED" if passed else "KILLED"
        print(f"  -> {verdict}  ({dt}s)", flush=True)
        results.append({"id": mid, "tier": tier, "symbol": symbol,
                        "result": verdict, "note": note, "seconds": dt})
        with open(f"{SP}/census-partial.json", "w") as f:
            json.dump(results, f, indent=2)
    print("\n=== SUMMARY ===")
    for r in results:
        print(f"  {r['result']:12s} {r['id']:14s} {r['tier']}  {r['symbol']}")

    bad = [r for r in results if r["result"] != "KILLED"]
    if bad:
        print(f"\nGATE FAILED — {len(bad)} of {len(results)} mutation(s) not killed:")
        for r in bad:
            print(f"  {r['result']}: {r['id']} ({r['symbol']}) — {r['note']}")
        print("\nSURVIVED means no test noticed that behavior breaking. Write the test;")
        print("do NOT weaken the mutation. BUILD_FAILED means a stale anchor — fix the anchor.")
        print("TIMEOUT (twice) is environmental, not a test gap — check the simulator, then re-run")
        print("just that id: python3 scripts/mutation-gate.py <id>")
        sys.exit(1)
    print(f"\nGATE PASSED — {len(results)}/{len(results)} mutations killed.")
    sys.exit(0)


if __name__ == "__main__":
    main()
