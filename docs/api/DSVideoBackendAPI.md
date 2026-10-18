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
Generate a 6-digit pairing code for tvOS authentication. **Requires authentication** (user must be logged in).

Response:
```json
{
  "code": "123456",
  "expiresInSeconds": 600
}
```

### POST `/auth/pairing/exchange`
Exchange a pairing code for a session token. **Public endpoint** (no auth required).

Request:
```json
{ "code": "123456" }
```

Response:
```json
{
  "token": "<jwt>",
  "user": { "id": "u_123", "username": "admin", "displayName": "admin" }
}
```

Errors:
- `invalid_pairing_code` - code format invalid (must be 6 digits)
- `invalid_or_expired_pairing_code` - code not found or expired

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
    { "id": "p_1", "name": "Actor Name", "role": "Role", "imageId": "img_actor_1" }
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

### GET `/search`
Query:
- `q` (required)
- `libraryId` (optional)
- `offset` / `limit`

Response is the same shape as `/items`.

## Artwork

### GET `/images/{id}`
Query:
- `w` (optional width)
- `h` (optional height)
- `fit` (optional): `cover` | `contain`

Response: `image/*` bytes (with cache headers).

## Playback

### GET `/items/{id}/playback`
Creates/returns a playback source. The backend decides between direct file streaming and HLS.

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

`audioTracks` lists every audio stream of the source, in source order, for every `kind` (direct,
remux and HLS alike); a title with no audio answers `[]`, never `null`. It comes from the same
probe the HLS audio renditions are built from, so it matches the master playlist track for track
(TASK-1004). Per entry: `id` is `a` plus the 1-based position; `label` is the track title, else
its language, else `Track N` (made unique), the same `NAME` the master playlist carries;
`language` is the source tag lowercased (`""` when untagged or `und`); `title` is the source
title tag (`""` when absent); `codec` and `channels` are the source stream's; exactly one entry
has `default: true` (the source's default, else the first). A client may ignore the field: the
apps read the tracks from the HLS manifest.

With `?client=web`, a title that would otherwise be served by the realtime remux (`kind: "direct"`,
`transcoding: true`, one fragmented MP4 with ONE audio stream) and carries two or more audio tracks
is answered `kind: "hls"` instead, so the web player gets every track as an audio rendition
(TASK-1003). A single-audio title keeps the remux.

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
unrated is 4), as in `ProfilesAPI.md` "Item fields".

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

## Route inventory (generated)

The prose sections above document the **19 routes the iOS/tvOS clients actually call** —
the browsing, playback, progress and auth surface — with request/response shapes. That is the
contract worth describing by hand, and it is deliberately not the whole route table.

For completeness, every route the server registers is listed below, with ✅ marking the ones
documented above. Regenerate with `python3 scripts/gen-route-inventory.py`.

**88 routes total: 77 client-facing, 9 Synology WebAPI compatibility, 2 static/player.**

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
