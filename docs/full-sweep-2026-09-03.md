# Full Sweep — DSVideo (iOS + tvOS + Server) — 2026-09-03

**Scope:** Go server (16.8k L), Swift clients (22.1k L, iOS + tvOS shared), SPK packaging.
**Baseline:** `main` @ `94d9a11`, clean tree.
**Method:** 5 parallel deep-dive audits (interop, server stability, iOS UX, tvOS/focus, security),
every headline finding re-verified by hand against source.

---

## Baseline health

| Check | Result |
|---|---|
| `go build ./...` | clean |
| `go vet ./...` | clean |
| `go test ./...` | 58 tests pass |
| `go test -race ./...` | clean (but see coverage) |
| iOS build (`generic/platform=iOS`) | **SUCCEEDED**, 1 warning |
| tvOS build (`generic/platform=tvOS`) | **SUCCEEDED**, 0 warnings |
| iOS unit tests | 78 pass |
| TODO/FIXME/HACK | **0** |
| `try!` / `fatalError` | 1 (`as!`, safe cast) |
| Accessibility labels | 127 labels / 59 hidden / 41 hints |

**Go coverage is the weak spot:** `cmd/dsvideo-backend` at **1.5%** — the HTTP surface where
every interop and concurrency risk lives is effectively untested. The clean race run proves
little because the tests never exercise the concurrent paths.

---

## P0 — Fix before next ship

### 1. tvOS: "Skip Intro" is rendered and unreachable — 4th recurrence of the focus bug
`Views/GestureVideoPlayer.swift:889-905`

`grep -n skipIntro` returns **exactly one line** — the enum declaration at `:184`. The case was
added by the fix that was meant to close this bug class and never bound to the button. The
button also sits in the only control `VStack` with no `.focusSection()`.

**On an Apple TV:** the Skip Intro button appears during an episode intro and cannot be selected.

### 2. tvOS: player Close + "Show" buttons have no focus binding
`Views/GestureVideoPlayer.swift:574-591`, `:593-614`

Same HStack as the captions/speed buttons, which *are* bound (`:673`, `:709`). Partial
application — the signature failure mode. Neither is inside an `#if os(iOS)` guard, so both
compile into tvOS. `TVFocusField` has no `close`/`goToShow` case, and `handleTVSelectPress`
would fall through to `togglePlayPause()` anyway.

**On an Apple TV:** both visible, both unreachable. Menu is the only exit from the player; there
is no way to reach the parent show from playback.

### 3. Server: the 2-hour session reaper is dead code
`internal/transcode/cleanup.go:121,127` + `internal/transcode/hls.go:409-412`

```go
session, ok := m.generator.GetSession(sessionID)   // stamps LastAccess = now
...
if session.LastAccess.Before(threshold) {          // now < now-2h → ALWAYS false
```
`GetSession` mutates the field the caller is about to test. **Verified by hand.**

**Consequence:** abandoned ffmpeg processes and temp dirs are never reaped by this path. Any HLS
session orphaned in `g.sessions` holds a `g.active` slot forever — once all slots are held,
every playback returns `transcode_busy` permanently until restart.

### 4. iOS: one dropped connection pins the app offline until relaunch
`App/AppState.swift:746-748`, gated at `:1265`

`.networkConnectionLost` fires on a dropped TCP connection over a **still-satisfied** interface
and sets `isOffline = true`. `NWPathMonitor` only reassigns on a *path change* — which never
happens, because the path never changed. `homeLoad()` and `foregroundRefresh()` both hard
early-return while the flag is set. **Verified by hand.**

**Consequence:** "No internet connection." pinned over stale rails on a working network. The sole
escape is `runHeartbeat()`, which doesn't check the flag — so recovery depends entirely on that
30s timer still running. After any path that calls `stopHeartbeatTimer()`, there is no recovery.

### 5. iOS: paused download resume always 401s, and blames the user's network
`Networking/DownloadManager.swift:520` → `:335` → `:145`

Restore writes `token: nil`, and `_sid` is stripped from the persisted URL at `:543`. `startDownload`
gates the header on `!contains("_sid="), let token` — so **both auth paths are dead**. The comment
at `:542` ("startDownload re-attaches auth on resume") is factually wrong. **Verified by hand.**

**Consequence:** pause → force-quit → reopen → Resume → 401 → *"Download failed. Check your
connection and retry."* The connection is fine. Retrying fails identically, forever.

---

## P1 — High

### 6. iOS: the entire network retry ladder is dead code — a regression with a date
`Networking/APIClient.swift:444` vs `:522`

`request()` wraps every `URLError` into `APIError.connection(...)`, so
`catch let urlError as URLError` can **never** match.

Traced the lineage:
- `3f462ea` (2026-07-03) added the TASK-788 retry ladder
- `20d9d8a` (2026-08-15) added the error wrap, silently killing it
- `git merge-base --is-ancestor` confirms the order

This is the **same defect class as August's TASK-834** — an error-wrapping change killing a
`catch` clause. The fix for that bug caused this one. Search, item detail, genres, watchlist and
TV shows all fail hard on a LAN↔WAN switch instead of retrying.

### 7. Server: `DELETE /watchlist/{itemId}` is non-idempotent; the client visibly reverts
`main.go:6012-6021` (server) / `AppState.swift:1797-1806` (client)

POST is `INSERT OR IGNORE` (idempotent); DELETE 404s when `RowsAffected == 0`. The client's
optimistic-removal `catch` re-inserts the row. **Verified both sides by hand.**

**Consequence:** double-tap, retry-after-flake, or two devices → the item visibly reappears in the
watchlist. Aggravated: `not_found` maps to "That item is no longer in your library" — wrong cause.

### 8. Server: `session.Error` read without the mutex on the hottest path
`internal/transcode/hls.go:1024` vs `:390-391`

`GetSession` returns a `*HLSSession` after its deferred `Unlock` fires, so every field access by
the caller is unsynchronized. Every `GET master.m3u8` polls this at 100ms while the transcode
goroutine writes `Error`. A torn interface read (non-nil type word, stale nil data word) makes
`session.Error.Error()` a nil deref. Same defect at `:1065-1070` and `cleanup.go:238-240`.

### 9. Server: `incrementSeq` returns 0 on DB error → silently dropped writes
`main.go:1422-1431` **Verified by hand.**

`0` fails the upsert's `WHERE excluded.write_seq > progress.write_seq` guard, so a transient DB
error discards a progress write **while returning `{"ok":true}`**. Also makes codec updates
invisible to any client whose delta cursor is `> 0`.

### 10. iOS: duplicate background URLSession with the same identifier
`Networking/DownloadManager.swift:118-121` **Verified by hand.**

Two sessions share `"com.heiloprojects.dsreel.downloads"`; the first (delegate-less) is never
invalidated. Undefined behavior — the OS can deliver relaunch events to the delegate-less one, so
downloads completing while suspended may never report.

### 11. iOS: offline playback writes file + DB + network every 0.5s
`Views/MainView.swift:813-827`

`DownloadsView`'s player passes an unthrottled `onProgressUpdate`; the player ticks every 0.5s and
each tick does a full JSON read/decode/re-encode/write **plus** a SQLite write **plus** a network
POST. `PlayerSheet` throttles this correctly (10s); this path doesn't at all. Battery and disk
churn in the one mode that should be cheapest.

### 12. iOS: silent download failures (4 paths)
`DownloadManager.swift:338-344` (row vanishes, no error), `:750-756` (copy failure → pinned at
100% forever), `:801-815` (cancel with no resume data → download lost silently), `:789` (resume
data discarded on `networkConnectionLost` → 4GB partial restarts from byte 0).

### 13. Server: unguarded concurrent full-library scans
`main.go:5535`, `:6135`

The periodic and on-demand scans gate on `scanInProgress.CompareAndSwap`; `/admin/scan` and the
`tmdb_api_key` write path do not. Two concurrent walks of a large library on a 4-core/3.8GB NAS,
each with its own 10-goroutine TMDb pool, with the stale-purge racing the other scan's upserts.

### 14. tvOS: 3 of 5 transport buttons are bound but unreachable
`Views/GestureVideoPlayer.swift:1272-1285` **Verified by hand.**

The d-pad handler only ever sets `.captions`, `.speed`, `.playPause`, `.back15`. `.forward15`,
`.skipStart`, `.skipEnd` have bindings but **no code path assigns them**. Left/right from
`.back15` falls through to seeking, so focus is stuck there.

### 15. tvOS: Top Shelf images will never load
`TopShelfExtension/TopShelfProvider.swift:29-32` + `AppState.swift:1835-1843`

The tokenless URL is a deliberate, correct security call — but `setImageURL` is still called with
it, so tvOS fetches, gets 401, and renders a blank tile. Every item, always. Correct shape is to
omit image URLs entirely rather than set ones known to fail.

### 16. tvOS: focus destroyed when a season collapses mid-scroll
`Views/TVShowDetailView.swift:517-527`

`resolveResumePoint` runs async (up to 5 sequential fetches). When it lands, the auto-expanded
season collapses out from under the focused episode row. No `@FocusState` to restore to and no
`prefersDefaultFocus` to fall back on.

### 17. tvOS: metadata fixer sheet has no Cancel and no Search
`Views/TVShowDetailView.swift:1717-1729`

The `#if !os(tvOS)` guard removed the sheet's **only two actions**, not just styling. Reachable
from two places on tvOS.

### 18. tvOS: cast row can't be scrolled at all
`Views/ItemDetailView.swift:945-997`

A horizontal `ScrollView` containing only non-focusable views. tvOS scrolls via focus — anything
past the visible width is unreachable. The author applied exactly this reasoning to the summary
text at `:594-603` but never to the cast row beneath it. Also 64pt avatars with `.caption` labels
at 10 feet.

---

## P2 — Medium (selected)

**Server**
- Goroutine kills a possibly-recycled pgid after `cmd.Wait()` reaped it (`main.go:4413-4423`)
- Metadata worker pools never awaited — up to 30 goroutines outlive a scan; `scanInProgress`
  reports idle while they still write (`main.go:6835-6842`)
- `permaFailed` map never evicted, deep-copied into every admin status response (`worker.go:81`)
- N+1 progress query inside an open `sql.Rows` (`webapi.go:1459`); the REST twin does it right
- Unbounded `playSessions` map — 30-min reaper is the only bound

**Interop**
- `applied` field discarded client-side (`APIModels.swift:350-352`) — the server added it
  specifically so "Mark Unwatched" couldn't silently no-op; the client can't see it
- Watchlist catches are bare — a 401 is swallowed as "toggle failed", never routed through
  `isAuthFailure` (`AppState.swift:1802-1813`)
- `subtitles[].url` points at a route that serves master.m3u8 (`main.go:3800` → `:4587`). Latent —
  the player matches renditions by name and never dereferences it
- `filter=byFolder` returns a shape `ItemsResponse` can't decode. Unreachable today; a trap

**iOS**
- `homeError` never cleared on background-sync success → stale error banner over correct rails
- A 10-min outage reported as a sign-in problem (`AppState.swift:909-911`); network failure on
  pairing reported as "Invalid pairing code." (`:1028`)
- `inFlightTasks` leaks on cancellation → cells permanently grey, prefetcher skips the URL forever
- Logout leaks the previous user's rails back and re-writes the Top Shelf snapshot (`:1115-1139`)
- `HomeCache` methods are all dead (the `HomeCacheEntry` type survives for migration)

**tvOS**
- Season header, rail header, and search rows use `.buttonStyle(.plain)` → focus invisible
- Home header row: no `.focused()`, no `.focusSection()`
- `DiagnosticLogView` uses bare `.padding(.horizontal)` → content in the overscan band
- Pairing: wrong code / expired / server-down all show one misleading message; auto-submit on the
  6th digit wipes the field on failure
- 15s-step-only scrubbing, no preview; `tvDpadSeekSeconds` is dead code

**Security** (full detail in agent output)
- Anonymous `/images/{id}` is a library-enumeration oracle — **already documented in-source** with
  the tradeoff reasoned honestly (re-gating kills Top Shelf artwork). Real fix: signed, expiring,
  item-scoped URLs
- No rate limit on the WebAPI login proxy (`webapi.go:1041`) — `checkAuthRateLimit` exists and is
  wired to the REST login only. **DSM credential brute-force bypass.**
- 30-day JWT, no rotation; `/auth/refresh` issues a new token without revoking the old
- `.jwt_secret` written before `chmod 600` — use `(umask 077; ...)`

---

## Verified clean

Worth stating, because these were the primary hypotheses:

- **Path traversal** — exhaustively defended. `pathWithinMediaRoot` fails closed, uses
  separator-terminated prefixes, enforced at playback/trickplay/subtitles/rehydration. Segment
  handlers use triple defense. `/tmdb/image` host-pinning verified experimentally — no SSRF.
- **Command injection** — none. All 12 `exec.Command` sites use argv slices; no `sh -c` anywhere.
- **SQL injection** — none. Every concat interpolates a compile-time constant; values go in args.
- **Secrets** — zero hits for TMDB-key shape or JWTs outside a deliberate test fixture.
- **Client credentials** — Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; nothing
  sensitive in UserDefaults. `writeTopShelfSnapshot` *refuses* to persist a bearer token and
  fails closed, losing artwork instead.
- **Transport** — `NSAllowsLocalNetworking` only. Zero custom TLS handling; system validates
  every cert. The DSM HTTPS fallback bypasses chain validation **only** for localhost.
- **Data integrity** — WAL + busy_timeout + graceful SIGTERM checkpoint. Migrations are
  additive-only and idempotent. `cachedItemSeq` published only after commit. `moveFile` fsyncs
  the parent dir. Scan **fails closed** on an unreadable root so an unmounted volume can't purge
  the library.
- **iOS main-thread safety** — no violations. All four download-delegate callbacks correctly
  `nonisolated` with params snapshotted before the hop.
- **Image cache** — `NSCache`, 100MB/200 items, real byte-cost accounting.
- **nginx conf re-sync** — the known trap is now handled in `start-stop-status:78-86`.

---

## Two process observations

**1. The tvOS focus bug is now a 4th recurrence.** August's L1 found five instances of "iOS UI
API compiled for tvOS, laid out somewhere nobody looked" and wrote a rule for it. Today's two
CRITICALs are the same class, and one of them (`.skipIntro`) is an enum case added *by that fix*
and never wired. A grep-level guard would catch this mechanically:
every `Button` in a tvOS-compiled view needs either `.focused()` or a focus-providing button
style. Worth a CI check rather than another rule in a doc.

**2. The retry-ladder regression is a fix causing a bug.** TASK-834 (Aug) fixed dead auth handling
caused by error wrapping; the wrap it introduced killed the retry ladder added in July. Both are
"a `catch` clause that can never match." That pattern deserves a test, not a code review —
one test asserting the retry actually fires on `.timedOut` would have caught it.

---

## Deployment note

The NAS at `192.168.50.148:8080` is running **older code than this tree**: `GET /api/v1/version`
returns 401, but in HEAD that route is registered public (`main.go:931`). Local SPK is
`0.3.3-0001`. Any live testing right now is testing stale code.

---

## Suggested order

1. **#1, #2, #14** — tvOS focus (one file, `GestureVideoPlayer.swift`; fix the class, add the CI grep)
2. **#3** — dead reaper (one-line: read `LastAccess` without `GetSession`'s side effect)
3. **#4, #5** — the two iOS dead-ends users actually hit
4. **#6** — retry ladder (catch `APIError.connection` instead) + a regression test
5. **#7, #9** — one-line server fixes with real user-visible consequences
6. **#8** — the reachable panic
7. Security: rate-limit the WebAPI login proxy; plan signed image URLs

Nothing was modified. All findings are read-only observations, hand-verified where marked.
