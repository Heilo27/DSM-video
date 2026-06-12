# DSVideo Full-Stack Review — 2026-06-12

Fresh-eyes review of iOS, iPadOS, tvOS, and server. Four parallel review agents
(iOS/iPadOS, tvOS, server, creative/feature-gap), findings spot-checked against
source by the lead. Tickets TASK-719 … TASK-729 cover the priority items.

**Confidence key:** ✅ verified in source by lead · ⚠️ agent finding, plausible but
verify before fixing.

---

## Fixed this session

**tvOS autoplay next-episode failure** (the reported bug) — root cause: the
countdown fired `onPlayNextEpisode()` while the player `fullScreenCover` was
still presented. The advance swaps the presenting view's identity (`.id`)
mid-dismissal, and tvOS silently drops the next episode's cover presentation.
Fix: the player now sets `advanceToNextAfterDismiss`; the advance runs in the
cover's `onDismiss`. Commit `206bd38`. tvOS + iOS builds verified. tvOS review
agent traced the new chain end-to-end and confirmed it sound.

---

## P0/P1 Bugs

### Client
- ✅ **Search filter dead on iOS** — `ItemsGridView.swift:124` iOS branch renders
  `sortedItems`; the search-filtered `displayedItems` is tvOS-only. (TASK-720)
- ✅ **Downloads back up to iCloud** — no `isExcludedFromBackupKey` anywhere;
  multi-GB videos hit user quota; App Review risk. (TASK-721)
- ✅ **Progress loss on playback failure** — `start()` resets
  `lastSyncedPosition/lastKnownDuration` (ItemDetailView.swift:1281), so the
  `onDismiss` final-flush guard bails after `onPlaybackFailed` recovery; plus
  background sync is fire-and-forget on suspend. (TASK-719)
- ⚠️ **Subtitle-offset restart teleports backward** — restart resumes from the
  10s heartbeat position, not `player.currentTime()`. (TASK-722)
- ⚠️ **Offline playback bypasses server progress sync** (DownloadsView launches
  GestureVideoPlayer directly).
- ⚠️ **Stale posters after metadata refresh** — `AuthenticatedImage` only reloads
  on nil→URL transitions, ignores `?v=` changes.
- ⚠️ **"Just Added" rail TVShow stub ID** may 404 against `/tvshows/{id}/seasons`.

### tvOS-specific
- ⚠️ **Up Next overlay never claims focus** — Select during countdown hits the
  player underneath, not the overlay buttons. (TASK-723)
- ⚠️ **Still Watching counter not reset on season cross** — prompt fires one
  episode early across seasons. (TASK-723)
- ⚠️ `.id(showPlayer)` on tvBody forces a full API re-fetch on every player
  dismiss — remove and rely on `loadProgress()`.
- ⚠️ Top Shelf serves the same image URL for 1x and 2x — soft artwork.
- ⚠️ D-pad seek hardcoded 10s, inconsistent with 15/30s skip buttons.

### Server (Go)
- ✅ **ffmpeg has no process group** — orphaned transcodes survive handler death
  up to the 5-min cleanup tick; `StopSession` removes dirs while ffmpeg may hold
  them. (TASK-725)
- ⚠️ **DS Video UA fallback may create sessions without DSM validation**
  (webapi.go ~278) — if confirmed, do not port-forward until fixed. (TASK-726)
- ⚠️ HLS segment path check uses `filepath.Clean` without `EvalSymlinks`;
  subtitle scan follows symlinks. (TASK-726)
- ✅ **Playback streams are deliberately unauthenticated** — session ID is the
  bearer token, 128-bit crypto-random (`randID`, main.go:5301) so guessing is a
  non-issue; the real exposure is `sess_` IDs in HTTP logs + unredacted
  `Authorization` header. Tighten log redaction. (TASK-726)
- ⚠️ idMappings read-then-write race; progress seq cursor can lag its write;
  rate limiter keys on `RemoteAddr` behind the RealIP middleware.

---

## Top feature gaps (ranked, cross-platform)

1. **Quality/format badges (4K/HDR/Atmos) + file-info section** — the defining
   serious-NAS-player signal; probe data already exists server-side. (TASK-728)
2. **Hardware transcode (VAAPI/QSV)** — 5-10x CPU reduction on NAS. (TASK-729)
3. **Haptics layer + accent-token fix on Play CTA** — cheapest perceived-quality
   win; app currently has zero haptics; Play button uses raw `Color.red` not
   `dsAccent`. (TASK-727)
4. **MPNowPlayingInfoCenter / MPRemoteCommandCenter + isIdleTimerDisabled**
   (tvOS screensaver can interrupt movies today). (TASK-724)
5. **Trick-play scrub thumbnails** — server sprite sheets + client preview.
6. **Subtitle styling** (size/color/background via `textStyleRules`) and MKV
   embedded-subtitle extraction server-side.
7. Small wins: playback-speed + audio-track persistence, chapter list sheet,
   PiP resume at PiP position, sync on `scenePhase → .active`, Wi-Fi-only
   download toggle, hero `matchedGeometryEffect` transition, hover effects +
   `.searchable` + split-column width on iPad.
8. Larger bets: Siri/Spotlight + widgets, richer home rails (genres,
   collections, "on this day"), multi-user/parental controls, intro/credits
   detection, richer Top Shelf (Continue Watching section).

## Creative direction (summary)

Identity verdict: disciplined token system, real logomark, coherent dark
material language — but motion is generic (no springs, no hero transitions),
zero haptics, and posters always burn title text onto artwork. The
differentiator to lean into: **"your NAS, proudly"** — provenance/file detail,
library-stats moments, personal-memory rails ("most rewatched", "never
finished"), ambient color-bleed cinema mode, household presence. Full text in
the session transcript; the four agent reports are the source of record.
