# DS Video Clone — Backend API (draft v1)

This API is implemented by the **DSM 7.2.2+ SPK backend** and consumed by the iOS/iPadOS/tvOS client.

## Conventions

- **Base URL**: `http(s)://<host>:<port>/api/v1`
- **Auth**: `Authorization: Bearer <token>`
- **JSON**: `Content-Type: application/json`
- **IDs**: opaque strings
- **Timestamps**: ISO-8601 UTC

## Authentication & discovery

### POST `/auth/quickconnect/resolve`
Resolve a QuickConnect ID into candidate base URLs the client can try (direct / relay).

Request:
```json
{ "quickConnectId": "myqc" }
```

Response:
```json
{
  "candidates": [
    { "baseUrl": "https://example.synology.me:12345", "kind": "direct" },
    { "baseUrl": "https://relay-xyz.quickconnect.to:443", "kind": "relay" }
  ]
}
```

Unauthenticated, so it is guarded before it can reach Synology (TASK-1053):
- **Rate limit.** Shares the per-IP auth budget with `/auth/login` and pairing: 10 requests per 60 seconds per
  client address. Beyond that: `429 {"error":"rate_limit_exceeded"}` with `Retry-After: 60`. The limit counts
  every request, including ones rejected below, and runs first.
- **ID format.** `quickConnectId` (after trimming surrounding whitespace) must be 1-64 characters of letters,
  digits, `-` or `_`, starting with a letter or digit (the same rule pairing applies). Otherwise
  `400 {"error":"invalid_quickconnect_id"}`, with no outbound call.
- Other errors: `400 invalid_json`, `400 missing_quickconnect_id`, `502 quickconnect_resolve_failed`.

### POST `/auth/login`
Log in using **DSM credentials** (proxy validation via `SYNO.API.Auth`). On success the backend issues an app token.

Request:
```json
{ "username": "admin", "password": "••••••••", "otp": "123456" }
```

Response:
```json
{
  "token": "<jwt-or-session-token>",
  "user": { "id": "u_123", "username": "admin", "displayName": "admin" }
}
```

### POST `/auth/logout`
Invalidate the app token (and, if held, the DSM session).

### POST `/auth/pairing/generate`
Generate a 6-digit pairing code for another device (FR-117). **Requires authentication** (user must be logged in). Either platform can generate; the signed-out device redeems.

Request (optional; an empty body or `null` is accepted from older clients): how this signed-in device reaches the server, handed to the device that redeems the code [TASK-972]. Every field is optional. A field that is not a plain address (credentials, query, fragment, whitespace, non-ASCII, over 255 bytes) or not a QuickConnect ID shape is dropped, and the code is still issued.
```json
{
  "quickConnectId": "ryans-nas",
  "lanAddress": "http://192.168.50.148:8090",
  "wanAddress": "nas.example.org:8091"
}
```

Response:
```json
{
  "code": "123456",
  "expires_in_seconds": 600
}
```

Errors: `missing_token` (401), `invalid_json` (400, malformed body), `pairing_busy` (503, no free code could be drawn).

### POST `/auth/pairing/exchange`
Exchange a pairing code for a session token. **Public endpoint** (no auth required). Per-IP auth rate limit applies (10/min). Codes are single-use and expire after 10 minutes. Once 20 wrong codes (from any address) have been tried while codes are outstanding, every outstanding code is revoked and the count starts again [TASK-972].

Request:
```json
{ "code": "123456" }
```

Response (`server` is present only when the generating device sent connection details):
```json
{
  "token": "<jwt>",
  "user": { "id": "u_123", "username": "admin", "displayName": "admin" },
  "server": { "quickConnectId": "ryans-nas", "lanAddress": "http://192.168.50.148:8090", "wanAddress": "nas.example.org:8091" }
}
```

Errors:
- `invalid_json` (400)
- `missing_code` (400)
- `invalid_or_expired_code` (401) - code not found, expired, already used, or revoked

## Libraries & browsing

### GET `/libraries`
Returns the libraries the server is configured to scan (Movies, TV Shows, Home Videos). A library whose folder is not configured is not listed, and filesystem paths are never included. [TASK-985]

Response:
```json
{
  "libraries": [
    { "id": "lib_movies", "title": "Movies", "kind": "movies" },
    { "id": "lib_tv", "title": "TV Shows", "kind": "tv" },
    { "id": "lib_home", "title": "Home Videos", "kind": "home" }
  ]
}
```

### GET `/items`
List items in a library (paged). Also used for “Just Added” / “Recently Watched”.

Query:
- `libraryId` (required for library browsing)
- `section` (optional): `library` | `justAdded` | `continueWatching` | `recentlyPlayed`
- `sort` (optional): `addedAt` | `title` | `year` | `rating`
- `order` (optional): `asc` | `desc`
- `offset` / `limit`

Response:
```json
{
  "total": 1234,
  "items": [
    {
      "id": "it_abc",
      "type": "movie",
      "title": "Wildlife",
      "year": 2009,
      "durationSeconds": 30,
      "addedAt": "2009-07-14T13:32:31Z",
      "rating": null,
      "posterImageId": "img_p_1",
      "backdropImageId": "img_b_1",
      "progress": { "positionSeconds": 20, "durationSeconds": 30, "updatedAt": "2026-01-08T00:00:00Z" }
    }
  ]
}
```

#### Item summary (the shape of every title list)
Every endpoint that lists titles builds each element with one builder (`itemSummary`,
`backend/cmd/dsvideo-backend/item_summary.go`), so they all answer the `/items` element:
`id`, `type`, `title`, `year`, `durationSeconds`, `addedAt`, `rating`, `posterImageId`,
`backdropImageId`, `contentRating`, `ageLevel`, plus, when present, `showName`, `seasonNumber`,
`episodeNumber`, `showFolderId` and `progress` (the viewing profile's, FRD-002 FR-230). A test
(`item_summary_parity_test.go`) asserts each endpoint's element has the same key set as the
`/items` element for the same item, apart from the differences in this table:

| Endpoint | Differences from the `/items` element |
|---|---|
| `/items?filter=justWatched` | none (`progress` always present) |
| `/search` | none |
| `/playlists/{id}` | none |
| `/downloads` | none |
| `/watchlist` | adds `libraryId` |
| `/tv/shows/{showId}/episodes` | none |
| `/items/{id}/similar` | none |
| `/just-added` | adds `libraryId`; no `progress` (the rail is shared by every profile) |
| `/suggested` | none (it excludes every title the profile has progress on, so none has `progress`) |
| `/collections/{id}/items` | adds `libraryId`; no `progress` (a show is represented by one of its episodes) |

Keys added by this change (all additive; clients ignore unknown keys):
- `/search`, `/items?filter=justWatched`, `/watchlist`, `/tv/shows/{showId}/episodes` gain `showName`,
  `seasonNumber`, `episodeNumber`, `showFolderId` (an episode in search and the watchlist no longer
  loses its season/episode identity).
- `/playlists/{id}` and `/downloads` gain the same four keys and also `addedAt`, `rating` and
  `progress` (the viewing profile's).
- `/just-added` and `/suggested` gain `showFolderId`.
- `/collections/{id}/items`: ungrouped members (movies and episodes that file under no show folder)
  gain `showFolderId`, `seasonNumber` and `episodeNumber`.

Not item lists, so not built by `itemSummary`: `/tv/shows` (a show aggregate) and the sync feed
(`/sync/*`, a typed, account-scoped record).

Behaviour change: a row that fails to read from the database now fails the request with
`500 {"error":"db_error"}` on `/playlists/{id}`, `/downloads`, `/tv/shows/{showId}/episodes` and
`/suggested`. Before, those handlers silently dropped the row and answered `200` with a short list.
`/just-added` is served from a precomputed rail, so it has no request to fail: a row that fails to
read now fails that rail's computation (logged), the rail is not cached as complete, and the next
request recomputes it. Before, the row was dropped and the short rail was cached for up to 12 hours.

### GET `/items/{id}`
Item details (enriched metadata).

Response (movie example):
```json
{
  "id": "it_abc",
  "type": "movie",
  "title": "Wildlife",
  "originalTitle": null,
  "year": 2009,
  "durationSeconds": 30,
  "contentRating": "PG-13",
  "summary": null,
  "genres": [],
  "cast": [
    { "name": "Keanu Reeves" }
  ],
  "castMembers": [
    { "personId": 6384, "name": "Keanu Reeves", "character": "Neo", "imageId": "cast-6384" },
    { "personId": 530, "name": "Actor Without Photo", "character": null, "imageId": null }
  ],
  "images": {
    "poster": { "id": "img_p_1" },
    "backdrop": { "id": "img_b_1" }
  }
}
```

`contentRating` is the title's US certification as TMDb reports it, for example `"G"`, `"PG-13"`,
`"R"` for movies and `"TV-14"`, `"TV-MA"` for shows (an episode carries its show's rating). It is
populated for new scans and, over time, for existing libraries by a paced background backfill.
`null` means **unrated**: TMDb has no US certification for the title, or it is a placeholder such
as `NR`, `Not Rated` or `Unrated`. A `null` can also mean the backfill has not reached that
title yet; clients should treat both as "no rating known" and must not infer an age level from it.

`castMembers` (FR-150) is the cast in billing order. It is always present and is `[]` when the
title has no cast; it is never `null`. Each entry has exactly these four keys:

| Key | Type | Meaning |
|-----|------|---------|
| `personId` | integer or `null` | TMDb person id. `null` only for names the server has not yet filled in. |
| `name` | string | The actor's name. Never empty. |
| `character` | string or `null` | The role played. `null` when unknown. |
| `imageId` | string or `null` | `"cast-<personId>"` when the actor has a photo, else `null`. |

`imageId` is passed straight to `GET /images/{id}` (below). `null` means "show the placeholder", and
the client must not request a photo for it. Titles not yet filled in by the cast backfill return their
old names as entries with `personId`, `character` and `imageId` all `null`, so a client shows names
now and photos once the backfill has reached the title. The older `cast` array (names only) is kept for
older clients and is unchanged.

### GET `/items/{id}/similar`
More Like This (FR-151): other library titles like this one, best match first. Computed locally from
the library; no outbound calls.

Query:
- `limit` (optional): default `12`, clamped to `1`-`30`; an unparseable value uses the default

A title is a match when it shares a genre with the item or is in one of the same collections (the
Collections rails' definitions). Score: 3 per shared genre, 4 per shared collection, +2 same release
decade (+1 adjacent decade), +1.5 same kind (movie/show). Ties: higher `rating`, then title. Episodes
collapse to one entry per show (`title` and `showName` are the show's name, `year` the earliest,
`addedAt` the newest); the seed, and for an episode seed its whole show, are excluded.

Response `200`: `{"items": [...]}`, each element exactly the `/items` list element (including
`contentRating`, `ageLevel` and `progress` when present). `items` is `[]` when the item has no genres
and is in no collection.

```json
{
  "items": [
    {
      "id": "it_def",
      "type": "movie",
      "title": "Wildlife 2",
      "year": 2011,
      "durationSeconds": 5400,
      "addedAt": "2026-01-02T10:00:00Z",
      "rating": 7.4,
      "posterImageId": "it_def",
      "backdropImageId": null,
      "contentRating": "PG",
      "ageLevel": 2
    },
    {
      "id": "it_ep1",
      "type": "episode",
      "title": "Planet Show",
      "year": 2008,
      "durationSeconds": 2700,
      "addedAt": "2026-03-01T09:30:00Z",
      "rating": null,
      "posterImageId": "it_ep1",
      "backdropImageId": null,
      "contentRating": "TV-PG",
      "ageLevel": 2,
      "showName": "Planet Show",
      "seasonNumber": 1,
      "episodeNumber": 1,
      "showFolderId": "sf_9"
    }
  ]
}
```

Errors:
- `404 {"error":"not_found"}`: unknown id.
- `403 {"error":"content_restricted"}`: the item is above the viewing profile's age ceiling (the same
  answer `GET /items/{id}` gives). Entries above the ceiling, and unrated entries under a ceiling, are
  never returned (FR-250).

### GET `/search`
Query:
- `q` (required)
- `libraryId` (optional)
- `offset` / `limit`

Response is the same shape as `/items` (the item summary above, including `showName`, `seasonNumber`,
`episodeNumber` and `showFolderId` for episodes).

## Artwork

### GET `/images/{id}`
Query:
- `w` (optional width)
- `h` (optional height)
- `fit` (optional): `cover` | `contain`

Response: `image/*` bytes (with cache headers).

**Cast photos.** An id of the form `cast-<tmdbPersonId>` (the `imageId` of a `castMembers` entry)
returns that actor's photo at 185 px wide, as `image/jpeg` (or the type TMDb supplied), with
`Cache-Control: public, max-age=604800`. `w`, `h` and `fit` are ignored for these ids. The image is
fetched from TMDb on first request and kept in the server's image cache (capped by
`DSVIDEO_IMAGE_CACHE_MAX_MB`, default 1024; `0` = unlimited). Errors:

| Status | `error` | Cause |
|--------|---------|-------|
| 404 | `no_image_available` | The server knows no photo for that person. |
| 404 | `image_not_found` | A malformed id (`cast-0`, `cast-abc`), or the photo could not be fetched. |
| 503 | `image_cache_unavailable` | The server has no image cache configured. |
| 500 | `db_error` | The server could not read its database. |

Example: `GET /api/v1/images/cast-6384` returns the photo of person 6384.

## Playback

### GET `/items/{id}/playback`
Creates/returns a playback source. The backend decides between direct file streaming and HLS.

Query parameter `quality` (optional) caps the picture height of a transcode:

| Value | Meaning |
|-------|---------|
| `1080p` | cap at 1080 lines |
| `720p` | cap at 720 lines |
| `480p` | cap at 480 lines |
| `auto`, empty, or omitted | no cap (the default) |

The `p` suffix is part of the value. Any other value, including a bare number such as `1080`, is not
an error: it is treated as Auto, so a client that spells it wrong gets no cap and no warning. The web
player, iOS and tvOS all send exactly these strings. The accepted set lives in one place in the
backend (`qualityHeights`, `backend/cmd/dsvideo-backend/playback_quality.go`). [TASK-1031]

Response:
```json
{
  "kind": "hls",
  "hlsMasterUrl": "https://<host>/api/v1/playback/sess_123/master.m3u8",
  "subtitles": [
    { "id": "sub_1", "label": "English", "format": "vtt", "url": "https://<host>/api/v1/playback/sess_123/sub_1.vtt" }
  ],
  "audioTracks": [
    { "id": "a1", "label": "Main", "language": "eng", "title": "Main", "codec": "ac3", "channels": 6, "default": true },
    { "id": "a2", "label": "fre", "language": "fre", "title": "", "codec": "aac", "channels": 2, "default": false }
  ],
  "resumePositionSeconds": 20
}
```

`streamUrl`, `hlsMasterUrl` and subtitle `url` values are absolute, and the apps play them as given,
so each points back at the address this request came in on [TASK-1056]:

| Request arrived via | URLs begin with |
|---------------------|-----------------|
| LAN, DSM's port (`http://192.168.50.148:5000/api/v1/...`) | `http://192.168.50.148:5000/api/v1/playback/...` |
| The `/dsvideo` alias (`.../dsvideo/api/v1/...`) | the same address plus `/dsvideo`, e.g. `http://192.168.50.148:5000/dsvideo/api/v1/playback/...` |
| QuickConnect (any `*.quickconnect.to` host) | `https://<that host>:<that port>/api/v1/playback/...`, always `https` |
| WAN direct HTTPS (`https://<ddns>:5001/...`) | `https://<ddns>:5001/api/v1/playback/...` |

The host and port come from `X-Forwarded-Host` (the package's nginx sets it to the client's `Host`), else
`Host`; the scheme from `X-Forwarded-Proto`, else the connection. QuickConnect is always `https` because
the apps reach it only over TLS. HLS playlists and segments are relative to the master playlist, so they
follow it. `DSVIDEO_BASE_URL` is an optional override that pins every one of these URLs to a single
address; leave it unset (the package default) so LAN, WAN and QuickConnect clients each get their own.

`audioTracks` lists every audio stream of the source, in source order, for every `kind` (direct,
remux and HLS alike); a title with no audio answers `[]`, never `null`. It comes from the same
probe the HLS audio renditions are built from, so it matches the master playlist track for track
(TASK-1004). Per entry: `id` is `a` plus the 1-based position; `label` is the track title, else
its language, else `Track N` (made unique), the same `NAME` the master playlist carries;
`language` is the source tag lowercased (`""` when untagged or `und`); `title` is the source
title tag (`""` when absent); `codec` and `channels` are the source stream's; exactly one entry
has `default: true` (the source's default, else the first). A client may ignore the field: the
apps read the tracks from the HLS manifest.

With `?client=web`, a title that carries two or more audio tracks is always answered `kind: "hls"`,
so the web player gets every track as an audio rendition. That covers a title that would otherwise
be served by the realtime remux (`kind: "direct"`, `transcoding: true`, one fragmented MP4 with ONE
audio stream; TASK-1003) and one that would otherwise be direct played (a browser plays only a
file's default audio track; TASK-1028). The latter is repackaged with its video copied, so its
`transcodeMode` reads `remux`. A single-audio title keeps direct play or the remux. Without
`client=web` (the apps) nothing changes: a direct-playable multi-audio file is still direct played.

### GET `/playback/{sessionId}/stream`
Direct progressive streaming endpoint (supports `Range`).

### GET `/playback/{sessionId}/master.m3u8`
HLS master playlist. It is written once every playlist it lists exists, so a client that has
read it never asks for a playlist that is not on disk yet; until then this returns 404 while the
session prepares.

A source with **two or more audio tracks** gets every track as an alternate audio rendition
(FR-061): one `#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud"` line per track, and one
`#EXT-X-STREAM-INF` whose `AUDIO="aud"` points at a video-only `video.m3u8`. Per track:
`NAME` is the track title, else its language, else `Track N` (made unique); `LANGUAGE` is the
source tag, omitted when untagged; exactly one track is `DEFAULT=YES` (the source's default, else
the first); every track is `AUTOSELECT=YES`; `CHANNELS` is 2 for an encoded track, the source count
for a copied one. The video is encoded once; each non-AAC track is encoded to stereo AAC and AAC
tracks are copied. Example:

```
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="eng",NAME="eng",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio_0.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="fra",NAME="Commentary",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio_1.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO="aud"
video.m3u8
```

A single-audio (or silent) source is unchanged: one muxed media playlist, `init.mp4` and
`segment_NNNNN.m4s`.

### GET `/playback/{sessionId}/{variant}.m3u8`
A media playlist the master names: `video.m3u8` and `audio_N.m3u8` for a multi-audio session,
`subtitle_N.m3u8` for a WebVTT rendition. Serves exactly the named file; `404 not_found` if it
does not exist (it never substitutes the master), `400 invalid_playlist` for a name that is not
letters, digits, `_` or `-` (max 64). Same session-binding rule as every `/playback/{sessionId}/*`
route.

### GET `/playback/{sessionId}/{name}.mp4`
Per-rendition fMP4 init segment of a multi-audio session (`init_video.mp4`, `init_audio_N.mp4`).
Segments are `segment_<rendition>_NNNNN.m4s` on `/playback/{sessionId}/{name}.m4s`.

### GET `/playback/{sessionId}/segments/{name}`
HLS segment bytes.

## Progress / “Continue Watching”

Wherever a response carries a title's progress (the `progress` of a list element, the
`/sync/items` feed, the TV episode lists, and the values of `/progress` and `/progress/all`) it
is the same object, built by one function (`progressRecord.JSON`,
`backend/cmd/dsvideo-backend/progress_record.go`): `{"positionSeconds": <int seconds>,
"durationSeconds": <int seconds>, "updatedAt": "<RFC 3339>"}`, all three keys always present. A
title with no progress row has no `progress` key (`null` in the TV season episode list). A test
(`progress_shape_test.go`) asserts every site emits identical bytes for the same row.

### POST `/items/{id}/progress`
Request:
```json
{ "positionSeconds": 20, "durationSeconds": 30, "state": "playing" }
```

Response:
```json
{ "ok": true }
```

## Home rails (per profile, FRD-002)

Both rails are served for the request's profile: the one named by `X-DSVideo-Profile`, or
the FR-221 default when the header is absent (the account's most restricted profile, else
the owner). The response header `X-DSVideo-Profile` names the profile used. Each item
carries `contentRating` (raw US certification, `null` when unrated) and `ageLevel` (1-4;
unrated is 4), as in `ProfilesAPI.md` "Item fields". Elements are the item summary (see
`GET /items`); `/just-added` and `/suggested` carry `showFolderId` for episodes, and neither carries
`progress`. `/suggested` answers a database read failure with `500 {"error":"db_error"}`, not a short rail.

### GET `/just-added?libraryId=&limit=`
Newest titles, one entry per show, `limit` 1-24 (default 16). Titles above the profile's
age ceiling are left out **before** the show dedup and the 24-title cut, so a restricted
profile gets a full rail of what it can see (never a shared rail trimmed short). The server
precomputes one rail per ceiling and library, refreshed every 12 hours and on demand.

### GET `/suggested?libraryId=&limit=`
`{ "genre": "Animation", "items": [...] }`, `limit` 1-30 (default 8). Seeded from the
profile's most recently watched title that it can see, and excluding everything that
profile has progress on (another profile's history is never used). Titles above the
ceiling are filtered in the query, before `LIMIT`, so the rail is not left short. No visible
history answers `{ "genre": "", "items": [] }`.

## Admin (server configuration)

### GET `/admin/status`
Health/status endpoint (requires auth).

Response includes:
- build version
- active jobs (indexing/transcoding)
- libraries configured

### POST `/admin/scan`
Trigger a library re-scan (requires auth).

### POST `/admin/metadata/refresh?scope=`
Admin only. `scope=broken` (default) and `scope=all` clear the metadata fetched marker so the next
scan re-queries TMDb; any other value is `400 invalid_scope`.

`scope=cast` (FR-150) fills in cast photos and characters for titles scanned before they existed. It
reads each title's stored TMDb id (it never re-matches by title), asks TMDb once per distinct show or
movie, writes only the cast, and runs in the background at a gentle pace.

| Status | Body | Meaning |
|--------|------|---------|
| 202 | `{"scope":"cast","started":true,"queued":N,"items":M}` | Started. `queued` TMDb lookups covering `items` library items. |
| 202 | `{"scope":"cast","started":false,"reason":"cast_backfill_already_running"}` | A run is already in progress. |
| 200 | `{"scope":"cast","started":false,"reason":"nothing_to_backfill","queued":0,"items":0}` | Every title already has cast, has no TMDb id, or was checked and has no cast listed. |
| 400 | `{"error":"tmdb_not_configured"}` | No TMDb API key on the server. |
| 403 | | Caller is not the administrator. |

Safe to run repeatedly. Titles whose TMDb lookup failed stay queued for the next run; titles TMDb lists
no usable cast for are remembered and not asked about again.

## Route inventory (generated)

The prose sections above document the **20 routes the iOS/tvOS clients actually call** —
the browsing, playback, progress and auth surface — with request/response shapes. That is the
contract worth describing by hand, and it is deliberately not the whole route table.

For completeness, every route the server registers is listed below, with ✅ marking the ones
documented above. Regenerate with `python3 scripts/gen-route-inventory.py`.

**89 routes total: 78 client-facing, 9 Synology WebAPI compatibility, 2 static/player.**

### Client-facing

| Route | Methods | Documented |
|---|---|---|
| `/admin/metadata/refresh` | POST | — |
| `/admin/normalize/status` | GET | — |
| `/admin/scan` | POST | ✅ |
| `/admin/status` | GET | ✅ |
| `/auth/login` | POST | ✅ |
| `/auth/logout` | POST | ✅ |
| `/auth/pairing/exchange` | POST | ✅ |
| `/auth/pairing/generate` | POST | ✅ |
| `/auth/quickconnect/resolve` | POST | ✅ |
| `/auth/refresh` | POST | — |
| `/collections` | GET | — |
| `/collections/{id}/items` | GET | — |
| `/downloads` | GET | — |
| `/downloads/{itemId}` | DELETE, POST | — |
| `/dsvideo` | GET | — |
| `/dsvideo/` | GET | — |
| `/genres` | GET | — |
| `/images/{id}` | GET | ✅ |
| `/items` | GET | ✅ |
| `/items/{id}` | GET | ✅ |
| `/items/{id}/playback` | GET | ✅ |
| `/items/{id}/progress` | POST | ✅ |
| `/items/{id}/similar` | GET | ✅ |
| `/items/{id}/tmdb-fix` | POST | — |
| `/items/{id}/tmdb-search` | GET | — |
| `/just-added` | GET | — |
| `/libraries` | GET | ✅ |
| `/libraries/summary` | GET | — |
| `/playback/{sessionId}/init.mp4` | GET | — |
| `/playback/{sessionId}/master.m3u8` | GET | ✅ |
| `/playback/{sessionId}/segments/{name}` | GET | ✅ |
| `/playback/{sessionId}/stop` | POST | — |
| `/playback/{sessionId}/stream` | GET | ✅ |
| `/playback/{sessionId}/{name}.m4s` | GET | — |
| `/playback/{sessionId}/{name}.mp4` | GET | ✅ |
| `/playback/{sessionId}/{name}.ts` | GET | — |
| `/playback/{sessionId}/{variant}.m3u8` | GET | ✅ |
| `/playlists` | GET, POST | — |
| `/playlists/{id}` | DELETE, GET | — |
| `/playlists/{id}/items` | POST | — |
| `/playlists/{id}/items/{itemId}` | DELETE | — |
| `/profiles` | GET, POST | — |
| `/profiles/age-levels` | GET | — |
| `/profiles/owner/pin/reset` | POST | — |
| `/profiles/{id}` | DELETE, PATCH | — |
| `/profiles/{id}/pin/verify` | POST | — |
| `/progress` | GET | — |
| `/progress/all` | GET | — |
| `/search` | GET | ✅ |
| `/settings` | GET, PUT | — |
| `/shows` | GET | — |
| `/shows/{showName}` | GET | — |
| `/suggested` | GET | — |
| `/sync/deleted` | GET | — |
| `/sync/heartbeat` | GET | — |
| `/sync/items` | GET | — |
| `/sync/status` | GET | — |
| `/tmdb/image` | GET | — |
| `/trickplay/{itemId}/trickplay.jpg` | GET | — |
| `/trickplay/{itemId}/trickplay.vtt` | GET | — |
| `/tv/shows` | GET | — |
| `/tv/shows/{showId}/episodes` | GET | — |
| `/tv/shows/{showId}/seasons` | GET | — |
| `/tv/shows/{showId}/tmdb-fix` | POST | — |
| `/tv/shows/{showId}/tmdb-search` | GET | — |
| `/version` | GET | — |
| `/watchlist` | GET | — |
| `/watchlist/{itemId}` | DELETE, GET, POST | — |
| `/web` | GET | — |
| `Authorization` | GET | — |
| `Cookie` | GET | — |
| `Location` | GET | — |
| `User-Agent` | GET | — |
| `X-Forwarded-For` | GET | — |
| `X-Forwarded-Host` | GET | — |
| `X-Forwarded-Proto` | GET | — |
| `X-Real-IP` | GET | — |
| `X-TMDb-API-Key` | GET | — |

### Synology WebAPI compatibility layer

Legacy surface for DS Video clients. The shipping apps use `/api/v1` with Bearer auth and do
not depend on these.

| Route | Methods | Documented |
|---|---|---|
| `/webapi/DSVideoServer/entry.cgi` | GET, POST | — |
| `/webapi/DSVideoServer/poster.cgi` | GET | — |
| `/webapi/DSVideoServer/vtestreaming.cgi` | POST | — |
| `/webapi/DSVideoServer/vtestreaming.cgi/*` | GET, POST | — |
| `/webapi/VideoStation/poster.cgi` | GET | — |
| `/webapi/VideoStation/vtestreaming.cgi` | POST | — |
| `/webapi/VideoStation/vtestreaming.cgi/*` | GET, POST | — |
| `/webapi/entry.cgi` | GET, POST | — |
| `/webapi/query.cgi` | GET, POST | — |

### Static / player

| Route | Methods | Documented |
|---|---|---|
| `/` | GET | — |
| `/web/*` | HANDLE | — |

## Notes / v1 limitations

- **Profiles on the Synology WebAPI layer (FRD-002 FR-251).** WebAPI clients cannot send
  `X-DSVideo-Profile`, so every WebAPI call is served for the FR-221 default profile (the
  account's most restricted profile, else the owner), and its responses carry
  `X-DSVideo-Profile` naming it. `Movie.list`, `TVShow.list` and `TVShowEpisode.list` leave
  out titles above that profile's ceiling, with `total` counting only visible titles (a show
  is hidden when its rating is). `Movie.getinfo`, `TVShow.getinfo`, `TVShowEpisode.getinfo`
  and `Streaming.open` (both `entry.cgi` and `vtestreaming.cgi`) answer WebAPI error **105**
  (DSM's "session does not have permission"; the envelope carries only a number) for a title
  above the ceiling, and no stream session is created. `WatchStatus.update` /
  `File.set_watchstatus` write progress to that profile, at any title level (FR-231), and the
  `watch_status` in listings is that profile's. Posters and backdrops are exempt (FR-250).
- DSM auth is used to validate credentials; **permissions mapping** to DSM shared folders is a v2 goal.
- tvOS support is achieved by the client consuming the same browsing and playback APIs; focus/UI is handled client-side.
- **Scope**: the prose sections cover the client-facing surface, not every registered route. The generated inventory above is the complete list. The live wire contract has been diffed against the clients' decoded keys and matches exactly — the gap here is documentation coverage, not a contract mismatch.
