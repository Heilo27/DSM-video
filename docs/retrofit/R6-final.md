# R6 — Final Verification (DSVideo, 2026-09-12)

## Before / after

| | Before | After |
|---|---|---|
| Unit tests | 105 | **148** |
| Mutations run | 13 | 13 |
| **KILLED** | 4 | **13** |
| **SURVIVED** | **9** | **0** |
| T-A surface | 7 of 8 unprotected (87%) | **0 of 8 unprotected** |

Baseline green both times. Every post-retrofit kill took 28-43s against a suite that needs ~24s
clean — consistent with real test execution, which is how a genuine kill is distinguished from a
build failure (see R6-harness-incident.md).

## Full mutation table — final run

| # | Tier | Symbol | Mutation | Before | After |
|---|---|---|---|---|---|
| M5-upsert | T-A | `LocalStore.upsertSingleProgress` | skip the write | SURVIVED | **KILLED** (35s) |
| M6-delitems | T-A | `LocalStore.deleteItems` | delete nothing | SURVIVED | **KILLED** (38s) |
| M1-clearall | T-A | `LocalStore.clearAll` | no-op | SURVIVED | **KILLED** (43s) |
| M1-delete-dl | T-A | `DownloadManager.deleteDownload` | no-op | SURVIVED | **KILLED** (37s) |
| M5-resume | T-A | `DownloadManager.updateResumePosition` | skip offline write | SURVIVED | **KILLED** (39s) |
| M2-httpfail | T-A | `DownloadManager.shouldAcceptResponse` | invert the 1.3.6 P0 gate | SURVIVED | **KILLED** (39s) |
| M2-ready | T-A | `LocalStore.isUnavailable` | always healthy | SURVIVED | **KILLED** (28s) |
| M3-finish | T-B | `PlaybackProgress.isFinished` | always false | SURVIVED | **KILLED** (30s) |
| M2-perm | T-B | `APIError.isPermanentRejection` | nothing permanent | SURVIVED | **KILLED** (29s) |
| M1-redact | T-A | `DiagnosticLog.redact` | leak the secret | KILLED | **KILLED** (29s) |
| M2-priv | T-B | `AppState.isPrivateLANAddress` | invert verdict | KILLED | **KILLED** (29s) |
| M4-err | T-B | `APIError.userMessage` | wrong auth cause | KILLED | **KILLED** (29s) |
| M2-reach | T-B | `APIError.serverReached` | invert | KILLED | **KILLED** (29s) |

Plus two mutations added during R4 that the brief did not ask for, both KILLED: deleting the wrong row
BY POSITION rather than by id, on the store and on downloads. A no-op mutation alone does not prove a
destructive test asserts on identity; these do.

## Exit criteria

- [x] Every T-A and T-B symbol: zero mutation survivors
- [x] Zero B1–B7 patterns on the new tests (literals on every expected side)
- [x] Every product defect found is ticketed (TASK-899…905)
- [x] `docs/frd/` now contains a real spec — FRD-000 (Ryan's mission, authoritative) and
      FRD-001 (blind reconstruction, 142 requirements tagged STATED/INFERRED)
- [x] Before/after census recorded
- [x] **Mutation gate committed** — `scripts/mutation-gate.py`, `fastlane mutation_gate`,
      `fastlane preflight`. Exit 0 only when every mutation is KILLED; verified on both paths.

## What is NOT done, stated plainly

1. **The gate is committed but not wired to an automatic trigger.** `fastlane mutation_gate` and
   `fastlane preflight` exist and work, but nothing runs them unattended — there is no CI service on
   this project. It must be invoked before a release. That is a real gap: a gate nobody runs is a
   report.
2. **Two B5/conditional-assertion violations remain** in the pre-existing suite:
   `DS_Video_cloneTests.swift:696` and `:791` wrap `#expect` inside `if let first = …`, so the
   assertions are conditionally executed. A preceding `!isEmpty` saves them today. Disposition was
   REPAIR; not yet done.
3. **Pre-existing B2 in `WatchStateTests`** — `boundariesFollowTheSharedThresholds` and
   `everyPositionClassifiesExactlyOnce` compute expected values from
   `PlaybackProgress.startedThreshold`/`watchedThreshold`, i.e. production symbols on the expected
   side. They would survive a mutation that changed a threshold and its comparison together. Found by
   the R4 agent, deliberately not touched (out of scope), flagged here.
4. **R3 triage was abbreviated.** The formal per-test disposition table (KEEP/REPAIR/REPLACE/DELETE)
   was not produced for all 105 pre-existing tests. The census made it largely moot — the existing
   tests were real where they pointed, and the defect was coverage axis rather than test quality — but
   the full table is absent and items 2 and 3 above are what it would have surfaced.
5. **Adversarial sweep gaps:** DST/midnight date grouping, non-Gregorian calendars and RTL were not
   attempted. Recorded as unattempted, not clean.
6. **UI-layer mutations were not run.** The census covered model/networking/persistence. The XCUITest
   suite is not mutation-verified.

## Product defects the retrofit found

| Ticket | Sev | What |
|---|---|---|
| TASK-899 | P0 | Corrupt `downloads.json` → `[]` → next write persists it. Library destroyed. |
| TASK-900 | P0 | Show merge half-applied: merged counts, folder-scoped id and lastWatched. **FIXED** |
| TASK-901 | P0 | Unescaped LIKE wildcards; searching `%` returns everything. **FIXED** |
| TASK-902 | P0 | Corrupt `dsreel.db` permanently unrecoverable; the retry reopens the same file. |
| TASK-903 | P1 | Deleting a download while it plays pulls the file from under AVPlayer. |
| TASK-904 | P1 | `handleShowDetail` per-episode query inside an open cursor — known deadlock shape. |
| TASK-905 | P2 | `/shows` and `/tv/shows` return divergent contracts. |

Two P0s fixed and committed (99fdced). Three P0s and two P1s remain open.

## One discrepancy worth keeping

`sqlite3_open` leaves a **non-nil handle on failure**, so the `guard let db` at the head of every
LocalStore write path did NOT short-circuit on a dead store — directly contrary to LocalStore's own
comments, and contrary to the mechanism described in TASK-889's ticket. No behavior was wrong, because
`isUnavailable` reports via `setupFailure` rather than via `db == nil`. But the comments described a
safety mechanism that was not there, and the R4 agent found it only by building a store that genuinely
fails to open. That is the kind of thing only a real test finds.


---

## Addendum — running the gate in practice (observed 2026-09-12)

The gate is correct but the **simulator subsystem degrades over a long sequential run**. A full
13-mutation pass (~7 minutes of repeated `xcodebuild test`) reliably reaches a state with:

- zero booted simulators
- ~120 accumulated `CoreSimulator` processes
- `xcodebuild` sitting at ~0.1% CPU, never returning

Mutations then report TIMEOUT. This is NOT a test result: `M2-priv` and `M2-reach` both timed out in
the long run and both KILL cleanly in ~29s when run individually. Every verdict in the R6 table was
obtained in small batches for exactly this reason.

**Mitigation committed** (d104179): a TIMEOUT now shuts down simulators, boots a fresh one, and retries
once before being believed, and the failure summary states that a repeated TIMEOUT is environmental
rather than a missing test.

**Recommended usage:** run it in batches of 4-6 ids rather than all 13 at once, and if timeouts appear,
reset the subsystem before continuing:

```bash
pkill -f xcodebuild
xcrun simctl shutdown all
killall -9 com.apple.CoreSimulator.CoreSimulatorService
xcrun simctl boot <udid>
```

A single full-pass invocation is still the right interface for `fastlane preflight`; it just needs a
healthy machine and may need one resume. This is a property of the host, not of the suite — worth
knowing before reading a TIMEOUT as a coverage gap.

### Root cause found (same session)

The degradation was not mysterious and not the gate's fault. The host was saturated:

- **load average 18.3 / 67.4 / 58.4**
- **248 accumulated `CoreSimulator` processes**
- **disk 95% full**

A large part of that was self-inflicted: this session had accumulated ~7.7 GB of derived-data
directories across 17 separate `-derivedDataPath` targets, and every killed `xcodebuild` leaked
simulator processes.

After `killall -9 com.apple.CoreSimulator.CoreSimulatorService` (248 → 12 processes) and removing the
stale derived-data trees (7.7 GB → 1.4 GB), load fell to 3.9 / 4.9 and both outstanding mutations
returned real verdicts:

| Mutation | Result |
|---|---|
| M2-priv | **KILLED** — first attempt timed out, the committed retry booted a fresh simulator and got the verdict |
| M2-reach | **KILLED** (33s) |

**Final: 13 of 13 mutations KILLED, zero survivors.** The retry added in d104179 is what turned
`M2-priv` from a false gate failure into a real kill, which is the case it was written for.

**Operational lesson:** reuse ONE derived-data path across runs rather than a fresh one per
invocation, and kill `CoreSimulatorService` between long batches. Disk pressure and leaked simulator
processes present as mutation timeouts, which look like test gaps and are not.
