# MaxReview Report — DSVideo — 2026-04-10
## Cycle 0 — Initial Review

### Summary
- Total open issues: 73
- Integration issues: 2
- Code issues: 16
- Architecture issues: 14
- Layout issues: 13
- Accessibility issues: 13
- Security issues: 14
- Spec compliance issues: 3

### By Severity
- P0 (blocking): 2 — TASK-364, TASK-367
- P1 (critical): 13 — TASK-322, TASK-343, TASK-345, TASK-347, TASK-349, TASK-351, TASK-354, TASK-357 (note: some may overlap Geordi P1 — TASK-359)
- P2 (major): 38
- P3 (minor): 20

### Full Ticket Breakdown

**Integration (Worf — Phase 1)**
- TASK-322 P1 — Test suite compile failure (3 errors block all 47 tests)
- TASK-323 P3 — print() calls bypass structured Logger in DownloadManager + GestureVideoPlayer

**Code (Scotty — Phase 2A)**
- TASK-343 P1 — tvOS home rail threshold diverges from iOS (> 0 vs >= 0.05)
- TASK-345 P1 — tvOS Just Added doesn't exclude watched items (iOS does)
- TASK-347 P1 — tvOS bypasses LocalStore entirely; large libraries truncated at 200 items
- TASK-349 P1 — LocalStore DB init errors silently swallowed (try?)
- TASK-351 P1 — Double progress sync on app background (GestureVideoPlayer + PlayerSheet both fire)
- TASK-354 P1 — Download error overwrites detail view error state, destroys header
- TASK-357 P2 — LocalStore queryJustAdded includes in-progress items (appear in both rails)
- TASK-360 P2 — (details in scratch)
- TASK-362 P2 — Connect button disabled when offline blocks LAN-only users
- TASK-366 P2 — (details in scratch)
- TASK-369 P2 — Home rail TV episode navigation uses showName as show ID (API expects opaque ID)
- TASK-372 P2 — recentlyWatched rail has no item cap (Continue Watching/Just Added capped at 10)
- TASK-375 P2 — (details in scratch)
- TASK-379 P2 — (details in scratch)
- TASK-382 P3 — (details in scratch)
- TASK-385 P3 — (details in scratch)

**Architecture (Geordi — Phase 2B)**
- TASK-355 P2 — AppState god-object (~750 lines, 5+ unrelated concerns, untestable)
- TASK-358 P2 — TVHomeView duplicates AppState home pipeline (own fetch, no SQLite cache)
- TASK-359 P1 — Continue Watching threshold differs iOS vs tvOS (user-visible divergence)
- TASK-361 P2 — PlayerSheet calls api.setProgress() directly at 4 sites, bypasses recordProgress/SQLite
- TASK-363 P2 — Two ISO8601DateFormatter instances per computeHomeRails call (expensive)
- TASK-365 P2 — homeAllItems ghost field never populated; fast-path unreachable in production
- TASK-368 P2 — TVShowsView.sortedShows recomputes O(n log n) on every SwiftUI body evaluation
- TASK-371 P2 — TVLibraryRail fires N independent api.items() calls, bypasses SQLite cache
- TASK-374 P3 — APIClient.librariesSummary() zero call sites, dead code
- TASK-376 P2 — LocalStore.upsertSingleProgress allocates ISO8601DateFormatter per call (high-frequency)
- TASK-378 P3 — 17-column SELECT duplicated verbatim in 3 LocalStore query methods
- TASK-381 P3 — Demo mode guard scattered across 22+ view load() functions
- TASK-383 P2 — startHeartbeatTimer/stopHeartbeatTimer public; risk of double-start; fires before login
- TASK-387 P2 — recomputeHomeRails + computeHomeRails dead code in real-data paths

**Layout/Accessibility (Vernier — Phase 2C)**
- TASK-324 P1 — GestureVideoPlayer close button overlaps Dynamic Island on iPhone 16 Pro in fill mode
- TASK-325 P2 — HomeRail title not .isHeader (heading rotor navigation broken)
- TASK-326 P2 — HomeRail ItemPosterCell inner text elements separately focusable from NavigationLink
- TASK-327 P2 — SearchView result NavigationLinks missing accessibilityLabel and hint
- TASK-328 P2 — SearchView no result count announced via AccessibilityNotification (WCAG 4.1.3)
- TASK-329 P2 — ItemDetailView MetadataPills read without context ("2023", "PG-13" with no label)
- TASK-330 P2 — iOSEpisodeRow episode number double-announced (.combine + explicit child label)
- TASK-331 P2 — TVEpisodeRow progress reads "Episode 0 progress" when episodeNumber is nil
- TASK-332 P2 — Scrub preview overlay not accessibilityHidden(true) — VoiceOver reads during gesture
- TASK-333 P2 — TVLandscapeRail titles not .isHeader on tvOS
- TASK-334 P2 — tvOS Settings Sign Out uses .plain style, no .destructive VoiceOver warning
- TASK-335 P2 — TVPairingView countdown not announced at expiry thresholds (WCAG 4.1.3)
- TASK-336 P2 — TVPairingView code + countdown are separate VoiceOver elements; should be grouped
- TASK-337 P2 — PairingCodeView QR scan success has no VoiceOver announcement (WCAG 4.1.3)
- TASK-338 P3 — LibrariesView Label() exposes SF Symbol name before library title
- TASK-339 P3 — LoginView HTTPS toggle label includes "(ON)"/"(OFF)" — redundant with VoiceOver state
- TASK-340 P3 — PlayerSheet loading ProgressView() has no label
- TASK-341 P3 — tvOS season button label omits episode count
- TASK-342 P3 — TVShowsView accessibility label omits season count
- TASK-344 P3 — TVLibraryRail NavigationLink missing hint
- TASK-346 P3 — TVPairingView brand icon not accessibilityHidden(true)
- TASK-348 P3 — SettingsView "How To" Label announces "book, How To..."
- TASK-350 P3 — DownloadsView downloaded item cell missing play hint
- TASK-352 P3 — tvOS Show Detail title+year+seasons not grouped with .combine
- TASK-353 P3 — TVShowsView loading spinner label is generic "Loading" not "Loading TV shows"
- TASK-356 P3 — OfflineBanner appearance not announced to VoiceOver (WCAG 4.1.3)

**Security (Odo — Phase 2D)**
- TASK-364 P0 — Go backend path traversal: file paths served without re-validation against media roots
- TASK-367 P0 — server.py accepts any non-empty username/password (dev server, no real auth)
- TASK-370 P1 — NSAllowsArbitraryLoads=true in Info.plist disables ATS globally
- TASK-373 P1 — Go backend defaults to hardcoded JWT secret "dev-insecure-change-me"
- TASK-377 P1 — InsecureSkipVerify=true for DSM HTTPS localhost auth fallback (MITM risk)
- TASK-380 P1 — logout() clears session token but saved password persists in Keychain
- TASK-384 P2 — SQLite DB + WAL/SHM sidecars lack NSFileProtectionComplete
- TASK-386 P2 — No .privacySensitive() on login/pairing screens (captured in app switcher)
- TASK-388 P2 — Keychain items use kSecAttrAccessibleWhenUnlocked (iCloud-backable) not ThisDeviceOnly
- TASK-389 P2 — Python server JWT has no jti/revocation; logout doesn't invalidate tokens
- TASK-390 P2 — Demo credentials as SHA-256 hashes are brute-forceable offline
- TASK-391 P3 — print() calls in production (one logs NAS image URL)
- TASK-392 P3 — useHTTPS defaults to false; first-launch credential submission is plaintext HTTP
- TASK-393 P3 — Unhandled-path catch-all logs up to 1KB of request body verbatim

**Spec Compliance (Worf — Phase 3)**
- TASK-394 P2 — Downloads/offline playback absent on tvOS
- TASK-395 P2 — tvOS login has no "Remember me" toggle (always persists silently)
- TASK-396 P3 — Metadata fixer absent on tvOS

### Verdict
FIX REQUIRED — proceeding to Phase 5A. Cycle 1 of 3.

**Build status:** iOS + tvOS SUCCEEDED. Test suite compile failure (TASK-322) blocks all 47 tests — fix first.
