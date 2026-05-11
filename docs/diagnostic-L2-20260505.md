# Level 2 Diagnostic — DSVideo — 2026-05-05

## Summary

Tracking task: TASK-559
Dirty working tree at time of run (all uncommitted session work).

### Issue Counts by Agent
Integration/Completeness: 5 | Code: 20 | Architecture: 18 | Security: 8 | Stability: 22 | Spec: 17
**Total: 90 issues**

### By Severity
- **P0**: 0
- **P1**: 9 — TASK-567, TASK-569, TASK-571, TASK-574, TASK-581, TASK-595, TASK-597, TASK-600, TASK-619
- **P2**: 43
- **P3**: 38

---

## P1 Issues — Fix These First

| Ticket | Category | Issue |
|--------|----------|-------|
| TASK-567 | Architecture | JWT revocation list in-memory only — tokens re-accepted after NAS restart |
| TASK-569 | Stability | `exec()` silently swallows all SQLite errors including disk-full COMMIT failures — silent data loss |
| TASK-571 | Architecture | `showFolderId` computed at query time from path string — breaks if TVPath config changes |
| TASK-574 | Architecture | EpisodeDetailView episode array is season-scoped — cross-season next-episode impossible |
| TASK-581 | Stability | `homeIsBackgroundRefreshing` has no `defer` — stuck true after cancel, permanently kills heartbeat syncs |
| TASK-595 | Stability | `homeBackgroundFetchTask` overwritten without cancelling old task — concurrent delta syncs race on cursor |
| TASK-597 | Security | JWT revocation list in-memory — tokens valid after NAS restart (same root as TASK-567, security angle) |
| TASK-600 | Security | chi Logger logs full URLs including `_sid=<token>` — session tokens in server logs |
| TASK-619 | Stability | `sqlite3_step()` return value ignored in `upsertItems` — partial batch commit, items permanently skipped |

---

## Notable P2s

| Ticket | Category | Issue |
|--------|----------|-------|
| TASK-560 | Code | CW threshold mismatch: SQLite 2% vs in-memory 5% (different rails on cold vs warm start) |
| TASK-561 | Code | Double percent-encoding of item IDs — items with special chars get malformed URLs |
| TASK-562 | Code | Orphaned URLSession from two-phase DownloadManager init |
| TASK-568 | Code | "See All" on TV rails navigates to movie library |
| TASK-573 | Code | "Go to Show" dismiss() + goToShow() race — double-dismiss navigation corruption |
| TASK-575 | Code | Autoplay-next countdown runs while app backgrounded |
| TASK-593 | Code | episodes.isEmpty guard blocks reload after metadata fix |
| TASK-576 | Arch | DownloadManager.shared bypasses @Environment injection |
| TASK-583 | Arch | Server.mu guards playSessions + scan — scan write lock delays playback reads |
| TASK-586 | Stability | onGoToShow timing: both dismisses fire synchronously same runloop pass |
| TASK-594 | Arch | ALTER TABLE runs every launch generating silent SQLite error |
| TASK-603 | Security | logout() leaves username in UserDefaults |
| TASK-605 | Security | LoginView .privacySensitive() on SecureField only — server URL + username visible in app switcher |
| TASK-610 | Security | TVPairingView .privacySensitive() on code Text only — partial screen visible in app switcher |
| TASK-636 | Spec | Login CTA visually inverted — white bg + red text vs spec's red bg + white text |
| TASK-639 | Spec | Player transport missing Skip-to-Start and Skip-to-End buttons |
| TASK-645 | Spec | "Queued" download state unimplemented |
| TASK-646 | Spec | Swipe-to-delete absent from Downloads |
| TASK-647 | Spec | Trailer button absent from ItemDetail action row |

---

## Build / Test Status
- iOS build: PASS
- tvOS build: PASS
- Go build: PASS
- Swift unit tests: 20/20 PASS
- Go unit tests: None exist

---

## Verdict
**FIX PASS RECOMMENDED.** 9 P1s, 0 P0s. No crashes, no data loss in normal operation — but TASK-569 and TASK-619 (SQLite error swallowing) are latent data loss risks under disk pressure. TASK-581/TASK-595 (stuck sync state) are reproducible reliability issues. P1s should be addressed before TestFlight submission.

