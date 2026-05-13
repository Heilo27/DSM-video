# Level 1 Diagnostic — DSVideo — 20260513
## Cycle 1

---

## Summary

| Category | Count |
|---|---|
| Integration | 8 |
| Completeness | 1 |
| Code | 6 |
| Architecture | 9 |
| Stability | 18 |
| Security | 10 |
| **Total open** | **52** |

Build status: **iOS BUILD SUCCEEDED. Go BUILD SUCCEEDED.**

---

## By Severity

### P0 (blocking): 1
- [Stability] Relay/Playback: AVPlayer HLS segment fetches via relay missing Cookie: type=tunnel — all relay video playback fails

### P1 (critical): 12
- [Integration] reconnect() relay probe uses hardcoded 5s serverVersion timeout — relay always skipped on cold start
- [Integration] No scenePhase foreground handler — homeLoad not re-triggered on app resume
- [Stability] Backend requestBaseURL returns https:// for relay requests — stream URLs broken (WRONG_VERSION_NUMBER)
- [Stability] 401 in background retry silently exits — user permanently stuck until manual sign-in
- [Stability] homeLoad concurrent calls not fully guarded (missing homeIsBackgroundRefreshing check)
- [Stability] Relay port expiry mid-session — API unavailable until retry resolves new port
- [Code] LAN HTTPS candidates always fail cert validation — dead weight, 4s×2 wasted per reconnect attempt
- [Code] requestBaseURL() ignores X-Forwarded-Host — returns localhost:8080 fallback for some proxy configs
- [Architecture] Sequential candidate probing — worst case 60+ seconds before reconnect fails
- [Architecture] requestBaseURL fundamental mismatch: stream URL host derived from request, not from client-reachable URL
- [Architecture] No connection state machine — isOffline/serverUnreachable/isReconnecting three booleans, impossible states representable
- [Architecture] Wrong error surfaced when 401 triggers in reconnect — user sees "Can't reach server" not "Session expired"

### P2 (major): 33
**Integration/Code:**
- AuthenticatedImage latches nil URL — images never reload after QC resolves
- QuickConnectSheet stores resolved WAN IP in baseURL instead of bare QC ID
- homeLoad in-memory path does not clear stale homeError banner
- relay win sets useHTTPS=false — corrupts future direct-IP HTTPS state
- direct-IP reconnect probes wrong port after relay-based login session
- syncStatus 4s timeout too short for cold-starting NAS DB — forces unnecessary relay fallback
- reconnect() 74 QC API calls in 5 minutes — rate-limiting risk
- Exhausted 37-attempt retry with no recovery path — user permanently stuck, no retry button
- checkTokenExpiryOnLaunch 2s sleep races with QC resolution
- clearNetworkError() self-cancels reconnectRetryTask from within its own body — homeLoad never fires on reconnect success
- homeIsBackgroundRefreshing not checked in homeLoad guard
- reconnectRetryTask nil'd before homeLoad — self-cancellation window
- Wrong "Can't reach server" error for no-token QC user (should be "sign in required")
- clearAll() in homeForceRefresh not transactional — DB inconsistency on interrupted force-refresh
- logout() race window with in-flight reconnect()
- No Go test coverage for auth/sync/relay logic
- NWPathMonitor WiFi→LTE transition doesn't trigger QC re-resolution

**Architecture:**
- QuickConnectResolver in Views layer, called from Model — layer violation
- get_server_info + request_tunnel called serially — should be concurrent
- Relay URL ephemeral — no proactive tunnel health check
- Background retry fires homeLoad() — may hit in-memory early-exit, skip sync
- Token expiry 2s sleep race (same as checkTokenExpiryOnLaunch above)
- AppState god-object (900+ lines, 6 concerns)

**Security:**
- Playback session IDs unauthenticated and not redacted in logs (P1 border)
- AuthenticatedImage and main views lack .privacySensitive() — library visible in App Switcher
- OpenSubtitlesAPIKey hardcoded constant — key will ship in binary if populated
- handleLogout returns 200 for invalid/missing token (undocumented intentional)
- Backend logs auth.cgi HTTP status on every login
- /images/{id} unauthenticated — library enumerable on LAN without credentials

### P3 (minor): 6
- NWPathMonitor network-type change doesn't trigger QC re-resolution
- checkTokenExpiryOnLaunch 2s sleep unreliable race guard
- Migration ALTER TABLE silently ignored on every restart — genuine failures invisible
- handleSyncStatus SELECT COUNT(*) full table scan on every call
- getSyncSeqs returns (0,0) silently on DB error
- No certificate pinning (SEC-H)
- Username in UserDefaults (SEC-I)

---

## Verdict — Cycle 1
**FIX REQUIRED — Cycle 1 of 3.**
1 P0, 12 P1. Proceeding to Phase 5A.

---

## Cycle 2 — Phase 5B Re-Review Results

Re-review scoped to 7 changed files. 0 P0/P1 regressions. 2 P2s found and fixed:
- AuthenticatedImage: macOS body missing onChange(of: url) retry (matched iOS fix)
- backend: added startup warning for unconfigured DSVIDEO_BASE_URL

All other fixes verified correct. No new P0/P1s introduced.

**Commits:** 6c812bf (cycle 1 fixes — 15 issues), bad0420 (P5B regressions — 2 issues)

## Verdict — Cycle 2
**DIAGNOSTIC CLEAR — No P0/P1s remaining.**

fix_cycle: 2

### Remaining open (P2/P3 — deferred):
- ARCH-01: QuickConnectResolver in Views layer (structural refactor, out of scope)
- ARCH-02: get_server_info + request_tunnel serial (concurrent refactor, out of scope)  
- ARCH-05: No connection state machine (large refactor, out of scope)
- SEC-G: /images/{id} unauthenticated (pre-existing, deferred)
- SEC-C: Missing .privacySensitive() on content views (P2, deferred)
- P3 items: NWPathMonitor network-type change, checkTokenExpiryOnLaunch timing hack, progress_seq bootstrap
