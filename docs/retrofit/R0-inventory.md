# R0 — Inventory (DSVideo, 2026-09-12)

## Test surface
| File | Tests | Kind |
|---|---|---|
| DS_Video_cloneTests.swift | 105 | unit (swift-testing `@Test`) |
| DSReelUITests.swift | 10 | XCUITest (written 2026-09-11) |
| DSReelVisualTests.swift | 5 | XCUITest layout/visual |
| DS_Video_cloneUITests.swift | 2 | launch budget + metric |
| DS_Video_cloneUITestsLaunchTests.swift | 1 | launch screenshot |
| **TOTAL** | **123** | |

Baseline: 105/105 unit PASS; UI suite verified passing 2026-09-11 (9 of 18 run individually).

## Banned-pattern census (grep candidates, bodies confirmed)
| Pattern | Raw hits | Confirmed | Notes |
|---|---|---|---|
| B1 tautology (assert the stub) | 0 | 0 | No mock framework in use; tests decode real JSON fixtures. |
| B2 restating the impl | 0 | 0 | Expected sides are literals throughout — genuinely good. |
| B3 NotNil/NoThrow/exists alone | 4 | 0 | All 4 are `#expect(x != nil)` followed by value assertions. |
| B5 positional / `[0]` / `.first` | 31 | **2** | 29 are `resp.items[0]` against a FIXED JSON fixture — deterministic, not a post-mutation hazard, NOT a violation. 2 are real: see below. |
| B6 happy-path only | — | **see gaps** | Decode tests have good negative coverage. Destructive paths have NO tests at all, so not even a happy path. |
| B7 assertion-free body | 2 | 0 | `testIdentifierMirrorIsComplete` asserts via `requireExists`; `testLaunchPerformanceMetric` is a `measure` metric by design. |

### Confirmed B5/conditional-assertion violations
1. `DS_Video_cloneTests.swift:696` — `if let first = netFailures.first { #expect(...) }`
2. `DS_Video_cloneTests.swift:791` — `if let first = netErrors.first { #expect(...) }`

Both wrap their assertions in `if let`, so the assertions are CONDITIONALLY EXECUTED. A preceding
`!isEmpty` check currently saves them, but the shape is the skip-pattern the doctrine bans: if the
filter ever stops matching, the test passes having verified nothing. Disposition: REPAIR.

## Risk tiering — and the finding that matters

Checked every T-A symbol for ANY reference in the test suite:

| Symbol | Tier | Test refs |
|---|---|---|
| `DownloadManager.deleteDownload(itemId:)` | T-A | **0** |
| `DownloadManager.clearAll()` | T-A | **0** |
| `LocalStore.clearAll()` | T-A | **0** |
| `LocalStore.deleteItems(_:)` | T-A | **0** |
| `LocalStore.migrate()` | T-A | **0** |
| `LocalStore.upsertSingleProgress` | T-A | **0** |
| `LocalStore.markProgressSynced` | T-A | **0** |
| `LocalStore.pendingProgress` | T-A | **0** |
| `DownloadManager.updateResumePosition` | T-A | **0** |
| `APIClient.setProgress` | T-A | **0** |
| `AppState.recordProgress` | T-A | **0** |
| `AppState.flushPendingProgress` | T-A | **0** |
| `AppState.deleteTopShelfSnapshot` | T-A | **0** |
| `APIClient.removeFromWatchlist` | T-A | **0** |
| `SeasonExpansionStore.clear/clearAll` | T-B | **0** |
| `AppState.logout` | T-A | 2 |

**Every destructive and persistence-durability symbol in the app has ZERO test references except
`logout`.** The 105 tests cover URL normalization, JSON decoding, error-message mapping, retry
ladders and key derivation — all genuinely useful, all T-B/T-C, none of them T-A.

This is not a case of fake tests. It is a case of a well-built suite pointed entirely away from the
dangerous code. The existing tests are mostly real (B1/B2 are clean, which is unusual); the problem
is the coverage axis.

## What the existing suite is good at (do not disturb)
- `NormalizedBaseURLTests` — exhaustive scheme/port matrix, literal expectations
- `APIErrorTests` — error-message mapping, now including the TASK-893/895 contract tests
- `APIModelsCodingTests` — real JSON fixtures, tolerant-decode negative cases
- `RetryLadderTests`, `FileProtectionPolicyTests`, `WatchStateTests` — policy-level, literal-asserted

## Retrofit order
1. **T-A:** the progress/resume persistence chain (the 1.3.6 P0s live here), then downloads
   delete/clearAll, then LocalStore delete/migrate/clearAll.
2. **T-B:** SeasonExpansionStore, watchlist, offline/cache reconciliation.
3. **T-C/D:** already partly covered by the new XCUITest suite.
