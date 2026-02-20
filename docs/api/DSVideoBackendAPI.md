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
Returns logical libraries (Movies, TV Shows, Home Videos, plus any custom libraries).

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
  "contentRating": null,
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
    { "id": "a1", "label": "Stereo", "language": "en" }
  ],
  "resumePositionSeconds": 20
}
```

### GET `/playback/{sessionId}/stream`
Direct progressive streaming endpoint (supports `Range`).

### GET `/playback/{sessionId}/master.m3u8`
HLS master playlist.

### GET `/playback/{sessionId}/{variant}.m3u8`
HLS variant playlist.

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

## Admin (server configuration)

### GET `/admin/status`
Health/status endpoint (requires auth).

Response includes:
- build version
- active jobs (indexing/transcoding)
- libraries configured

### POST `/admin/scan`
Trigger a library re-scan (requires auth).

## Notes / v1 limitations

- DSM auth is used to validate credentials; **permissions mapping** to DSM shared folders is a v2 goal.
- tvOS support is achieved by the client consuming the same browsing and playback APIs; focus/UI is handled client-side.
