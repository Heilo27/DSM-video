# R2 — Mutation Census (DSVideo, 2026-09-12) — THE DIAGNOSIS

Baseline before every mutation: **105/105 unit tests PASS.**
Method: one mutation at a time, full unit suite run, revert. 13 mutations across T-A and T-B.

## HEADLINE

> **9 of 13 mutations SURVIVED. On the T-A destructive surface: 7 of 8 — 87% unprotected.
> The suite was green on every single one.**

| # | Tier | Symbol | Mutation | Result |
|---|---|---|---|---|
| M2-priv | T-B | `AppState.isPrivateLANAddress` | invert the private-range verdict | **KILLED** |
| M4-err | T-B | `APIError.userMessage(401/403)` | swap auth message for wrong cause | **KILLED** |
| M2-reach | T-B | `APIError.serverReached` | invert server-reached | **KILLED** |
| M1-redact | T-A | `DiagnosticLog.redact` | return the secret verbatim | **KILLED** |
| M3-finish | T-B | `PlaybackProgress.isFinished` | always return false | SURVIVED |
| M2-perm | T-B | `APIError.isPermanentRejection` | no status is permanent | SURVIVED |
| M5-upsert | T-A | `LocalStore.upsertSingleProgress` | skip the progress write | SURVIVED |
| M6-delitems | T-A | `LocalStore.deleteItems` | delete nothing | SURVIVED |
| M1-clearall | T-A | `LocalStore.clearAll` | clearAll does nothing | SURVIVED |
| M1-delete-dl | T-A | `DownloadManager.deleteDownload` | deleteDownload does nothing | SURVIVED |
| M5-resume | T-A | `DownloadManager.updateResumePosition` | skip offline resume write | SURVIVED |
| M2-httpfail | T-A | `DownloadManager` HTTP status gate | invert the 1.3.6 P0 gate | SURVIVED |
| M2-ready | T-A | `LocalStore.isUnavailable` | store always claims healthy | SURVIVED |

## What the four KILLS tell us

The suite is genuinely real where it points. `isPrivateLANAddress`, the error-message mapping,
`serverReached`, and `redact` all have honest tests that die when the behavior breaks. Notably
`M4-err` and `M2-reach` are killed by tests I added yesterday for TASK-893/895 — those were written
to doctrine and they work.

**This is not a suite of fake tests.** B1 (tautology) and B2 (restating the impl) came back at ZERO
in the R0 census, which is unusual and good. The problem is the coverage AXIS: 105 tests aimed
entirely at URL normalization, JSON decoding, error mapping, retry ladders and key derivation — all
T-B/T-C pure functions — and none at the destructive or persistence surface.

## What the nine SURVIVORS mean, concretely

Each of these is a behavior that can break with the suite staying green:

- **M5-upsert / M5-resume** — a watch position can silently stop being written, on BOTH the online
  (SQLite) and offline (downloads.json) paths. This is the exact shape of the 1.3.6 P0 (TASK-889).
  The fix shipped; nothing guards the fix.
- **M2-httpfail** — the download status gate added yesterday for TASK-887 can be inverted and no test
  notices. The P0 we just fixed is unprotected against regression.
- **M2-ready** — `LocalStore.isUnavailable` can always claim healthy. That is TASK-889's entire
  detection mechanism, unguarded.
- **M1-clearall / M6-delitems / M1-delete-dl** — three destructive operations can become no-ops (or,
  with a different mutation, delete the wrong thing) with a green suite. `clearAll` is what runs on
  sign-out.
- **M3-finish** — `PlaybackProgress.isFinished` drives Continue Watching membership and resume-vs-
  restart. It can always-return-false and the suite stays green. NOTE: `WatchStateTests` exists and
  passes, so it tests something adjacent but not this function's verdict.
- **M2-perm** — `isPermanentRejection` gates whether the progress outbox drops a row or retries
  forever. Inverting it means a deleted movie's queued progress blocks the outbox permanently — the
  exact bug the code comments say was already fixed once.

## Honest notes on harness artifacts (recorded, not hidden)

- `M1-clearall` first reported KILLED in 2s. That was a COMPILE failure, not a test kill — my
  injected bare `return` merged with the following line. Re-run with `if true { return }`: SURVIVED.
  A 2-second "kill" is always suspect; every kill in the table above ran ≥35s.
- `M2-priv` first reported TIMEOUT at 300s (simulator acquisition hang, not the mutation). Re-run
  clean: KILLED in 35s.
- Both were verified individually rather than left in the table as-is.
