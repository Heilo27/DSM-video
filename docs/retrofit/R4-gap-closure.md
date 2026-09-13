# R4 — Gap Closure (DSVideo, 2026-09-12)

Closes the nine mutation survivors R2 found. **43 new tests. Suite: 148 passed / 0 failed**
(105 pre-existing + 43 new).

Every test below carries, in its own doc comment, the specific code change that turns it red.
That note is the contract, and it was verified by re-applying each mutation and confirming the
mapped tests go RED — results in the table at the bottom. A test whose named mutation survives
is a defective test, not an acceptable one.

---

## Test seams added to app code

Three, all minimal, all documented at their definition sites, none behind `#if DEBUG` — the
shipping code path is the path under test.

### 1. `LocalStore` — injectable database URL
`DSM Video/DSM Video/Networking/LocalStore.swift`

`LocalStore.shared` is an actor singleton bound to `<Documents>/dsreel.db`. Any test touching a
write, a delete, or the unavailable path would share that one file with every other test —
order dependent, and on a device run a `clearAll` test would wipe the developer's own library.

Added:
- `private let databaseURLOverride: URL?` — `nil` in production.
- `private init(databaseURLOverride: URL? = nil)`.
- `static func makeForTesting(databaseURL:) async -> LocalStore` — opens at the given URL and
  completes setup before returning.
- `static func makeUnopenableForTesting() async -> LocalStore` — a store whose open is
  guaranteed to fail, for exercising `isUnavailable`. This is the only way to reach the
  unavailable branch at all; without it survivor #4 is untestable.

`openDatabase()` now resolves `dbURL` from the override when present and derives the WAL/SHM
sidecar paths from that URL's directory. With the override nil it computes the identical
`<Documents>/dsreel.db` it always did.

Two incidental corrections inside the seam, both in the failure branch only:
- On a failed `sqlite3_open` the half-open handle is now closed and `db` set to `nil`.
  `sqlite3_open` allocates a handle even on failure, and a non-nil `db` meant the
  `guard let db` at the head of every write path did **not** short-circuit on a dead store —
  contrary to the behaviour the file's own comments describe. `isUnavailable` was already
  correct either way (`setupFailure` covers it), so this changes no reported health, only
  whether writes to a dead store attempt SQLite calls against an unusable handle.
- `setupLogged()` skips the legacy JSON-cache migration when an override is set, so a test
  store neither adopts nor **deletes** the app container's cache file.

### 2. `DownloadManager` — injectable container
`DSM Video/DSM Video/Networking/DownloadManager.swift`

Same problem: a `@MainActor` singleton with bookkeeping at `<AppSupport>/downloads.json` and
media in `<Documents>/Downloads`.

Added:
- `private let containerOverride: URL?` — `nil` in production.
- `init(containerForTesting container: URL)`.

`downloadsDirectory()` and `downloadsMetadataFileURL` fall back to the original URLs when the
override is nil. The test init deliberately uses an **ephemeral** URLSession rather than a
second background session: two live sessions sharing
`com.heiloprojects.dsreel.downloads` is undefined behaviour (the production `init()` comment
says so explicitly), and the test instance never starts a transfer.

### 3. `DownloadManager.shouldAcceptResponse(status:)` — the HTTP gate, extracted
`DSM Video/DSM Video/Networking/DownloadManager.swift`

```swift
nonisolated static func shouldAcceptResponse(status: Int?) -> Bool {
  guard let status else { return true }
  return (200...299).contains(status)
}
```

Lifted verbatim out of `urlSession(_:downloadTask:didFinishDownloadingTo:)`, which the delegate
now calls. Necessary because that delegate takes a live `URLSessionDownloadTask` whose status
cannot be chosen in a unit test. No behaviour change: `nil` status is accepted, matching the
original `if let httpStatus` shape (a `file://` transfer has no status to reject on).

---

## Survivor-by-survivor coverage

### T-A

#### 1. `LocalStore.upsertSingleProgress` — skip the write
Suite: `LocalStoreProgressWriteTests` (7 tests). Every one re-reads through a **second
`LocalStore` instance opening the same file**, so an in-memory cache cannot satisfy them.

| Test | OC | Kills |
|---|---|---|
| `recordedPositionIsReadableFromAFreshStoreOnDisk` | OC-PRG-003, OC-PRG-004 | M5-upsert; swapped position/duration bindings |
| `aStoreWithNoWriteReportsNoProgressAndAnEmptyOutbox` | OC-PRG-004 | negative case — proves the store doesn't report 600 for anything asked of it |
| `aLaterPositionReplacesTheEarlierOneWithoutDuplicatingTheRow` | OC-PRG-002 | M5-upsert; a dropped `ON CONFLICT` clause |
| `eachTitleKeepsItsOwnPositionIndependently` | OC-PRG-003 | M5-upsert; a write that ignores its `itemId` |
| `confirmingASyncClearsTheOutboxButKeepsThePosition` | OC-PRG-005 | M5-upsert; `markProgressSynced` deleting the row |
| `aStaleServerConfirmationDoesNotClearANewerPosition` | OC-PRG-005 | removal of `markProgressSynced`'s value guard |
| `droppingAPermanentlyRejectedRowUnblocksTheOutbox` | OC-PRG-028 | `dropPendingProgress` no-op (the documented outbox stall) |

#### 2. `DownloadManager.updateResumePosition` — skip the offline write
Suite: `DownloadResumePositionTests` (5 tests). Each verifies through a **new
`DownloadManager` over the same container**, which has its own empty cache.

| Test | OC | Kills |
|---|---|---|
| `anOfflineResumePositionIsReadableFromDiskAfterARelaunch` | OC-DWN-020, OC-OFF-015 | M5-resume |
| `aDownloadNeverPlayedReportsNoResumePositionAfterARelaunch` | OC-DWN-020 | negative case |
| `aResumeWriteTouchesOnlyItsOwnTitleAndLeavesNeighboursAtZero` | OC-DWN-020 | M5-resume; a write that stamps every/first entry |
| `aResumeWriteForATitleThatIsNotDownloadedChangesNothing` | OC-DWN-020 | removal of the unknown-id guard |
| `aResumeWriteDoesNotRewriteStoredPathsAsAbsolute` | OC-DWN-007 | reimplementation over `getDownloadedItems()`, which would bake a container path into the file |

#### 3. HTTP status gate — invert it (the 1.3.6 P0, TASK-887)
Suite: `DownloadResponseGateTests` (4 tests), via `shouldAcceptResponse(status:)`.

| Test | OC | Kills |
|---|---|---|
| `aNotFoundResponseIsRejectedSoItsBodyIsNeverStoredAsTheVideo` | OC-DWN-018 | M2-httpfail, directly |
| `everyErrorStatusIsRejectedAndEverySuccessStatusIsAccepted` | OC-DWN-006 | M2-httpfail; 400/401/403/404/410/500/502/503 rejected, 200/206 accepted, all literals |
| `theAcceptedStatusRangeIsExactlyTwoHundredThroughTwoNinetyNine` | OC-DWN-018 | off-by-one at either end (199/200/299/300) |
| `aTransferWithNoHTTPStatusIsAcceptedRatherThanDiscarded` | OC-DWN-008 | negative case — rejecting on *absence* of a status would discard every legitimate non-HTTP transfer |

#### 4. `LocalStore.isUnavailable` — always return false (TASK-889's detection)
Suite: `LocalStoreAvailabilityTests` (3 tests).

| Test | OC | Kills |
|---|---|---|
| `aStoreThatCannotOpenItsDatabaseReportsItselfUnavailableWithAReason` | OC-PRG-026 | M2-ready; also asserts `unavailableReason` names the real problem |
| `aStoreThatOpenedNormallyReportsItselfAvailableWithNoReason` | OC-PRG-026 | negative case — stops the property being pinned to `true` |
| `anUnavailableStoreDiscardsWritesRatherThanPersistingThem` | OC-PRG-026 | pins the behavioural consequence the flag exists to disclose: the write genuinely vanishes |

#### 5 & 6. `LocalStore.clearAll` / `deleteItems`
Suite: `LocalStoreDestructiveTests` (6 tests). Every assertion is count delta + target identity
+ survivor identity. No positional access, no `.first`, no `[0]`.

| Test | OC | Kills |
|---|---|---|
| `signOutClearEmptiesItemsProgressAndSyncCursorsOnDisk` | OC-AUT-022, OC-AUT-023 | M1-clearall; four non-zero preconditions asserted first, plus both cursors reset (a cleared library with a live watermark never re-syncs) |
| `reopeningTheStoreWithoutClearingKeepsEveryItemByIdentity` | OC-LIB-001 | negative case — proves `clearAll` empties the store, not the act of reopening it |
| `deletingOneItemRemovesOnlyThatIdentityAndPersists` | OC-LIB-028 | M6-delitems; and a delete by position |
| `deletingSeveralItemsRemovesEveryNamedIdentityNotJustTheFirst` | OC-LIB-028 | M6-delitems; and a loop that only deletes the first id |
| `deletingAnEmptyListOfItemsRemovesNothing` | OC-LIB-002 | removal of the empty-list guard |
| `deletingAnUnknownIdLeavesEveryRealItemIntact` | OC-LIB-028 | a loose/prefix match, or a fallback that removes the first row |

#### 7. `DownloadManager.deleteDownload` — no-op
Suite: `DownloadDeleteTests` (5 tests). These assert on the **bytes on disk** as well as the
bookkeeping, which is what makes OC-DWN-010 ("actually reclaims space") a real assertion.

| Test | OC | Kills |
|---|---|---|
| `deletingOneDownloadRemovesOnlyItsEntryAndItsBytes` | OC-DWN-009, OC-DWN-010, OC-DWN-023 | M1-delete-dl; and a delete by position |
| `relaunchingWithoutDeletingKeepsEveryDownloadByIdentity` | OC-DWN-009 | negative case — the read path legitimately drops entries whose files are missing, so this has to be pinned separately |
| `deletingATitleThatIsNotDownloadedRemovesNothing` | OC-DWN-009 | removal of the `firstIndex(where:)` guard |
| `deletingTheOnlyDownloadLeavesAnEmptyListAndNoBytes` | OC-DWN-009 | M1-delete-dl at the count-of-one boundary |
| `signOutPurgeRemovesEveryDownloadEntryAndEveryFile` | OC-DWN-026 | `clearAll` no-op, and the partial-removal case OC-DWN-026 names explicitly (bookkeeping cleared, media orphaned) |

### T-B

#### 8. `PlaybackProgress.isFinished` — always return false
Suite: `IsFinishedTests` (7 tests).

`WatchStateTests` already existed and passed, but it exercises `watchState`, which carries its
own threshold comparisons — it never asks `isFinished` for a verdict. That is why the mutation
lived. Every expected value here is a hand-computed literal; no threshold constant appears on
the expected side.

| Test | OC | Kills |
|---|---|---|
| `aFilmWatchedPastNinetyFivePercentIsFinishedAndRestartsFromZero` | OC-PLY-037 | M3-finish (7000/7200 = 97.2%) |
| `aFilmWatchedHalfwayIsNotFinishedAndResumesWhereItStopped` | OC-PRG-001 | negative case — stops the function being pinned to `true` |
| `aLongFilmInsideItsFinalMinuteIsFinished` | OC-PLY-037 | M3-finish on a 3h runtime |
| `theSecondsRemainingRuleDecidesIndependentlyOfPercentage` | OC-PLY-037 | removal of the `< 90s remaining` clause — isolated at 91.1% vs 90.9% of a 1000s item, where the ratio rule cannot reach |
| `theWatchedRatioBoundaryIsStrictlyGreaterThanNinetyFivePercent` | OC-PLY-037 | `>` widened to `>=` (9499 / 9500 / 9501 of 10000) |
| `anUnknownDurationOrUnstartedItemIsNeverFinished` | OC-PLY-022 | removal of either guard — includes the 60s-clip-at-position-0 case, which without the position guard reports "finished" for something never played |
| `aFinishedPositionReadsAsZeroFromTheStoreWhileAnUnfinishedOneDoesNot` | OC-PRG-003 | M3-finish through the persistence path, where it actually bites: `getProgressSeconds` routes through `isFinished` |

#### 9. `APIError.isPermanentRejection` — false for every status
Suite: `PermanentRejectionTests` (6 tests).

| Test | OC | Kills |
|---|---|---|
| `aNotFoundIsPermanentSoTheRowCanLeaveTheOutbox` | OC-PRG-028 | M2-perm, directly |
| `everyPermanentRejectionStatusIsJudgedPermanent` | OC-PRG-028 | M2-perm (400/404/410/422, all literals) |
| `transientAndAuthFailuresAreNotPermanentSoTheRowIsRetried` | OC-PRG-005 | the function pinned to `true` — 500/502/503/401/403/429/network/connection/invalidURL must all be retried, since dropping any of them loses the viewer's place |
| `aServerErrorNamingAMissingItemIsPermanentEvenWithoutAPermanentStatus` | OC-PRG-028 | M2-perm on the message path (`not_found`, `item_not_found`, `invalid_progress` at status 200) |
| `aServerErrorWithATransientOrUnknownReasonIsRetriedNotDropped` | OC-PRG-005 | a default arm returning `true`, or substring-matching the message list |
| `aPermanentStatusDecidesEvenWhenTheReasonTextIsUnrecognised` | OC-PRG-028 | reordering the status and message checks so a non-matching message could veto a 404 |

---

## Mutation verification

Each mutation re-applied one at a time to the real production file, the mapped suites run, then
reverted. `if true { return }` form used rather than a bare `return` — a bare `return` merges
with the following line and produces a compile failure, which R2 recorded mis-reporting itself
as a 2-second "KILL".

All eleven go RED. Zero survivors.

| Mutation | Target | Result | Killed by |
|---|---|---|---|
| M5-upsert | `LocalStore.upsertSingleProgress` — skip the write | **KILLED** (7 failed / 7 passed) | all 7 `LocalStoreProgressWriteTests` + `IsFinishedTests/aFinishedPositionReadsAsZero…` |
| M5-resume | `DownloadManager.updateResumePosition` — skip the offline write | **KILLED** (3 failed / 2 passed) | `anOfflineResumePositionIsReadableFromDiskAfterARelaunch`, `aResumeWriteTouchesOnlyItsOwnTitle…`, `aResumeWriteDoesNotRewriteStoredPathsAsAbsolute` |
| M2-httpfail | HTTP status gate — invert `!(200...299)` | **KILLED** (3 failed / 1 passed) | `aNotFoundResponseIsRejected…`, `everyErrorStatusIsRejected…`, `theAcceptedStatusRangeIsExactly…` |
| M2-ready | `LocalStore.isUnavailable` — always `false` | **KILLED** (2 failed / 1 passed) | `aStoreThatCannotOpenItsDatabaseReportsItselfUnavailableWithAReason`, `anUnavailableStoreDiscardsWrites…` |
| M1-clearall | `LocalStore.clearAll` — no-op | **KILLED** (1 failed / 5 passed) | `signOutClearEmptiesItemsProgressAndSyncCursorsOnDisk` |
| M6-delitems | `LocalStore.deleteItems` — delete nothing | **KILLED** (2 failed / 4 passed) | `deletingOneItemRemovesOnlyThatIdentityAndPersists`, `deletingSeveralItemsRemovesEveryNamedIdentity…` |
| M6-delitems-pos | `LocalStore.deleteItems` — delete the lowest id, not the named one | **KILLED** (3 failed / 3 passed) | the two above + `deletingAnUnknownIdLeavesEveryRealItemIntact` |
| M1-delete-dl | `DownloadManager.deleteDownload` — no-op | **KILLED** (2 failed / 3 passed) | `deletingOneDownloadRemovesOnlyItsEntryAndItsBytes`, `deletingTheOnlyDownloadLeavesAnEmptyListAndNoBytes` |
| M6-delete-dl-pos | `DownloadManager.deleteDownload` — remove index 0 instead of the target | **KILLED** (1 failed / 4 passed) | `deletingOneDownloadRemovesOnlyItsEntryAndItsBytes` |
| M3-finish | `PlaybackProgress.isFinished` — always `false` | **KILLED** (5 failed / 2 passed) | `aFilmWatchedPastNinetyFivePercent…`, `aLongFilmInsideItsFinalMinute…`, `theSecondsRemainingRule…`, `theWatchedRatioBoundary…`, `aFinishedPositionReadsAsZero…` |
| M2-perm | `APIError.isPermanentRejection` — `false` for every status | **KILLED** (4 failed / 2 passed) | `aNotFoundIsPermanent…`, `everyPermanentRejectionStatusIsJudgedPermanent`, `aServerErrorNamingAMissingItem…`, `aPermanentStatusDecidesEven…` |

The two `-pos` rows are extra mutations beyond the census list, added because a no-op mutation
alone does not prove a destructive test asserts on *identity* rather than count. Both die, which
is what the count-delta + target-identity + survivor-identity shape is for.

### Harness note for whoever re-runs the census

Revert each mutation by checking out **the single mutated file**, never
`git checkout -- "DS Video clone/DSM Video/DSM Video"`. The directory-wide form wipes every
uncommitted change under that path — during this pass it destroyed all three test seams (which
were uncommitted by definition) and left the suite with 91 compile errors. Seams were
re-authored identically and the suite verified green again afterwards.

---

## Findings

No product defects. Every new test passes against current `main`.

Two observations worth recording, neither a defect:

1. **`sqlite3_open` leaves a non-nil handle on failure.** Before this pass, a `LocalStore`
   whose open failed kept a usable-looking `db` pointer, so the `guard let db` at the head of
   every write path did not short-circuit — contrary to what the file's own comments state
   ("a failed open leaves `db` nil, which turns every write path in this file into a silent
   no-op"). `isUnavailable` reported correctly regardless, via `setupFailure`, so no user-visible
   behaviour changed. Corrected inside the seam; it is in the failure branch only.

2. **Pre-existing B2 in `WatchStateTests`.** `boundariesFollowTheSharedThresholds` and
   `everyPositionClassifiesExactlyOnce` compute their expected values from
   `PlaybackProgress.startedThreshold` / `watchedThreshold` — production symbols on the
   expected side, which TEST-DOCTRINE B2 bans. They would survive a mutation that changes both
   a threshold and the comparison consistently. Out of scope for R4 (the census did not list
   them as survivors) and flagged for R6 rather than touched here. The new `IsFinishedTests`
   deliberately uses literals throughout so the same blind spot is not reproduced.
