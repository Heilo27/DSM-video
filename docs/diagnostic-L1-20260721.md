# Level 1 Diagnostic — DSVideo — 2026-07-21

## Verdict: DIAGNOSTIC CLEAR (cycle 1)

Full-ship Level 1 sweep across two targets. Zero P0 found. All P1/P2/P3
findings fixed, committed, pushed, and adversarially re-verified in one cycle.
No regressions. No new tickets from re-review.

## Targets
1. **Server + browser** — Go backend (`backend/cmd/dsvideo-backend/`), embedded
   web player (`web/index.html`), Synology SPK (`spk/DSVideoServer/`)
2. **iOS/tvOS apps** — SwiftUI (`DS Video clone/`), targets: DSM Video (iOS),
   DSM Video tvOS, DSM Video Top Shelf

## Phase results
- **Phase 1 (gate):** Go build/vet/test GREEN; iOS + tvOS ** BUILD SUCCEEDED **. No P0 build failures.
- **Phase 2 (4 Opus reviewers):** server code+security, server stability, app code+security, app stability+layout.
- **Phase 3 triage:** P0=0, P1=3, P2≈15, P3≈14. 35 tickets (TASK-791→825).
- **Phase 5A (3 fix agents):** 32 tickets fixed P0→P3. 1 deferred (TASK-817 per-address refactor — guard hardened, non-urgent).
- **Phase 5A.5:** manifest-scoped commit 0449502, pushed to feat/sprint-convert-script.
- **Phase 5B (2 re-reviewers, adversarial):** all fixes VERIFIED, 0 regressions, 0 new tickets, builds green.

## Severity summary
| Sev | Found | Fixed | Deferred |
|-----|-------|-------|----------|
| P0  | 0     | —     | —        |
| P1  | 3     | 3     | 0        |
| P2  | ~15   | ~15   | 0        |
| P3  | ~14   | ~13   | 1 (TASK-817 refactor) |

## Key outcomes
- **No blockers on either target.** Front doors solid: JWT hardened, media path
  traversal closed, SQL parameterized, secrets handled, token in Keychain, ATS scoped.
- **P1s fixed:** long-title stream reaper eviction (794), sync-DoS via unchecked
  itemID insert (797), tvOS empty-episodes focus dead-end (792).
- **Security hardening:** admin model gating global settings/rescans (791),
  within-root checks on all ffmpeg paths (800), poster oracle closed (804),
  unified JWT revocation (806), body-size DoS cap (810), logout cross-user
  residue purge (807).
- **TASK-812 verified safe:** stream URL carries opaque session id, not the JWT.
- **Concurrent main.go edits** (2 agents) verified non-conflicting.

## Builds (final, re-run in Phase 5B)
- Go: build/vet/test GREEN
- iOS (DSM Video): ** BUILD SUCCEEDED **
- tvOS (DS Video clone tvOS): ** BUILD SUCCEEDED **

## Deferred (tracked, non-blocking)
- TASK-817 — per-address scheme/port model. The uniform LAN guard makes it non-urgent; left open for a future sprint.

## Commit
0449502 — fix(dsvideo): Level 1 diagnostic cycle 1 — 32 tickets closed
