# MaxReview Report — DSVideo — 2026-04-13
## Cycle 1 — 2026-04-13

### Build Status
- iOS (iPhone 17 Pro simulator, iOS 26): BUILD SUCCEEDED, 0 warnings
- tvOS: BUILD SUCCEEDED, 1 asset warning (App Icon stack layers)
- Unit tests: 47/47 PASS
- UI tests: 3/3 pass (empty stubs — flagged as TASK-467)

### New Issues This Cycle (26 net-new, after deduplicating TASK-464 = TASK-458)

**Code (Scotty)**
- TASK-451 P1: No reload after MetadataFixerSheet success — stale data shown
- TASK-453 P1: handleTVShowTMDbFix OR clause dead for re-fix case — UPDATE affects 0 rows
- TASK-455 P2: MetadataFixerSheet "updated" confirmation never visible (dismiss fires first)
- TASK-457 P2: addedAt/lastWatchedAt sort uses fragile lexicographic string comparison
- TASK-459 P2: LibrariesView local libraries stale before homeLibraries populates
- TASK-461 P3: O(n²) duplicate-title detection in ForEach body

**Security (Odo)**
- TASK-452 P1: GET /settings leaks TMDb API key to all authenticated clients
- TASK-454 P2: TVShowsView logs full NAS URL to os.log
- TASK-456 P2: handleSyncItems uses string-interpolated SQL (not exploitable now, fragile)

**Layout/A11y (Vernier)**
- TASK-458 P2: Sort chips announce wrong sort option to VoiceOver
- TASK-460 P2: Sort chip buttons missing .isButton trait
- TASK-462 P2: TMDb ID disambiguation badge absent from accessibilityLabel
- TASK-463 P3: Searching ProgressView missing label in MetadataFixerSheet

**Integration (Worf)**
- TASK-465 P2: releaseNewest/Oldest sort has no iOS entry point (enum exists, not in displayedChips)
- TASK-466 P2: LocalStore has zero unit tests
- TASK-467 P2: UI test files are empty Xcode stubs

**Spec Gaps (Worf Phase 3)**
- TASK-468 P2: LoginView branding wrong (logomark color, field backgrounds, no icons)
- TASK-469 P3: LoginView secondary CTA + "or" divider absent
- TASK-470 P2: ItemsGridView missing Filter button + All/Rating chips
- TASK-471 P3: ItemsGridView item count label not rendered
- TASK-472 P2: ItemDetailView trailer button absent from action row
- TASK-473 P2: ItemDetailView cast is vertical text list, not horizontal avatar scroll
- TASK-474 P1: GestureVideoPlayer center play/pause overlay present (spec Priority #1 removal)
- TASK-475 P3: GestureVideoPlayer scrub thumb not custom (spec: 16pt white circle)
- TASK-476 P2: Skip interval 30s, spec requires 15s
- TASK-477 P1: Player bottom control strip missing (skip, rewind, play/pause, forward, end)
- TASK-478 P2: SearchView error state wrong component
- TASK-479 P2: SearchView results grid, spec requires list rows
- TASK-480 P3: DownloadsView storage label format + progress bar height wrong
- TASK-481 P2: DownloadsView "Queued" state not implemented
- TASK-482 P2: TabView not custom DSTabBar (spec requires uppercase labels, dsAccent tint)
- TASK-483 P2: Continue Watching uses portrait cards, spec requires landscape ContinueWatchingCard

### By Severity (this cycle's new issues only)
- P0: 0
- P1: 4 — TASK-451, TASK-453, TASK-474, TASK-477
- P2: 18
- P3: 6 (incl. TASK-461, TASK-463, TASK-469, TASK-471, TASK-475, TASK-480)

### Verdict
FIX REQUIRED — proceeding to Phase 5A. Cycle 1 of 3.
Prioritizing P1s first: TASK-451, TASK-452, TASK-453, TASK-474, TASK-477, then P2s.
