# Level 1 Diagnostic — DSVideo (iOS + tvOS + Go backend)
**Run:** 2026-09-11 19:44 · **Branch:** main @ 6df3866 · **Tracking:** TASK-886
**Scope:** pre-App-Store-submission full-ship sweep, 4 agents at cap
**Agents:** Scotty (code/arch/security) · Torres (stability/spec) · Data (dead-control) · Vernier (live sim, real NAS)

## VERDICT: DO NOT SUBMIT YET
4 P0 (3 code defects + 1 environmental) · 6 P1 · 9 P2 batched
Tickets: TASK-887 … TASK-898

| # | Severity | Finding | Ticket |
|---|---|---|---|
| 1 | P0 | Downloads write a 22-byte 404 body as the .mp4 | TASK-887 |
| 2 | P0 | Player error screen is an inescapable dead end | TASK-888 |
| 3 | P0 | LocalStore reports ready with no database | TASK-889 |
| 4 | P0 | Only beta Xcode installed (environmental) | — |
| 5 | P1 | tvOS Next Episode unfocusable (recurrence #5) | TASK-890 |
| 6 | P1 | setProgress `applied` contract ignored | TASK-891 |
| 7 | P1 | QuickConnect LAN IPs trusted → cleartext password | TASK-892 |
| 8 | P1 | DecodingError reports healthy server unreachable | TASK-893 |
| 9 | P1 | tvOS hardcoded to http://localhost:5000 | TASK-894 |
| 10 | P1 | Wrong/leaky error text | TASK-895 |
| 11 | P1 | iOS file protection blocks locked-screen writes | TASK-896 |
| 12 | P1 | UITest target is an empty template | TASK-898 |
| 13 | P2 | Polish batch (9 items) | TASK-897 |

Note on method: every P0/P1 was independently re-verified by Friday against the source before
ticketing. Two agent claims were OVERTURNED (Data's C10 "EMPTY", Torres's two extra focus sites)
and one was SHARPENED (the `applied` field is read, but its value is discarded downstream — a worse
bug than reported). Those reversals are recorded inline below.

---

# Phase 7 — Triage (Friday). L1 DSVideo 20260911-1944
All four Phase 5 agents returned. Every P0/P1 below was INDEPENDENTLY VERIFIED by Friday by reading
the code, not accepted on an agent's word. Two agent claims were overturned; both are recorded.

## VERDICT: DO NOT SUBMIT YET. 4 P0 (3 code + 1 environmental), 6 P1.

## P0 — BLOCKERS

### P0-1 · Downloads are comprehensively broken (Vernier, live-verified; Friday code-confirmed)
TWO independent bugs compounding, either one fatal:
(a) ItemDetailView.swift:1067 startDownload() fetches playback info, then calls
    `stopPlayback(sessionID:)` at :1079 — BEFORE passing `info.streamUrl` to the download manager
    at :1096. The comment at :1076 claims "the download itself doesn't use it." THAT PREMISE IS
    FALSE: videoURL is derived from that same session's info. Stopping the session invalidates the
    URL being handed over. Vernier proved it over HTTP: stream returns 206 + real bytes, then
    404/22 bytes immediately after stop.
(b) DownloadManager.swift:783 didFinishDownloadingTo never checks HTTPURLResponse.statusCode.
    URLSession calls this delegate for a 404 exactly as for a 200. The error body
    `{"error":"not_found"}` (22 bytes) is copied, moved to `{itemId}.mp4` by completeDownload
    (:651-662), given FileProtectionType.complete, and the item is marked DOWNLOADED.
    DAMNING CONTRAST: the ONLY statusCode check in the entire file is at :737-740 — for the POSTER
    THUMBNAIL. The artwork is validated; the movie is not.
USER IMPACT: every download silently produces a 22-byte file that presents as a downloaded movie.
Offline playback — a headline feature — cannot work. Verified on disk in the app container.
FIX: validate statusCode in the delegate before accepting the file AND stop releasing the session
before the download completes (or re-resolve the URL for the download).

### P0-2 · Player error screen is an inescapable dead end (Vernier, live-verified)
Retry, Dismiss, and swipe-to-dismiss are ALL inert on the "Playback Failed" overlay. Vernier made
three precise taps inside Dismiss's frame; the a11y tree stayed byte-identical. Landscape, no tab
bar, no back control. ONLY escape was backgrounding the app.
FRIDAY'S MECHANISM WORK (partial — the symptom is live-proven, the precise cause is not fully
pinned and the fixer must confirm before editing):
  - errorOverlay (GestureVideoPlayer.swift:471-514) reads CORRECT in isolation: Dismiss calls
    onDismiss?(). It sits last in the ZStack (:465), so z-order is not obviously the problem.
  - Candidate 1: gestureOverlay (:420, defined :519) is a full-frame Color.clear with
    .contentShape(Rectangle()) + DragGesture + SpatialTapGesture and .accessibilityHidden(true).
    It has NO .allowsHitTesting(playerError == nil) guard. The accessibilityHidden is consistent
    with Vernier seeing an unchanged a11y tree while taps vanished.
  - Candidate 2: ItemDetailView.swift:1364 onDismiss closure — on a playback FAILURE both
    exitPosition and lastKnownDuration are 0, so it takes the guard branch and calls the
    environment `dismiss()`. If the player is not presented as a sheet in that path, dismiss() is
    a no-op and the user is trapped. This matches "Dismiss does nothing" exactly.
  Both are cheap to fix together; do not guess — reproduce first.
USER IMPACT: any playback failure traps the user until they force-background the app. An App Store
reviewer hitting one unplayable file sees an app with no way out.

### P0-3 · LocalStore reports success when it has no database (Data; Friday-confirmed)
LocalStore.swift:68 — `isReady = true` is OUTSIDE the do/catch at :62-67. If setup() throws, `db`
stays nil, ensureReady() returns instantly forever, and all 19 `guard let db else { return }` sites
become SILENT NO-OPS. upsertSingleProgress (:430) — the resume-position writer called by
recordProgress BEFORE the network POST — is one of them.
Why the outbox cannot save it: no local row means pending_sync is never set, so
flushPendingProgress() has nothing to replay. The retry machinery is well-built and irrelevant;
it can only replay rows that reached SQLite.
Mitigating: the failure IS logged (log.error at :66). But there is no user-visible signal and no
health flag anywhere.
USER IMPACT: watch half a film, exit, resume position was never written. Presents as a server bug.
FIX: only set isReady on success; on failure set a degraded flag, surface it, and attempt recovery.

### P0-4 · SUBMISSION BLOCKER (environmental, not a defect) — Friday, direct
Only /Applications/Xcode-beta.app exists on this machine (Xcode 27.0, build 27A5194q, active).
No release Xcode installed. ASC rejects beta archives with INVALID_BINARY.
ALREADY HARDENED: check_xcode (fastlane/Fastfile:59) catches this on three independent signals and
is wired into build_and_upload (:200), build_and_upload_tvos (:308) and :doctor (:148). It fails in
seconds instead of after a 30-minute archive. The prior lesson held.
ACTION (Ryan only): install release Xcode, then `sudo xcode-select -s /Applications/Xcode.app`.
Verify: `xcodebuild -version` build number must NOT end in a lowercase letter.

## P1

### P1-1 · tvOS "Next Episode" is rendered and unfocusable — recurrence #5 (Torres; Friday ARBITRATED)
ItemDetailView.swift:505. `.buttonStyle(.plain)`, deliberate `#if os(tvOS)` styling branches
(font + minHeight: 64), in a plain VStack (NOT a List), reached from TVShowDetailView.swift:819
inside `#if os(tvOS)`.
CONCLUSIVE EVIDENCE: the same view declares
  `enum ActionButton: Hashable { case play, fromBeginning, watchlist, watched }`  (:263)
with all four bound via .focused() (:298, 326, 353, 384). Next Episode is NOT in the enum. The view
demonstrably knows how to do focus management; this button was omitted from it.
WHY IT SURVIVED: scripts/check-tvos-focus.sh only locks down the PLAYER's TVFocusField enum — its
own header says so. ItemDetailView was never in the guard's scope.
*** ARBITRATION: Data reported C10 as EMPTY. Data was WRONG; Torres was RIGHT. Vernier's live sim
run ALSO reported 0 unreachable controls — but Vernier never reached an episode detail screen with
a next episode available, so this button was outside the live path. Two of three agents missed it.
The code evidence is unambiguous. DO NOT dismiss this because the live run came back clean. ***
FIX: add `case nextEpisode` to ActionButton, bind .focused(), and EXTEND check-tvos-focus.sh to
cover ItemDetailView so recurrence #6 is caught by CI.

### P1-2 · setProgress's `applied` contract is documented and then ignored (Torres; Friday SHARPENED)
APIClient.swift:203 setProgress is @discardableResult returning Bool, and its own doc at :199-201
says: "callers must not treat a 200 alone as 'saved'." BOTH call sites discard it —
AppState.swift:1768 (recordProgress) and :1842 (flushPendingProgress) — and each then calls
markProgressSynced UNCONDITIONALLY.
CONSEQUENCE (worse than Torres scored it; he wrote "never read" — it IS read at :216): when the
server replies applied:false (write superseded/discarded), the client marks the row SYNCED and
clears it from the outbox. Progress is dropped on BOTH ends.
USER IMPACT: resume position quietly reverts. This is the exact bug the server field was added to
expose, and the signal is thrown away at the last step.
FIX: honor the Bool — on false, leave pending_sync set so the outbox retries.

### P1-3 · QuickConnect LAN IPs trusted verbatim → password over cleartext HTTP (Scotty; Friday-confirmed)
QuickConnectResolver.swift:60-77. `interface[].ip` from the QuickConnect response is appended to
lanIPs with no validation beyond non-empty, then turned into `http://{ip}:{port}` candidates.
AppState.login() (:577) POSTs `savedPassword` to each candidate in order, LAN first (2s timeout).
A hostile/compromised QuickConnect response naming a PUBLIC ip harvests the NAS password in clear.
THE CHECK ALREADY EXISTS AND IS CORRECT: AppState.isPrivateLANAddress (:434-448) handles
192.168/10/172.16-31/169.254/localhost/.local — and is called for exactly this decision in five
other places (:165, :208, :469, :1141, ServerSetupView:454). It is simply not called here.
The code's own comments prove the threat model is understood ("HTTP to a public IP ... would send
credentials in plaintext"). One-line fix: filter lanIPs through isPrivateLANAddress.

### P1-4 · DecodingError reports a healthy server as unreachable (Scotty; Friday-confirmed)
APIClient.swift:594 rethrows DecodingError RAW. Every consumer does
`(error as? APIError)?.userMessage ?? "Could not connect to server."` (e.g. AppState.swift:1705),
so the cast fails and the user is told the server is unreachable while it is healthy and responding.
The comment immediately above (:589-592) calls decode failures "the quietest class of bug in this
app" and cites ItemsResponse.total silently breaking Watchlist — then the user-facing text hides it.
Breaks the project's standing error-language rule on the exact failure mode the code calls out.
FIX: add APIError.decode and wrap at the single choke point. No call-site changes needed.

### P1-5 · tvOS ships with the server address hardcoded to http://localhost:5000 (Vernier, live)
Visible on the SHIPPED tvOS sign-in screen. On an Apple TV, localhost is the Apple TV itself. Also
poisons pairing: device log shows the exchange POSTing to localhost and getting 403, while the same
code redeemed 200 from curl. First-run experience on the platform is broken out of the box.

### P1-6 · Wrong + leaky error text (Vernier, live) — standing error-language rule
(a) A failed download surfaces "This video's format isn't supported." — sends users off to
    re-encode perfectly good files. Wrong cause.
(b) Raw status codes leak to users: "Server error (403)." The server actually returned a clean
    401 invalid_or_expired_code; the good information is discarded and the view's own sensible
    fallback string is bypassed.

## P2 (fix if cheap, do not block submission)
- XXL text: the PLAY button's label collapses to a clipped glyph fragment. Vernier argues P1 — the
  primary action losing its label at accessibility sizes is a plausible review-guideline risk.
  Friday: fix this one, it is cheap and it is the primary CTA.
- tvOS a11y tree returns ONLY the Application node on every screen (zero children) while iOS
  returns rich labelled trees through the identical harness. May be a harness limit, but the
  asymmetry argues real. NEEDS A MANUAL VOICEOVER CHECK ON APPLE TV BEFORE SUBMIT.
- ItemsGridView.swift:104 — a genre filter with no server-side matches renders "No Videos · This
  library has no videos yet" while the chip bar still shows the active filter. Screen contradicts
  itself. (Data, C11 "the state that lies".)
- main.go:1023 /api/v1/images/{id} is public + unthrottled and item IDs are hex(absolute path), so
  200-vs-404 enumerates every title and the NAS folder tree from the WAN. Documented/accepted;
  putting the existing limiter on this one route removes the practical oracle without touching
  Top Shelf.
- main.go:1641 redactSensitiveParams is global middleware that REPLACES r.URL for all downstream
  handlers, so webapi.go:241 getWebAPISession reads `_sid=[REDACTED]` and query auth fails. Only
  the legacy Synology WebAPI compat layer; the shipping app uses /api/v1 + Bearer. Not a risk now.
- tvOS invisible-focus candidates: TVMainView.swift:526 rail header and TVShowDetailView.swift:1794
  candidate rows. *** FRIDAY DOWNGRADED these from Torres's P2 claim: the rail header's own comment
  shows focus highlight WAS deliberately reasoned about, and the candidate rows are inside a List,
  which grants row focus on tvOS. Not dead controls. ***
- PiP restore re-fires .onAppear; setupPlayer() guards re-entry but setupAudioInterruptionObserver()
  and setupVolumeObserver() do not, so they overwrite observer tokens and stack a duplicate volume
  sink. (Scotty, P3→ keep at P3.)
- docs/api/DSVideoBackendAPI.md documents 16 of 87 routes. *** Torres verified the LIVE wire
  contract independently and client-decoded keys match server-emitted keys EXACTLY (PlaybackInfo's
  11 fields all present in handlePlayback). DOC defect, NOT a wire defect. Do not block. ***
- No dark-mode differential exists: the app forces its own dark theme and ignores system
  appearance entirely. Light/dark captures byte-identical. Worth a product decision, not a bug.
- UITest target is the untouched Xcode template (2 stubs asserting nothing) — zero automated UI
  coverage. This is WHY P0-1 and P0-2 reached a pre-submission review. Post-submission work.

## CLEARED / OVERTURNED (recorded so a clean check is distinguishable from a skipped one)
- 5 of 6 doctor handoffs were FALSE POSITIVES, agreed independently by Scotty AND Torres:
  notification-leak (struct View cannot have deinit; observers removed in cleanup() at :1867-1873),
  timer-retain ([weak self] at both levels + invalidate on every logout path), orientationLock
  (genuinely isolated; SWIFT_STRICT_CONCURRENCY = complete), task-in-init ([weak self], main-actor,
  once per process), task-no-cancel x126 (pattern sound; nothing re-fires on body re-eval),
  array-bounds x26 (no reachable crash from server data; the one server-fed path — Trickplay's
  WebVTT parser — count-checks every subscript). RECOMMEND muting task-no-cancel for this repo.
- 11/11 recent commits VERIFIED, 0 partial, 0 regressed. 28f5cad's 480-line deletion sweep: all 22
  deleted symbols audited, zero live callers, every residual grep hit is a tombstone comment.
- ZERO regressions of prior-diagnostic FIXED items. The 2026-09-03 sweep's 5 P0s and 13 P1s all
  still fixed in HEAD.
- Credentials: password AND token in Keychain with WhenUnlockedThisDeviceOnly; nothing sensitive in
  UserDefaults. All 28 dlog sites reviewed individually — every token through redact(), no
  passwords, no session IDs, zero print/NSLog.
- Rate-limit fix (7749135) correct: loopback-peer-gated, last-XFF-entry, True-Client-IP ignored;
  nginx confirmed setting X-Real-IP at all four proxy blocks.
- Path traversal contained everywhere user input reaches a path.
- ATS LAN exemption narrowly scoped — verified nothing in normalizedBaseURL rewrites https→http.
- Session leaks (cf48ba0) genuinely hold, including detached stopPlayback on dismiss and the
  awaited release before stream replacement.
- Test validity (0k–0p): ZERO XCTSkip in the repo. 100/100 passes are real executions.
- Builds: iOS Release + tvOS Release both SUCCEEDED, zero real warnings, Swift 6 mode.
- Go: build clean, vet clean, 4/4 test packages pass.
- Dead-control classes EMPTY: C1 buttons, C2 toggles (all 11 persisted keys trace to a live
  reader), C3 navigation (11/11 modals have presenters), C6 server fields (both directions),
  C7 error paths (48/48 Go codes mapped, zero orphans), C8 enum cases (38 enums), C9 async.
- Version: live ASC confirms both platforms at 1.3.5 READY_FOR_SALE (divergence re-converged).
  1.3.6 in Fastfile and project AGREE and is unused. Correct and safe.

## KNOWN COVERAGE LIMITS OF THIS RUN (stated so the pass is honest)
- Both LocalStore P0s (P0-3) and F2 below are CODE-READING confirmations; neither Data nor Friday
  executed them. F2 especially wants a real-device check.
- F2 (P1-ish, folded here): LocalStore.swift:133 applies FileProtectionType.complete to dsreel.db
  on iOS while continueAudioInBackground defaults TRUE (GestureVideoPlayer:139, MainView:1348), so
  locked-screen playback is the DEFAULT path. While locked, the protected file is unwritable and
  DownloadManager.updateResumePosition (:471) opens with `try? Data(contentsOf:)` — throws,
  swallowed, no log. Lock the phone, listen 40 min, unlock: position lost for the locked interval.
  The author ALREADY FIXED this exact hazard on tvOS (:145-157 deliberately sets .none, noting
  .complete "makes the database unreadable to its own app"). The intermittent iOS lock window is
  the same bug and survived. VERIFY ON DEVICE, then fix.
- One real-device LAN→cellular switch mid-film was NOT executed (Torres SPECULATIVE). Mechanisms
  read correct: stall/failed-to-end observers with teardown removal, .networkConnectionLost →
  serverUnreachable, reconcileOfflineFlag self-heals.
- Data's C6/C7 diffs relied on grepping Go map-literal keys and writeErr call sites; if the backend
  emits errors through another helper, that coverage has a hole.
- Vernier's live tvOS run never reached an episode-detail screen with a next episode available —
  which is exactly why P1-1 needs the code evidence, not the live negative.
