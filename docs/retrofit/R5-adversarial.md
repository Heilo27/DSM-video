# R5 — Adversarial Sweep (DSVideo / DSReel)

Role: break the app. Isolation honoured — no `*Tests*.swift` and no other `.claude/retrofit/*`
file was read. Every finding below was derived from product code only.

**Result: 11 findings — 4 P0, 4 P1, 2 P2, 1 P3.** 9 CONFIRMED end-to-end, 2 SUSPECTED.
6 attack families were run and found **nothing** — they are recorded in §7 so a clean
result is distinguishable from an unattempted one.

---

## 1. INPUT

### F-01 — P0 — CONFIRMED — LIKE wildcards unescaped in the search endpoint
**Input:** search for `%`, or `_`, or `a%b`.
**Where:** `backend/cmd/dsvideo-backend/main.go:2662` (`pattern := "%" + q + "%"`), consumed at
`:2665` (`COUNT(*) … LIKE LOWER(?)`) and `:2679` (the row query).
**What happens:** the query is correctly *parameterised* (no SQL injection), but the user's text
is concatenated into a LIKE pattern with **no wildcard escaping and no `ESCAPE` clause**.
`%` matches every item in the library; `_` matches any single character; `Hawaii_Five` matches
`HawaiiXFive`. The `total` count and the returned rows are both wrong.
**User sees:** searching `%` returns the entire library as if it all matched the query. A title
containing a literal `_` or `%` cannot be searched for exactly.
**Why this is the top finding:** this codebase *knows* the rule and applies it in six other
places — `:2498-2500`, `:5612`, `:7818-7821`, `:7872`, `:8348-8350`, `:8422`. The one endpoint
that forgot is the only one taking **raw end-user text**. The escaping is also copy-pasted
inline at every site with **no shared helper**, which is exactly the drift pattern the repo's
own comments complain about elsewhere.
**Note:** `grep -n 'func escapeLike' backend/` returns nothing. There is no helper to call.

### F-02 — P1 — CONFIRMED — `handleShowDetail` omits the `ESCAPE` clause its siblings use
**Input:** open a show whose folder name contains `_` or `%` (e.g. `Hawaii_Five-0`).
**Where:** `main.go:3133` — `matchWhere := "path LIKE ?"` with `matchArgs := folderPrefix + "%"`,
and `folderPrefix` is built at `:3129` from the unescaped URL path param.
**What happens:** `/` and `..` are blocked at `:3122` (so no traversal — see §7), but the
wildcards are not escaped and there is no `ESCAPE '\'`. The *same show*, in the *same screen
load*, is matched by a different rule in `handleTVShowSeasons` (`:8348-8353`, escaped) and
`handleTVShowEpisodes` (`:8412-8422`, escaped).
**User sees:** show-level metadata (year, rating, overview, genres — all `MAX()` aggregates at
`:3137-3145`) pulled from a **wider set of rows than the episode list**, so the header can show
another show's rating/overview while the episode list below it is correct.
**Same defect, second location:** `webapi.go:1821`, `:1906`, `:1989` — all three use
`path LIKE ?` with no `ESCAPE`.

### F-03 — P2 — SUSPECTED — `parseInt` accepts trailing garbage
**Where:** `main.go:8016-8026` uses `fmt.Sscanf(s, "%d", &v)`.
**What happens:** `Sscanf` stops at the first non-digit and returns no error, so `limit=50abc`
parses as `50`, and `limit=5e9` parses as `5`. Clamped afterwards by `clampInt`, so the blast
radius is a silently-wrong page size rather than a crash.
**Labelled SUSPECTED:** I did not trace every `parseInt` caller to prove a user-visible wrong
result; `strconv.Atoi` would reject these.

---

## 2. SEQUENCE

### F-04 — P0 — CONFIRMED — sign-out deletes the video file out from under an active player
**Sequence:** start playing a downloaded item offline → while it is playing, sign out.
**Where:** `AppState.swift:728` → `DownloadManager.clearAll()` at
`DownloadManager.swift:260-287`. Line `:283` is `try? fm.removeItem(at: downloadsDirectory())`.
**What happens:** `clearAll()` cancels in-flight *download* tasks, but there is **no check for an
open player and no player teardown**. It deletes every poster, then the entire Downloads
directory, then the metadata file — while `AVPlayer` holds the file open.
**User sees:** playback dies mid-scene (or plays to the end of the buffered region and then
fails, since the inode survives until the last handle closes). The item is gone with no warning
that signing out discards downloads.
**Severity rationale:** unrecoverable local data loss triggered by an ordinary, non-destructive-
looking action. The same hazard applies to **delete-a-download-while-playing-it**
(`deleteDownload:237-258`, `try? fm.removeItem(atPath: item.videoPath)` at `:247`) — also no
player check.

### F-05 — P1 — CONFIRMED — `deleteDownload` rewrites every surviving row to a legacy absolute path
**Sequence:** have 3 downloads → delete one.
**Where:** `DownloadManager.swift:238` — `var items = getDownloadedItems()`, then `:256`
`saveDownloadedItems(items)`.
**What happens:** `getDownloadedItems()` **resolves** filename-only `videoPath` into container-
absolute paths (`:441-456`). Writing that array straight back persists the absolute form,
violating the filename-only storage invariant. This is the exact mistake the codebase warns
against twice in its own comments — `:494-496` ("Using getDownloadedItems() would resolve
absolute paths and write them back, undoing the fix") and `:726-727`. `deleteDownload` and
`clearAll` are the two methods that did not get the memo.
**User sees:** contained — after a container-path change the legacy branch at `:441` fails
`fileExists` and the filename-recovery fallback at `:447` rescues it. So: wrong data on disk,
recovered by luck. P1 not P0 because recovery exists.

### F-06 — P3 — CONFIRMED — `SeasonExpansionStore.clearAll()` / `clear()` are never called
**Where:** `App/SeasonExpansionStore.swift:93` and `:98`. `grep -rn 'SeasonExpansionStore.clear'`
over the whole source tree returns **zero** call sites.
**What happens:** the doc comment states the purpose explicitly — "Used when signing out, so the
next user does not inherit someone else's layout." `AppState.logout():699-730` clears the
Keychain, username, watchlist, home state, downloads and LocalStore, but **not** this.
**User sees:** on a shared device, user B opens a show and finds user A's expanded seasons.
Cosmetic leak of another user's viewing shape, so P3 — but it is dead code written for a job
nobody wired up.

---

## 3. STATE

### F-07 — P0 — CONFIRMED — the ba1160c show-merge is half-applied: counts merge, episodes do not
**State:** one series split across two folders, e.g. `/TV/MacGyver 1985/` and `/TV/MacGyver/`,
both with `show_name = "MacGyver"`.
**Where:** `main.go:5226 showGroupKey` merges on `LOWER(show_name)`. `handleTVShows` groups on
that key at `:8230`, but emits `"id": info.folderName` at `:8302` — and `info.folderName` is
**whichever folder was scanned first** (`:8232`, set only when `!exists`).
**What happens, precisely:**
1. `episodeCount` (`:8305`, `info.count++` at `:8241`) and `seasonCount` (`:8304`,
   `len(info.seasons)`) aggregate across **both** folders.
2. The client sends that single `folderName` back as the show id. `handleTVShowEpisodes`
   matches `path LIKE tvRoot + escapedID + "/%"` (`:8422`) — which matches the **first folder
   only**.
3. The `show_name = ?` fallback at `:8428-8431` fires **only when `matchCount == 0`**. The
   first folder exists, so the count is non-zero and **the fallback never runs**. The merge is
   silently half-applied. Same structure in `handleTVShowSeasons`: `:8376` primary,
   `:8384` fallback gated on `len(seasons) == 0`.
4. `showLastWatched` (`:8262-8289`) is keyed by **folder**, and read at `:8315` with
   `info.folderName` — so watching an episode in the *second* folder never updates the merged
   show's `lastWatchedAt`.
**User sees:** the show cell says "24 episodes / 2 seasons"; opening it lists 12 episodes across
1 season. `TVShowsView.swift:460-461` renders `episodeCount` for single-season shows, so the
inflated number is on screen. Sorting by Recently Watched (`TVShowsView.swift:91-103`) puts a
show you watched last night at the bottom because the progress was recorded under the other
folder.
**Severity rationale:** silently wrong data on the primary browse path, and it is the specific
behaviour commit ba1160c claims to have fixed ("a show is one show, even when split across
folders"). The grouping was fixed; the identity that every downstream query depends on was not.

### F-08 — P1 — CONFIRMED — one malformed item discards the entire page
**State:** server returns 50 items where item #37 has `"title": null` (or `durationSeconds` as
the string `"3600"`, or a missing `addedAt`).
**Where:** `Models/APIModels.swift:58-74` — `ItemSummary` declares `id`, `type`, `title`,
`addedAt` **non-optional**; `ItemsResponse.items: [ItemSummary]` at `:45`. Decoded as a whole
at `APIClient.swift:581`.
**What happens:** `JSONDecoder` is all-or-nothing over an array. One bad element throws, the
`catch` at `:587` wraps it as `APIError.decode`, and **all 50 items are discarded**.
**User sees:** a completely empty library grid from a healthy server with 49 good items.
**Credit where due:** the error *reporting* here is genuinely good — `describe()` at `:603-619`
names the offending field and type, and the comment at `:583-586` shows this class of bug was
already paid for once. The gap is granularity, not diagnosis: there is no per-element
`try?`/`compactMap` to salvage the good rows.

### F-09 — P1 — CONFIRMED — `Int32` narrowing on `limit` is a trapping conversion
**Where:** `LocalStore.swift:787` — `sqlite3_bind_int(stmt, 2, Int32(limit))` in
`fetchItems(forLibraryId:limit:)`.
**What happens:** `Int32(limit)` traps (crashes) for any `limit > Int32.max`. Every other
integer bind in this file deliberately uses `bind_int64`/`Int64` — the comment at `:367-374`
spells out exactly why, calling `Int32(x)` "a TRAPPING narrowing conversion" that produces "an
unrecoverable crash-loop with no in-app escape." This one line is the survivor of that sweep.
**Labelled P1 not P0:** `limit` is caller-supplied and internal (default 50), not server data,
so it is not currently reachable from a hostile payload. It is a loaded gun in a file whose own
comments document the shooting.

---

## 4. LIFECYCLE

### F-10 — P0 — CONFIRMED — a corrupt `downloads.json` silently destroys the whole download library
**Sequence:** `downloads.json` is valid JSON but wrong schema (or truncated by a jetsam kill
mid-write) → finish any one download.
**Where:** `DownloadManager.swift:729-734`:
```
if let rawData = try? Data(contentsOf: downloadsMetadataFileURL),
   let decoded = try? JSONDecoder().decode([DownloadedItem].self, from: rawData) {
  rawItems = decoded
} else {
  rawItems = []          // <-- corruption and "no file yet" are indistinguishable
}
```
then `:736-737` `updatedItems.insert(item, at: 0)` and `saveDownloadedItems(updatedItems)`.
**What happens:** a decode failure is coerced to "empty library," and the very next line
**overwrites the file with a single-element array**. Every other download's metadata is
permanently gone. The `.mp4` files remain on disk — orphaned, invisible in-app, and not
reclaimable through the UI.
**User sees:** 20 downloads become 1. Storage stays full with no way to free it from inside the
app.
**Three sites share the `try?`-to-nil pattern, all silent:** `:433-436` (`getDownloadedItems`
returns `[]`), `:497-499` (`updateResumePosition` silently no-ops, losing offline resume
positions), `:729-734` (the destructive one). Note `saveDownloadedItems` at `:633-657` *does*
log encode and write failures — the read path is the one with no diagnostics.

### F-11 — P0 — CONFIRMED — a corrupt `dsreel.db` is a permanent dead store with no recovery
**Sequence:** launch with a truncated `dsreel.db`, or one with a valid header and a garbage body
(the normal outcome of a kill mid-migration).
**Where:** `LocalStore.swift:131-157 openDatabase()`, `:123-127 setup()`, `:84-103` retry.
**What happens:** `sqlite3_open` is lazy — it succeeds on a garbage file, so `openDatabase()`
throws nothing. `migrate()` then fails on first real access. The retry at `:94` calls `setup()`
again, which calls `openDatabase()` on **the same corrupt file** and fails identically. There is
**no corruption recovery anywhere**: `grep` for `integrity_check`, `SQLITE_CORRUPT`, and any
delete-and-recreate of `dsreel.db` all return nothing.
**User sees:** the banner from `:54-58` via `AppState.swift:1818-1820` — honest, but
**permanent**. Continue Watching, Just Added and Recently Watched are empty forever; every
resume position silently fails to save. The only fix is deleting the app.
**Severity rationale:** the retry was built for exactly this and cannot work, because retrying
an unconditionally-failing open is not a recovery strategy. One `PRAGMA integrity_check` plus a
unlink-and-recreate would make this fully recoverable — the cache is by definition
reconstructible from the server.

---

## 5. ENVIRONMENT

Covered under F-08 (missing/null/wrong-type fields, empty arrays). Additional observations:

- **HTML body where JSON is expected (500/502 from a reverse proxy):** handled correctly.
  `APIClient.swift:556-579` checks the status code *before* decoding, tries
  `APIErrorResponse`, and falls through to `APIError.http(status)`. No crash, no false success.
- **Content-Type is never validated** (`grep` finds only the outbound header at `:513`). A 200
  response with an HTML body lands in the decode `catch` at `:587` and surfaces as
  `APIError.decode` — wrong-sounding but not harmful. P3, not itemised.
- **Auth expiry mid-session:** handled, and the comment at `:566-572` documents a previous bug
  where every 401 became `.server("invalid_token")` and the `.http(401)` handlers were
  unreachable. Status is now preserved. Clean.

---

## 6. CLOCK / LOCALE

### The headline locale attack found NOTHING — and I verified it rather than assuming
The brief flags comma-decimal locales as the highest-yield clock/locale target, and
`APIClient.swift:192-193` looked like a textbook hit: `String(format: "%.3f", startSeconds)`
formatted into a **URL query parameter**, parsed server-side by `strconv.ParseFloat`
(`main.go:5234`), which is locale-blind and rejects `"123,456"`. In a German locale that would
be a silent seek-to-zero on every resume.

I tested it instead of reporting it:
```swift
String(format: "%.3f", 123.456)                                  // "123.456"
String(format: "%.3f", locale: Locale(identifier:"de_DE"), 123.456) // "123,456"
```
`String(format:)` **without** a locale argument uses the POSIX/nil locale and is
locale-independent. The call sites pass no locale, so they are **SAFE**. `grep` confirms no site
in the app passes `locale:` or `Locale.current` to any formatter. Reporting this as a break
would have been a false CONFIRMED.

Also clean, checked:
- `Double(parts[0])` in `Views/Trickplay.swift:94-102` — `Double.init(String)` is
  locale-independent. Safe.
- The `%.1f` rating formatters (`HomeHero.swift:258`, `ItemDetailView.swift:821/845/848`) are
  display-only and never parsed back. Safe.
- **ISO8601 with and without fractional seconds:** correctly handled by the dual formatters at
  `AppState.swift:14-22` (`homeRailsFormatterFrac` and `homeRailsFormatter`). Clean.
- **Lexicographic ISO8601 sorting** (`TVShowsView.swift:89-115`) rests on a stated assumption
  that timestamps are uniform `yyyy-MM-ddTHH:mm:ssZ`. The backend emits `time.RFC3339` UTC
  everywhere (`main.go:2131`, `:5313`, `:5930`, `:6055`, …), so the assumption **holds today**.
  It is fragile — adding fractional seconds or a non-Z offset to any one writer would silently
  corrupt the sort order with no error — but it is not currently a break.

### Not attempted (out of budget, flagged for R6)
DST/midnight rollover for date *grouping*, non-Gregorian calendars, and RTL layout were not
exercised. I found no date-*grouping* logic in the rails (they sort by raw timestamp string and
never bucket by calendar day), which is why this scored low enough to drop — but I did not
prove the absence, so treat it as unattempted rather than clean.

---

## 7. ATTACKS THAT FOUND NOTHING (clean, not unattempted)

| Attack | Result |
|---|---|
| **SQL injection via search / any string reaching SQLite** | **CLEAN.** Every query in `LocalStore.swift` and every user-reachable backend query uses `?` placeholders with `sqlite3_bind_*` / `database/sql` args. No string-interpolated user data in any SQL. The rails SQL at `LocalStore.swift:643-664` *does* interpolate — but only compile-time `Double`/`Int` constants from `PlaybackProgress`, never input. F-01 is a LIKE-wildcard bug, **not** an injection. |
| **Path traversal via item/show IDs** | **CLEAN.** `/` and `..` are rejected at `main.go:3122`, `:7814`, `:8344`, `:8408`, and `pathWithinMediaRoot` (`:5252`) re-anchors against the configured roots with `filepath.Clean`. |
| **Double-tap Download** | **CLEAN.** Guarded by `activeDownloads[itemId] == nil` at `DownloadManager.swift:181` *and* `!isDownloaded` at `:187`, and both paths release the redundant playback session instead of leaking an ffmpeg transcode. Well built. |
| **Decode-error diagnosis / silent empty screens** | **CLEAN.** `APIClient.swift:587-600` wraps `DecodingError` as `APIError.decode` (not a bare rethrow, which the comment notes used to surface as "Could not connect to server"), and `describe()` names the exact field. Only the *granularity* is wrong — that is F-08. |
| **Progress outbox wiped on logout** | **CLEAN — I expected a break and was wrong.** `pending_sync` is a *column on `progress`* (migration v2, `LocalStore.swift:287`), not a separate table, so `DELETE FROM progress` in `clearAll():871-879` does clear the outbox. The whole clear is wrapped in a transaction against a mid-clear crash. |
| **Progress write races / stale-cache-beats-fresh-server** | **CLEAN.** `markProgressSynced():558-585` guards on the exact position+duration it uploaded, so a write that landed while a flush was in flight is not dropped from the outbox — the comment at `:550-556` reasons this through correctly. The server upsert is conditional (the 2026-08-05 correction at `:275-285` documents fixing a real last-write-wins data-loss bug). `subtitleOffset` is NaN/Inf-rejected and clamped at `main.go:3650-3657`; `clampStartSeconds():5233-5251` rejects NaN/Inf/negative and bounds to `duration - 10`. This subsystem has clearly been attacked before and held. |

---

## Ranked by likelihood a real user hits it

1. **F-07** (P0) — split-folder show: wrong episode/season counts, wrong Recently Watched order.
   Any user with a re-named or re-organised series folder. Silent wrong data on the main screen.
2. **F-01** (P0) — searching `%` or `_` returns the whole library / can't find a title with `_`.
   One keystroke to trigger.
3. **F-10** (P0) — one jetsam kill mid-write plus one completed download destroys the download
   library and orphans the files. Common on memory-pressured devices.
4. **F-04** (P0) — signing out (or deleting) while playing a download kills playback and the file.
5. **F-08** (P1) — one bad item from the server blanks an entire library page.
6. **F-11** (P0 severity, lower frequency) — corrupt DB is permanently dead with no recovery;
   requires an unlucky kill, but is unrecoverable when it happens.
7. **F-02** (P1) — show header metadata from the wrong rows; needs `_`/`%` in a folder name.
8. **F-05** (P1) — absolute paths written back on delete; real invariant violation, luck-recovered.
9. **F-06** (P3) — another user's season layout on a shared device.
10. **F-09** (P1 latent) — trapping `Int32` narrowing; not currently reachable from server data.
11. **F-03** (P2, SUSPECTED) — `Sscanf` accepts `limit=50abc`; clamped, so low impact.

## Two themes worth more than any single finding
- **Duplicated rules drift.** F-01, F-02, F-05 and F-09 are all cases where a rule was fixed in
  most places and missed in one — LIKE escaping inline at six sites with no helper, the
  filename-only path invariant warned about in comments and then violated twice, `Int32` swept
  to `Int64` everywhere but one line. The repo's comments repeatedly diagnose this pattern; the
  pattern is still producing bugs.
- **`try?`-to-nil conflates "corrupt" with "empty", and the next write makes it permanent.**
  F-10 and F-11 are the same shape: a read failure becomes a benign-looking empty value, and
  the code then writes over the real data. Corruption needs to be distinguishable from absence
  at all three `DownloadManager` sites and given a recovery path in `LocalStore`.
