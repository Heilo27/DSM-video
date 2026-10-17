# Level 2 Diagnostic — DSVideo — 2026-10-17

**Tracking:** TASK-919 · **Focus (Ryan):** the new profile system (FRD-002, ADR-001, ProfilesAPI.md) · **Fix commit:** a4f4fa1 (pushed to `main`) · **Not deployed:** NAS SPK and App Store builds untouched.

## Verdict

**Conditional ship.** All P0/P1 findings fixed in one pass and gated green. Profile enforcement held under every attack the security review tried: spoofed or missing profile header, another account's profile, PIN brute force, WebAPI, streams, subtitles, metadata fix. The remaining work is P2/P3 and is ticketed.

## Gate (combined tree, after all fixes)

| Check | Result |
|---|---|
| `go vet ./...` | clean |
| `go test -count=1 ./...` | 5/5 packages ok |
| iOS `DSM VideoTests` (sim 0A0D22D8) | 304 passed, 0 failed, 0 skipped (baseline 249) |
| tvOS app build | succeeded |
| `fastlane check_focus` | passed |
| UI tests | not run (need a live server) |

## Phases

| Phase | Agent | Outcome |
|---|---|---|
| 2 Spec freshness | Geordi | intent reconciled; FR-088 drift (TASK-920) |
| 3 Oracle contract (blind) | Spock | 391 assertions: 236 profile, 155 core |
| 4 Integration | Worf | 103/236 profile assertions mapped, 5 destructive uncovered, 0 gamed; core not checked (context ceiling) |
| 5 Code / Arch / Security / Stability | Scotty / Geordi / Odo / Torres | findings below |
| 6 Spec compliance | Worf | FRD-002: 38 pass, 4 partial, 3 unproven, 2 fail (both already found); FRD-000/001 not swept |
| 8 Fix pass | Scotty ×4 shifts, Odo, Worf, Torres, O'Brien | 15 tickets closed |

## Fixed (a4f4fa1)

**P0**
- TASK-933: a scan deleted titles under an unreadable subfolder or an unmounted volume, then the purge erased every profile's progress for them. Now the scan keeps titles when in doubt, one failed library doesn't stop the others, and progress gets a 30-day grace period.
- TASK-938: five destructive oracle assertions had no test (migration count verifier, profile delete vs downloads, delete confirm Cancel, watchlist delete above ceiling, rating change via sync). All now tested and proven red under mutation.

**P1**
- TASK-927: the Downloads tab and offline play ignored the profile ceiling. Fixed, and offline resume is per profile.
- TASK-934: re-match didn't bump change_seq, and Just Added stayed stale for up to 12h after a re-rating. Fixed, with singleflight. Ryan's New Arrivals rule is recorded in FR-250.
- TASK-935: the ageLevel backfill and the deleted-profile local purge had no callers, so upgraded devices showed kids empty rails.
- TASK-937: backup reaping kept no minimum. It now keeps the newest 3.
- TASK-921/922 (Rule 9): the kids threshold and the top level lived in both Go and Swift. The server now sends `kids`, `unrestrictedLevel` and `unratedLevel`.
- TASK-929: request logs carried DSM passwords, session ids, OTP and the trusted-device token. Now redacted.
- TASK-931: DSM users differing only by punctuation shared one account and could reset the owner PIN. Now one DSM user maps to one account (additive `account_claims`, no rows moved), and stale shared credentials are revoked.

**P2 fixed in the same pass**
- TASK-923/928: Top Shelf leaked the last profile's watch history.
- TASK-930: jwt v5.2.1 → v5.2.3.
- TASK-932 SEC-6: global settings now need an unrestricted profile.
- TASK-936: orphaned progress saves were attributed to the owner. With no profile chosen, reads now show only the most restricted profile's titles.
- Change numbers are now published after commit on every item and progress write.

## Open (ticketed)

| Ticket | Pri | What |
|---|---|---|
| TASK-939 | P2 | FR-244: a ladder change never reaches devices (no ladder version recorded) |
| TASK-940 | P2 | Go 1.26.1 has 24 reachable stdlib vulns (fixed in 1.26.9); chi v5.1.0 advisories |
| TASK-941 | P2 | re-key moves progress without a seq bump; a failed commit can hold the write lock; flaky `TestCompletedSessionsAreReclaimed` (~2/8) |
| TASK-932 | P3 | SEC-7 PIN lockout is in memory only; SEC-8 FR-250 images wording |
| TASK-924–926 | P3 | duplication cleanups |
| TASK-920 | — | FR-088 spec drift |
| — | P2 | ItemDetail model ignores the server's `ageLevel`, so new downloads take their level from the local catalog |

## Decisions recorded in the spec

- **FR-264 Top Shelf (Friday, Ryan may revise):** on any account with a restricted profile, Top Shelf shows Just Added at the most restricted level only, with no watch history.
- **AC-002-64 vs FR-275:** an offered collection with no visible titles returns 200 with an empty page; 404 only for undefined or not-offered collections. The AC was amended to match FR-275 and the code.
- **FRD-002 §10:** added `invalid_avatar` and `dsm_unavailable`.
- **New FR-224:** one DSM user, one account.
- **New FRD-001 FR-143** (scan keeps on doubt; destructive-class narrowing) and **FR-144** (log redaction).
- **§11 accepted residual:** a device upgraded from a pre-profiles build and launched offline before ever loading the profile list has an unfiltered offline catalog until it first reaches the server.

## Flagged for Ryan (destructive class, all narrowing)

- Progress for removed titles is now kept 30 days before it's erased.
- The newest 3 conversion originals are kept past retention (up to 3 extra video files on the NAS).
- A profile deleted on one device has its local copy purged on the others (the server copy was already gone).

## Not covered this run

- FRD-000/001 spec sweep.
- Core oracle assertions (155).
- 127 profile assertions not mapped.
- UI tests.
- Design-system checks 17–20.
- Stability checks 7, 8, 11, 12, 14.
- A timed migration on the real 11MB NAS database.
