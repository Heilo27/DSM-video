# Level 1 Diagnostic — DSVideo (tvOS) — 2026-06-05
## Cycle 1

Build: tvOS SUCCEEDED / iOS SUCCEEDED
Focus: tvOS experience — layout, flow, ease of use, missing features.

## By Severity

### P1 (6)
- TASK-691 [Code] TVShowsView tvOS grid blank — sortedShows never populated, .onChange/.onAppear inside #if !os(tvOS)
- TASK-659 [Stability] Season never auto-expands after resolveResumePoint — @State isExpanded set in init, no onChange to react
- TASK-657 [Stability] firstUnwatched algorithm wrong — S2E1 not nominated after S1 100% watched
- TASK-654 [Stability] Unbounded concurrency — 20-season show fires 40 simultaneous requests
- TASK-709 [UX] All seasons collapsed by default on show detail — user must press Select just to see episodes
- TASK-705 [Layout] First home rail header clipped behind toolbar — "Just Added" shows as "st "

### P2 (12)
- TASK-697 [Code] homeIsCacheDecoding stuck true on offline cold-start — homeLoad permanently blocked, force-quit required
- TASK-656 [Stability] CancellationError swallowed in resolveResumePoint TaskGroup — tasks run after view dismissed
- TASK-690 [Stability] Blank screen on cross-season advance when fetchNextSeason fails — no recovery path
- TASK-663 [Integration] No interactive scrub bar on tvOS — display-only, no touchpad scrub
- TASK-658 [Integration] TVSettingsView skeleton — quality/subtitle/speed not settable on tvOS
- TASK-706 [Layout] Home rail cards use .plain buttonStyle — focus ring below 10-foot threshold
- TASK-717 [UX] Start Over button async layout shift — Play button moves after focus lands
- TASK-718 [UX] 8+ d-pad presses to start episode from home
- TASK-660 [Integration] Watchlist UI absent on tvOS — backend wired
- TASK-670 [Integration] Next Episode button absent from tvOS detail page
- TASK-683 [Code] tvOS seek 30s increments vs Apple HIG 10s standard
- TASK-699 [Code] Speed cycle exact Float equality — silent reset; play() ignores playbackRate

### Verdict
FIX REQUIRED — Cycle 1 of 3. Proceeding to Phase 5A.
