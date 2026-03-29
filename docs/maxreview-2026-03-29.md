# MaxReview — DSVideo — 2026-03-29

**Cycle:** 1 of 3 max
**Branch:** main
**Status:** Phase 3 in progress → Fix cycle pending

---

## Phase 1: Integration Tests — PASS

- iOS Simulator build: ✓ PASS
- tvOS Simulator build: ✓ PASS
- Go backend build: ✓ PASS
- Go tests: ✓ PASS (no test files — coverage gap noted)
- Swift test suite: ✓ PASS (38 tests) — fixed stale imports + rewrote against current API (TASK-234)
- Swift warnings: 1 (appintentsmetadataprocessor — tool-level, not code)

---

## Phase 2: Code + Architecture + Layout/A11y Review

### Phase 2A — Code Review (Scotty)
**P0: 0 | P1: 6 | P2: 16 | P3: 3**

| Ticket | Severity | Issue |
|--------|----------|-------|
| TASK-235 | P1 | Path traversal in HLS segment serving — missing prefix check |
| TASK-236 | P1 | LIKE injection via showID — % and _ wildcards not escaped |
| TASK-237 | P1 | seasons sort panics on int64 type assertion |
| TASK-238 | P1 | EpisodeDetailView.current index OOB after episode list reload |
| TASK-239 | P1 | X-TMDb-API-Key per-request client creation — header injection |
| TASK-258 | P1 | showID not percent-encoded in tvShowSeasons/tvShowEpisodes |
| TASK-252 | P2 | rows.Err() never checked after DB row iteration loops |
| TASK-253 | P2 | backgroundFetchTask never cancelled on view disappear |
| TASK-254 | P2 | sortedItems recomputed on every body eval — memoize |
| TASK-255 | P2 | Recent searches comma-delimited — corrupts on comma queries |
| — | P2 | JWT 30-day expiry, no revocation persistence across restarts |
| — | P2 | InsecureSkipVerify on localhost HTTPS fallback (no host guard) |
| — | P2 | SecItemAdd result silently discarded |
| — | P2 | completeDownload silently discards file move failure |
| — | P2 | AVPlayerLayer force cast will crash if layerClass removed |
| — | P2 | DownloadManager backgroundSession IUO |
| — | P2 | timeObserver leak if cleanup() skipped |
| — | P2 | play sessions map never evicted — unbounded memory growth |
| TASK-240 | P2/P1 | N+1 getProgress calls per library load |
| — | P3 | Demo SHA-256 comparison provides no security over plaintext |
| — | P3 | tvShowSeasons/tvShowEpisodes path components unvalidated on Go side |
| — | P3 | try? audioSession silently swallows audio session errors |

### Phase 2B — Architecture Review (Geordi)
**P0: 0 | P1: 4 | P2: 4 | P3: 3**

| Ticket | Severity | Issue |
|--------|----------|-------|
| TASK-256 | P1 | Library state duplicated between SidebarView and LibraryHomeView |
| — | P1 | HomeCache reads disk on main thread during view init |
| TASK-257 | P1 | macOS AuthenticatedImage has no shared cache |
| — | P1 | APIClient double reconstruction during QuickConnect login |
| — | P2 | HomeCache reads disk 4x per load cycle |
| — | P2 | GestureVideoPlayer mixes Combine + structured concurrency |
| TASK-255 | P2 | Recent searches comma storage (cross-filed) |
| — | P2 | DownloadManager singleton in @State — untestable |
| — | P3 | normalizedBaseURL is a free function |
| — | P3 | Library.kind is untyped String with scattered raw literals |
| — | P3 | QuickConnectResolver not reviewed |

### Phase 2C — Layout/A11y Review (Vernier)
**P0: 2 | P1: 5 | P2: 8 | P3: 7**

| Ticket | Severity | Issue |
|--------|----------|-------|
| TASK-241 | P0 | Dynamic Type disabled — hard-coded Font.system(size:) throughout |
| TASK-242 | P0 | dsTextSecondary contrast ~4.1:1 + year labels ~3.5:1 (WCAG 1.4.3) |
| TASK-243 | P1 | Sort chip touch targets ~39pt |
| TASK-244 | P1 | Metadata fix button ~19pt touch target + no accessibilityLabel |
| TASK-245 | P1 | Login tagline contrast ~2.5:1 on brand red |
| TASK-246 | P1 | GestureVideoPlayer close button ~42pt |
| — | P1 | iOSEpisodeRow xmark button no touch target |
| — | P1 | Episode NavigationLink no accessibilityHint |
| TASK-247 | P2 | Watched badge no accessibilityLabel on iOS poster cells |
| TASK-248 | P2 | Progress bar not accessibilityHidden |
| TASK-249 | P2 | LaunchAnimationView not accessibilityHidden |
| — | P2 | TMDb candidate buttons no accessibilityLabel |
| — | P2 | iOSCircularProgress announces "Episode 0" when number nil |
| — | P2 | TVLoginView server field no accessibilityHint |
| — | P2 | MetadataFixer search results no accessibilityLabel |
| — | P2 | iOSSeasonSection chevron no accessibilityHint |
| TASK-250 | P3 | Sort chip label uses arrow symbols in accessibilityLabel |
| TASK-251 | P3 | "See All" no rail context in accessibilityLabel |
| — | P3 | QR scanner no VoiceOver announcement on success |
| — | P3 | TVEpisodeRow "Episode 0" when number nil |
| — | P3 | downloadIconButton empty accessibilityValue |
| — | P3 | Season header button no expand/collapse hint |

---

## Phase 3: Spec Compliance — In Progress

---

## Triage Summary (Cycle 1 — pre-Phase 3)

| Severity | Count |
|----------|-------|
| P0 | 2 |
| P1 | 15 |
| P2 | 28 |
| P3 | 13 |
| **Total** | **58** |

**Verdict:** Fix cycle required. No P0 crashes/security, but 2 P0 accessibility issues (WCAG rejectable), 4 security P1s in backend, and 2 crash P1s in Swift.

---

## Fix Cycle 1 Plan

**Scotty handles:** TASK-235, 236, 237, 238, 239, 240, 252, 253, 254, 255, 258
**Vernier handles:** TASK-241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251
**Arch deferred to Cycle 2:** TASK-256, 257 (larger refactors)
