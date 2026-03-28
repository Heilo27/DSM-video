# MaxReview Report — DSVideo
**Date:** 2026-03-28
**Cycle:** 1 of 1
**Verdict:** ✅ PASS

---

## Summary

25 issues found across code, architecture, layout/accessibility, and spec compliance reviews. All 23 actionable tickets resolved in a single fix cycle. Build passed on all platforms (iOS, macOS, tvOS).

| Severity | Found | Fixed |
|----------|-------|-------|
| P0 (Critical blocker) | 0 | — |
| P1 (High — must fix) | 6 | 6 |
| P2 (Medium) | 11 | 11 |
| P3 (Low) | 6 | 6 |
| **Total** | **23** | **23** |

*(2 issues from Phase 3 were duplicates of P1s already logged — not double-counted.)*

---

## Issues Fixed

### P1 — Critical / High

| Ticket | File | Issue |
|--------|------|-------|
| TASK-173 | ItemDetailView.swift | `.task(id: itemID)` missing — Next Episode never reloaded detail |
| TASK-174 | GestureVideoPlayer.swift | AVAudioSession never deactivated on cleanup — suppressed system audio |
| TASK-175 | GestureVideoPlayer.swift | playerItem strongly captured in Combine sinks — retain cycle |
| TASK-176 | GestureVideoPlayer.swift | Final playback position not synced on dismiss — progress lost |
| TASK-177 | ItemDetailView.swift | Next Episode a11y label missing episode number |
| TASK-178 | GestureVideoPlayer.swift | Double-tap center zone was dead — no play/pause action |
| TASK-179 | GestureVideoPlayer.swift | HUD auto-hid while paused after skip tap |
| TASK-180 | GestureVideoPlayer.swift | Skip button tap targets ~32pt — below 44pt HIG minimum |
| TASK-181 | GestureVideoPlayer.swift | `allowsHitTesting` toggled sync during 250ms fade animation |
| TASK-182 | LibrariesView.swift | `onAppear` guard inverted — network call fired on every nav pop |
| TASK-183 | LibrariesView.swift | Pagination loop had no empty-page break or hard cap |
| TASK-184 | LibrariesView.swift | Home rail dedup used title-only key — collapsed different items |
| TASK-185 | TVShowDetailView.swift | Episode progress a11y showed "Episode 0" for unnumbered eps |
| TASK-186 | ItemDetailView.swift | `startDownload()` silent fail when no stream URL — no user feedback |

### P2 — Medium

| Ticket | File | Issue |
|--------|------|-------|
| TASK-187 | GestureVideoPlayer.swift | `.fixedSize()` on time label squeezes slider on iPhone SE |
| TASK-188 | LibrariesView.swift | ISO8601 strings sorted as raw strings — wrong order on non-standard formats |
| TASK-189 | GestureVideoPlayer.swift | `scheduleHide*` tasks missing `@MainActor` annotation |
| TASK-190 | TVShowDetailView.swift | Year/season separator dot rendered when year was nil |
| TASK-191 | hls.go | Redundant `-hls_flags append_list` conflicted with `event` playlist type |

### P3 — Low

| Ticket | File | Issue |
|--------|------|-------|
| TASK-192 | hls.go | `NicePriority` struct comment said default 19, value was 10 |
| TASK-193 | TVShowDetailView.swift | Redundant `.accessibilityHidden(false)` calls (no-op) |
| TASK-194 | ItemDetailView.swift | Cast `ForEach` used offset as identity — incorrect on metadata update |
| TASK-195 | TVShowDetailView.swift | Seasons `ForEach` used `seasonNumber` as id — unstable on duplicate season numbers |

---

## Files Changed

- `DS Video clone/DSM Video/DSM Video/Views/GestureVideoPlayer.swift`
- `DS Video clone/DSM Video/DSM Video/Views/ItemDetailView.swift`
- `DS Video clone/DSM Video/DSM Video/Views/TVShowDetailView.swift`
- `DS Video clone/DSM Video/DSM Video/Views/LibrariesView.swift`
- `backend/internal/transcode/hls.go`
- `backend/cmd/dsvideo-backend/web/index.html`

---

## Build Status

```
BUILD SUCCEEDED (iOS Simulator — iPhone 17 Pro)
BUILD SUCCEEDED (macOS)
BUILD SUCCEEDED (tvOS Simulator — Apple TV)
```

---

## Notes

- Web UI buffering root cause: `-hls_playlist_type vod` caused ffmpeg to hold the playlist until full transcode completion. Switched to `event` for incremental delivery. hls.js buffer config also hardened.
- Home rail TV show duplicates: API returns individual episodes; `deduplicated()` helper added with composite `title+type` key.
- Next Episode navigation: required both `.task(id: itemID)` on ItemDetailView and `detail = nil` reset to clear stale content on prop change.
