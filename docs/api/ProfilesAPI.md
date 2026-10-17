# DS Video Clone — Profiles, Age Ratings & Collections API (draft v1)

**Status:** Specified 2026-10-17 (TASK-914). **Not implemented yet.** This file describes the contract the
server and both apps build to. `DSVideoBackendAPI.md` stays the description of the live wire until this
ships, and then these sections move into it.
**Spec:** `docs/frd/FRD-002-profiles.md` (FR numbers below refer to it). **Architecture:** `docs/decisions/ADR-001-profile-visibility.md`.

## Conventions

Everything in `DSVideoBackendAPI.md` § Conventions applies (base URL `/api/v1`, Bearer auth, JSON, opaque
string IDs, ISO-8601 UTC). In addition:

- **Request header `X-DSVideo-Profile: <profileId>`** names the active profile on every authenticated
  request (FR-220).
  - Valid id for this account → served for that profile.
  - Unknown id, or an id from another account → `403 unknown_profile`. The client returns to the profile
    picker.
  - **Header absent** (FR-221) → the account's **most restricted** profile if it has any restricted profile
    (lowest `maxAgeLevel`, ties to the earliest created), otherwise the **owner** profile.
- **Response header `X-DSVideo-Profile: <profileId>`** on every authenticated response, naming the profile
  the server actually used (FR-222).
- **Errors** keep the server's existing shape: `{ "error": "<code>" }`, with the extra fields noted per code.
  **No profile or PIN error is ever 401.** 401 keeps its one meaning, "your session is invalid" (FR-217).
- **PINs** are strings of exactly 4 ASCII digits (`"0420"`, not `420`).
- `/profiles*` routes are exempt from `unknown_profile`: an unknown or deleted id falls back to FR-221 so a
  device holding a deleted profile id can still load the picker; the response header names the profile
  actually used.

## Item fields (added to every item payload)

Every object that represents a title (`/items`, `/items/{id}`, `/search`, `/just-added`, `/suggested`,
`/shows*`, `/tv/shows*`, `/watchlist`, `/collections/{id}/items`, and **`/sync/items`**) gains:

```json
{
  "contentRating": "PG-13",
  "ageLevel": 3
}
```

- `contentRating`: the stored US certification string, or `null` for unrated (FR-240). Display only.
  Clients never derive anything from it.
- `ageLevel`: integer 1–4 computed by the server (FR-241). **Unrated titles are `4`** (FR-242). A client's
  entire visibility check is `item.ageLevel <= activeProfile.maxAgeLevel`.

## Profile object

```json
{
  "id": "pf_7Qm2x",
  "name": "Maya",
  "avatar": "fox",
  "maxAgeLevel": 2,
  "hasPin": false,
  "isOwner": false,
  "createdAt": "2026-10-17T19:00:00Z"
}
```

`avatar` is an opaque key from the apps' built-in set: 1–32 characters, letters, digits, `-` and `_` only
(anything else is `400 invalid_avatar`); `null` clears it. The server stores it as given. The
PIN is never returned, only `hasPin`.

## Profiles

### GET `/profiles`
Lists the account's profiles. Works whatever the active profile is (the picker needs it).

Response:
```json
{
  "maxProfiles": 4,
  "activeProfileId": "pf_owner1",
  "profiles": [
    { "id": "pf_owner1", "name": "Ryan", "avatar": "owl", "maxAgeLevel": 4, "hasPin": true, "isOwner": true, "createdAt": "2026-10-17T19:00:00Z" },
    { "id": "pf_7Qm2x", "name": "Maya", "avatar": "fox", "maxAgeLevel": 2, "hasPin": false, "isOwner": false, "createdAt": "2026-10-17T19:05:00Z" }
  ]
}
```

### POST `/profiles`
Create a profile. **Requires the owner PIN** (FR-211), and the owner must already have a PIN (FR-212).

Request:
```json
{ "ownerPin": "0420", "name": "Maya", "avatar": "fox", "maxAgeLevel": 2, "pin": null }
```

Response `201`: the new profile object.

Errors: `owner_pin_required`, `pin_incorrect`, `pin_locked`, `owner_pin_not_set`, `profile_limit_reached`,
`invalid_profile_name`, `duplicate_profile_name`, `invalid_avatar`, `invalid_age_level`, `invalid_pin_format`.

### PATCH `/profiles/{id}`
Edit any profile, the owner's included. **Requires the owner PIN.** Only the fields present change.
`"pin": "1234"` sets or changes the PIN; `"pin": null` clears it.

Request:
```json
{ "ownerPin": "0420", "maxAgeLevel": 3 }
```

Response: the updated profile object.

Errors: as POST, plus `unknown_profile`, and `owner_profile_immutable` (lowering the owner's level, or
clearing the owner's PIN while other profiles exist).

To set the owner's **first** PIN, send `PATCH /profiles/{ownerId}` with `{ "pin": "0420" }` and no
`ownerPin`. That is only allowed while the owner has no PIN (FR-212).

### DELETE `/profiles/{id}`
Delete a profile **and permanently delete its progress, history and watchlist** (FR-206, destructive).
**Requires the owner PIN** in the JSON body.

Request:
```json
{ "ownerPin": "0420" }
```

Response:
```json
{ "ok": true }
```

Errors: `owner_pin_required`, `pin_incorrect`, `pin_locked`, `unknown_profile`, `owner_profile_immutable`
(the owner profile cannot be deleted).

### POST `/profiles/{id}/pin/verify`
Check a profile's PIN before the app enters it (FR-213). For a profile with no PIN this returns `ok`
immediately. Rate-limited per profile (FR-215); the owner-PIN checks on management calls share this
counter.

Request:
```json
{ "pin": "0420" }
```

Response:
```json
{ "ok": true }
```

Errors:
- `403 pin_incorrect`: `{ "error": "pin_incorrect", "attemptsRemaining": 3 }`
- `429 pin_locked`: `{ "error": "pin_locked", "retryAfterSeconds": 300 }` (5 minutes after 5 failures,
  doubling per further lockout, capped at 3600)
- `400 invalid_pin_format`, `403 unknown_profile`

### POST `/profiles/owner/pin/reset`
Reset a forgotten owner PIN by re-entering the **DSM password** (FR-216). Checked against DSM exactly like
`/auth/login`, and subject to the same sign-in rate limit.

Request:
```json
{ "password": "••••••••", "otp": "123456", "newPin": "0420" }
```

Response:
```json
{ "ok": true }
```

Errors: `403 password_incorrect` (wrong password or OTP; deliberately not 401), `403 otp_required` (the
DSM account has two-factor sign-in and no `otp` was sent; ask for the code), `403 permission_denied`
(DSM account no longer allowed to use the app, as at login), `503 dsm_unavailable` (DSM could not be
reached or gave no usable answer; the password is never blamed for that), `400 invalid_pin_format`.

### GET `/profiles/age-levels`
The ladder, for display on the profile editor ("Older Kids: PG, TV-Y7, TV-PG"). Clients display this and
never re-implement it (FR-241).

Response:
```json
{
  "unratedLevel": 4,
  "levels": [
    { "level": 1, "key": "littleKids", "label": "Little Kids", "movie": ["G"], "tv": ["TV-Y", "TV-G"] },
    { "level": 2, "key": "olderKids", "label": "Older Kids", "movie": ["PG"], "tv": ["TV-Y7", "TV-Y7-FV", "TV-PG"] },
    { "level": 3, "key": "teens", "label": "Teens", "movie": ["PG-13"], "tv": ["TV-14"] },
    { "level": 4, "key": "adult", "label": "Adult", "movie": ["R", "NC-17"], "tv": ["TV-MA"] }
  ]
}
```

## Collections

### GET `/collections`
The active profile's browse collections (FR-270–FR-276). Only collections with at least one title visible
to this profile are returned, in definition order. Kids' profiles (`maxAgeLevel ≤ 2`) get every
collection. Teens and Adult profiles get only `audience: all` (studio and theme) collections.

Response:
```json
{
  "collections": [
    { "id": "pixar", "title": "Pixar", "kind": "studio", "itemCount": 14, "posterImageId": "img_p_88" },
    { "id": "holiday", "title": "Holiday", "kind": "theme", "itemCount": 6, "posterImageId": "img_p_12" },
    { "id": "animation", "title": "Animation", "kind": "genre", "itemCount": 41, "posterImageId": "img_p_3" }
  ]
}
```

- `itemCount` counts titles visible to the active profile. A show counts once.
- `posterImageId` is a representative visible member's poster (most recently added), or `null`.
- An empty `collections` array means "no collections yet for this profile", not an error (FR-276).

### GET `/collections/{id}/items`
The titles in one collection, with the rating filter applied. Movies and shows appear once each; episodes
are never listed individually.

Query: `sort` (`title` default | `year` | `addedAt` | `rating`), `order`, `offset` / `limit`, the same
meaning as `/items`.

Response: the same shape as `GET /items` (`total` is the visible total).

Errors: `404 unknown_collection` (not defined, or not offered to this profile).

## Enforcement by route

How every client-facing route in the `DSVideoBackendAPI.md` inventory treats the active profile (FR-250).
**F** = filtered listing (hidden titles left out, totals and counts reflect only the visible set).
**R** = refused above the ceiling with `403 content_restricted`. **P** = data is per profile.
**U** = refused on restricted profiles with `403 profile_restricted`. **A** = account-scoped (not
filtered). **X** = exempt.

| Route | Class | Notes |
|---|---|---|
| `GET /items` | F | `continueWatching` / `recentlyPlayed` sections also P |
| `GET /items/{id}` | R | |
| `GET /items/{id}/playback` | R | gate is at session creation (FR-252) |
| `POST /items/{id}/progress` | P | accepted at any level (FR-231) |
| `GET /items/{id}/tmdb-search`, `POST /items/{id}/tmdb-fix` | U | plus the existing server-admin rule |
| `GET /search` | F | |
| `GET /just-added` | F | |
| `GET /suggested` | F, P | built from this profile's history |
| `GET /genres` | F | counts are visible counts |
| `GET /libraries` | A | the library list itself; an empty-for-this-profile library shows FR-265's message |
| `GET /libraries/summary` | F | counts are visible counts |
| `GET /shows`, `GET /tv/shows` | F | a show is visible iff its rating is |
| `GET /shows/{showName}`, `GET /tv/shows/{showId}/seasons`, `GET /tv/shows/{showId}/episodes` | R | |
| `GET /tv/shows/{showId}/tmdb-search`, `POST /tv/shows/{showId}/tmdb-fix` | U | |
| `GET /progress`, `GET /progress/all` | F, P | |
| `GET /watchlist` | F, P | entries above the ceiling hidden, not deleted (FR-207) |
| `GET /watchlist/{itemId}` | P | answers for this profile |
| `POST /watchlist/{itemId}` | R, P | |
| `DELETE /watchlist/{itemId}` | P | allowed at any level (removing is never harmful) |
| `GET /playlists`, `GET /playlists/{id}` | F | playlists stay per account (FR-230) |
| `POST /playlists`, `DELETE /playlists/{id}`, `DELETE /playlists/{id}/items/{itemId}` | A | |
| `POST /playlists/{id}/items` | R | |
| `GET /downloads` | F | download marks stay per account |
| `POST /downloads/{itemId}` | R | |
| `DELETE /downloads/{itemId}` | A | |
| `GET /trickplay/{itemId}/*` | R | |
| `GET /collections`, `GET /collections/{id}/items` | F | |
| `GET /profiles*`, `POST/PATCH/DELETE /profiles*` | — | rules in their own sections above |
| `GET /sync/items`, `/sync/deleted`, `/sync/status`, `/sync/heartbeat` | A | carries `ageLevel`; device filters every read (FR-262, ADR-001 §4) |
| `GET /settings`, `PUT /settings` | A | |
| `/admin/*` | U | plus the existing server-admin rule |
| `/auth/*`, `/version` | A | |
| `GET /images/{id}`, `GET /tmdb/image` | X | public artwork |
| `/playback/{sessionId}/*` | X | session id is the capability; gated at creation |
| `/webapi/*` (Synology compatibility) | F / R, P | no header possible → FR-221 fallback, same filter (FR-251); R answers WebAPI error 105 (the envelope has no string code); WatchStatus writes to the fallback profile |

## Error codes (added)

| Code | HTTP | Extra fields |
|---|---:|---|
| `unknown_profile` | 403 | — |
| `content_restricted` | 403 | — |
| `profile_restricted` | 403 | — |
| `owner_pin_required` | 403 | — |
| `pin_incorrect` | 403 | `attemptsRemaining` |
| `pin_locked` | 429 | `retryAfterSeconds` |
| `password_incorrect` | 403 | — |
| `otp_required` | 403 | — |
| `invalid_pin_format` | 400 | — |
| `invalid_profile_name` | 400 | — |
| `duplicate_profile_name` | 409 | — |
| `invalid_age_level` | 400 | — |
| `profile_limit_reached` | 409 | — |
| `owner_pin_not_set` | 409 | — |
| `owner_profile_immutable` | 409 | — |
| `invalid_avatar` | 400 | — |
| `dsm_unavailable` | 503 | — |
| `unknown_collection` | 404 | — |
