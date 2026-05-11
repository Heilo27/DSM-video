# MaxReview Report — DSVideo — 2026-04-14
## Cycle 1 — 2026-04-14

### Summary
- Total open issues (this run): 49
- Integration issues: 4 (TASK-499–502)
- Code issues: 11 (TASK-513–519, 522, 524, 526, 528)
- Architecture issues: 10 (TASK-503–512)
- Layout issues: 2 (TASK-536, 539)
- Accessibility issues: 8 (TASK-531–535, 537–538, 540)
- Security issues: 7 (TASK-520–521, 523, 525, 527, 529–530)
- Spec compliance issues: 7 (TASK-541–547)

### By Severity
- P0 (blocking): 0
- P1 (critical): 5 — TASK-503, TASK-513, TASK-514, TASK-527, TASK-531
- P2 (major): 30 — TASK-499, 500, 504–506, 508–509, 511, 515–519, 520–522, 524, 529, 532–536, 537–543
- P3 (minor): 14 — TASK-501, 502, 507, 510, 512, 523, 525–526, 528, 530, 544–547

### P1 Detail
| Ticket | Issue |
|--------|-------|
| TASK-503 | autoPlay .onAppear fires on player dismiss → infinite relaunch loop |
| TASK-513 | Backend handleItemsJustWatched N+1 getProgress inside open rows cursor (deadlock) |
| TASK-514 | autoPlay re-triggers on every ItemDetailView re-appear (duplicate of 503 root cause, iOS side) |
| TASK-527 | handleShowDetail missing path-traversal guard — attacker can traverse DB via showName |
| TASK-531 | VoiceOver skip label says "30 seconds" but skipSeconds = 15 |

### P2 Detail (30 tickets)
TASK-499: TVShowDetailView poster imageURL missing version cache-buster
TASK-500: ItemDetailView backdrop/poster missing version cache-buster
TASK-504: CW autoPlay bypasses TVShowDetailView — next episode button never available
TASK-505: Concurrent homeLoad + heartbeat can produce two runDeltaSync calls
TASK-506: LocalStore.migrateFromJSONCache blocks actor on sync Data(contentsOf:)
TASK-508: TVShowDetailView tvOS/iOS header imageURL missing version cache-buster
TASK-509: Backend incrementSeq non-atomic under concurrent writes
TASK-511: TVLibraryRail.load has no refresh path after delta sync
TASK-515: handleSyncHeartbeat registered outside auth middleware — unauthenticated
TASK-516: EpisodeDetailView missing autoPlay — TV CW episodes don't auto-play
TASK-517: handleTVShowSeasons tvRoot not LIKE-escaped
TASK-518: LibrariesView pull-to-refresh silently ignored when libraries already loaded
TASK-519: handleProgressBatch no server-side cap on ID count
TASK-520: Downloaded video files lack NSFileProtectionComplete
TASK-521: DownloadedItem metadata in UserDefaults (unencrypted)
TASK-522: handleTVShowsList lastWatchedAt groups by i.path not folder
TASK-524: PlayerSheet.start() doesn't reset isOffline on retry
TASK-529: No rate limiting on auth endpoints
TASK-532: Player controls in VoiceOver AX tree when hidden
TASK-533: HomeRail "See All" touch target below 44pt, font not Dynamic Type
TASK-534: HomeRail section title fixed 18pt — not Dynamic Type
TASK-535: SearchView accessibilityLabel uses raw lowercase type string
TASK-536: DownloadsView delete only via context menu — no visible affordance
TASK-537: SettingsView port TextField fixed 70pt — truncates at XXL
TASK-538: TVShowDetailView header VStack not grouped for VoiceOver
TASK-539: iOSEpisodeRow touch target below 44pt
TASK-541: GestureVideoPlayer skip-to-start / skip-to-end buttons absent
TASK-542: ItemDetailView Trailer button absent
TASK-543: ItemsGridView Filter button absent
TASK-540: ItemDetailView 300pt backdrop hides play button below fold on SE

### Verdict
FIX REQUIRED — proceeding to Phase 5A. Cycle 1 of 3.

### Notes
- TASK-503 and TASK-514 are the same root cause (missing autoPlay sentinel). Fix once in ItemDetailView.
- TASK-499/500/508 are all the same pattern (missing version: param on imageURL calls). One fix pass covers all three.
- P1 TASK-527 (path traversal) must be fixed before any other P1.
