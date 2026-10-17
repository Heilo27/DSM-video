# FRD-002 — Profiles, Age Ratings and Kids' Collections

**Status:** Specified 2026-10-17 (TASK-914). Server part A in progress (TASK-916).
**Authority:** Ryan's decisions of 2026-10-17 are tagged **[RYAN]** and are binding. Design calls made to
carry them out are tagged **[DESIGN]**; those can be revised without going back to Ryan.
**Truths:** `docs/TRUTHS.md` (draft). **Mission:** `docs/frd/FRD-000-mission.md`.
**API contract:** `docs/api/ProfilesAPI.md`. **Architecture:** `docs/decisions/ADR-001-profile-visibility.md`.
**Depends on:** TASK-915 (fetch and store US certification, production companies and keywords).
**Amends:** FRD-001 FR-008 (new), FR-013, FR-095.

## Truth Test
- Serves: **S5** "Optional profiles inside one account" (Ryan, 2026-10-17).
- Supports: S1 (each viewer's position is one server-held truth on every device), S2 (Continue Watching
  stops showing someone else's position), S3 (migration keeps every existing position).
- Violates: none. Checked against A4 "not a second login system": a profile PIN works only inside a session
  DSM already authenticated and never grants server access by itself, so it is a lock, not a login.
- Verdict: **KEEP.** Ryan ruled on 2026-10-17 and added S5, in narrowed form: the product is still one
  account per DSM user (the product is already multi-user). Profiles are an optional subdivision of one
  account.

---

## 1. Terms

| Term | Meaning |
|---|---|
| **Account** | One DSM user signed in to DSVideo (server identity `u_<dsm username>`). Each account has its own profiles. A NAS with three DSM users has three independent sets of profiles. |
| **Profile** | A viewer within an account, with its own watch history, progress, watchlist, age ceiling and optional PIN. |
| **Owner profile** | The profile created automatically for every account. It manages the others. Not to be confused with the **server admin** (`DSVIDEO_ADMIN_USER` / `owner_username`), which is a DSM account with rights over server-wide settings. |
| **Age level** | An integer 1–4 from the rating ladder (§6). Every title has one; every profile has a maximum. |
| **Restricted profile** | Maximum age level below 4 (Adult). Unrated titles are hidden from it. |
| **Kids' profile** | Maximum age level 2 (Older Kids) or below. Browses by collections instead of genres (§9). |
| **Active profile** | The profile a request is served for (§4). |

## 2. Profiles

**FR-200 [RYAN]** An account has at most **4 profiles, the owner profile included**. Creating a fifth is
refused with `profile_limit_reached`.

**FR-201 [RYAN]** Each profile has its own watch history, progress and watchlist. Another profile in the
same account never sees, resumes from or changes them.

**FR-202 [RYAN]** Each profile has a maximum age level (§6). A profile sees only titles at or below it.

**FR-203 [DESIGN]** A profile has: a name (1–20 characters after trimming, unique within the account
regardless of case), an avatar key chosen from a fixed set built into the apps (no image uploads), a
maximum age level, and whether a PIN is set. The PIN itself is never returned by any endpoint. An avatar
key is 1–32 characters of letters, digits, `-` and `_`; anything else is refused with `invalid_avatar`.

**FR-204 [DESIGN]** Every account has exactly one owner profile, created automatically: at migration for
existing accounts (§5) and at first sign-in for new ones. Its name defaults to the DSM display name. Its
maximum age level is fixed at 4 (Adult) and cannot be lowered, because the owner manages profiles and must
be able to see every title it manages. It cannot be deleted (`owner_profile_immutable`).

**FR-205 [DESIGN]** An account with only its owner profile behaves exactly as DSVideo does today: no
picker, no PIN prompt, nothing filtered.

**FR-206 [DESIGN, DESTRUCTIVE]** Deleting a profile permanently deletes that profile's progress, watch
history and watchlist. Nothing else is touched: no media, no other profile's data, no downloads. Before
deleting, the app confirms with wording that names what is lost. A device whose active profile was deleted
returns to the profile picker on its next request (`unknown_profile`).

**FR-207 [DESIGN]** Lowering a profile's maximum age level **hides** progress and watchlist entries that are
now above it. It never deletes them, and raising the level brings them back.

## 3. PINs and profile management

**FR-210 [RYAN]** Any profile may have an optional PIN of exactly 4 ASCII digits. Anything else is refused
with `invalid_pin_format`.

**FR-211 [RYAN]** Creating, editing (name, avatar, age level, setting or clearing a PIN) or deleting **any**
profile, the owner's included, requires the owner profile's PIN. A missing PIN is refused with
`owner_pin_required`; a wrong one with `pin_incorrect`.

**FR-212 [DESIGN]** The owner profile must have a PIN before a second profile can be created
(`owner_pin_not_set`), and its PIN cannot be cleared while any other profile exists. Without this, FR-211
would protect nothing. The owner may set a first PIN with no prior PIN, because only the account holder
has a session at that point.

**FR-213 [DESIGN]** Selecting a PIN-protected profile requires its PIN, verified **by the server** every time
the profile is entered. The app never stores or checks PINs itself.

**FR-214 [DESIGN]** PINs are stored only as a salted, deliberately slow hash; the cost is tuned so one check
stays well under a second on the slowest supported NAS CPU. A PIN is never stored in plain text, logged or
returned.

**FR-215 [DESIGN]** PIN checks are rate-limited per profile. Every endpoint that accepts a PIN, owner-PIN
management calls included, shares one failure counter for that profile. After 5 consecutive failures the
profile's PIN checks are refused for 5 minutes with `pin_locked` and a `retryAfterSeconds`. Each further
lockout doubles the wait, up to 1 hour. A success resets the counter. The counter may live in memory; a
server restart resetting it is acceptable, because a viewer cannot trigger a restart.

**FR-216 [DESIGN]** A forgotten owner PIN is reset by re-entering the **DSM password** (and OTP, if the
account has one), checked against DSM exactly as at sign-in and subject to the sign-in rate limit. This
keeps DSM as the only identity (A4). If DSM cannot be reached or gives no usable answer, the reset is
refused with `dsm_unavailable` (503), never `password_incorrect`: an unreachable NAS service is not a wrong
password. A forgotten PIN on any other profile is cleared or changed by the owner under FR-211.

**FR-217 [DESIGN]** PIN and profile errors are **never** HTTP 401. The apps treat 401 as an expired session
and sign out (APIClient, DownloadManager), so a wrong PIN answered with 401 would sign the user out and
blame the session (FRD-001 FR-002, FR-121). Wrong DSM password during a PIN reset is `password_incorrect`
(403), not the sign-in endpoint's `invalid_credentials` (401).

## 4. Which profile a request is for

**FR-220 [DESIGN]** A client names the active profile with the request header `X-DSVideo-Profile:
<profileId>`. The server checks that the profile belongs to the token's account. An unknown id, or an id
from another account, is refused with `unknown_profile` (403). Both cases get the same answer, so the error
reveals nothing about other accounts. The profile management routes (`/profiles*`) are the exception: an
unknown or deleted id falls back to FR-221, so a device holding a deleted profile can still load the picker,
and the response names the profile actually used.

**FR-221 [RYAN]** A request **without** the header (shipped app builds, the `/web` player, the Synology
WebAPI compatibility layer, any client that predates profiles) resolves as follows:
- If the account has **any restricted profile**, the request is served for the **most restricted** profile:
  the lowest maximum age level, ties going to the earliest-created.
- Otherwise it is served for the owner profile.

This shuts the "use an old build" bypass. The consequence is deliberate: in a family account, a shipped
iPhone build sees the kids' library, and its progress and watchlist changes are written to that kids'
profile. FR-267 is what keeps the owner whole: both platforms ship the picker in the same release.

**FR-222 [DESIGN]** Every authenticated response carries `X-DSVideo-Profile` naming the profile it was
served for, so a client and a test can see what the server resolved.

**FR-223 [DESIGN]** The server does not ask for proof of PIN entry on each request. The PIN gates the
**apps'** profile selection (FR-213). §11 sets out what that does and does not protect.

## 5. Per-profile data and migration

**FR-230 [RYAN/DESIGN]** Progress, watch history (which drives Suggested and Continue Watching) and the
watchlist are kept per profile. Playlists, server-side download marks and settings stay per account.
Playlists and download marks are not used by any shipped app, and settings are device and server
preferences, not viewing history. Their contents are still filtered by the active profile's ceiling when
listed (§7).

**FR-231 [DESIGN]** Progress writes are accepted for any title, even one above the active profile's ceiling.
History is the viewer's own data, filtering applies when reading, and refusing a write would silently lose
a position (S3). Watchlist **adds** above the ceiling are refused (`content_restricted`), because the app
never offers them.

**FR-232 [DESIGN, DESTRUCTIVE: production migration]** On upgrade, every existing account gets an owner
profile, and every existing progress and watchlist row is assigned to it. No row is deleted, and no position
or watchlist entry changes value. Safety envelope, all required:
1. Before migrating, the server writes a full copy of the database file next to the original and logs its
   path. If that copy cannot be written, the migration does not run and the server does not start. It
   logs the real cause (for example, "Profiles migration needs N MB free next to the database; X MB
   available") so DSM shows the package as failed to start. There is no dual-schema serving mode (Friday,
   2026-10-17: running both schemas would double every progress and watchlist query, to cover a disk-full
   case that breaks the NAS anyway).
2. Rows are copied, never moved in place. The migration counts rows before and after, per table and per
   account. On any mismatch it rolls back, and the old tables stay authoritative.
3. The pre-migration tables are kept under a renamed name. Dropping them is a separate, deliberate change
   in a later release, flagged to Ryan when it happens.

**FR-233 [DESIGN]** After the app upgrades, positions already stored on the device belong to the owner
profile. The device's local progress is kept per profile, and its progress sync cursor is per profile, so
switching profiles never mixes or overwrites another profile's positions (FRD-001 FR-014, FR-015, FR-019
apply per profile).
Until the device knows which profile it is acting for (an offline launch, a profile list that failed to
load, or a sync that started before the list loaded), it neither uploads nor downloads positions, nor reads
or changes the watchlist: that traffic waits, and positions stay on the device, until a profile is active
or the server proves it has no profiles. Stored positions reach the owner only by that explicit hand-over,
never by a request without a profile, which FR-221 would serve for the most restricted profile.

## 6. Age ratings

### 6.1 Storage (contract for TASK-915)

**FR-240 [RYAN/DESIGN]** The server fetches each title's **US certification** along with its other TMDb
metadata and stores the **raw certification string**, trimmed, exactly as TMDb reports it (`PG-13`,
`TV-MA`, `NR`, …) in `items.content_rating`. It stores no derived level:
- **Movies:** the `US` entry of `/movie/{id}/release_dates`. Take the first non-empty certification in this
  release-type order: theatrical (3), theatrical limited (2), premiere (1), digital (4),
  physical (5), TV (6).
- **TV:** the `US` entry of `/tv/{id}/content_ratings`. Every episode row of a show stores **its show's**
  string, and inherits the show's companies and keywords too. A show is rated as a whole, never episode by
  episode.
- **Unrated is `NULL`.** No US certification, empty, `NR`, `Not Rated` and `Unrated` are all normalized to
  `NULL` when stored. These placeholders count as empty in the release-type order, so a theatrical `NR`
  falls through to the next release type that has a real certification (for example, a digital `PG`). This
  is intended: an unrated theatrical run followed by a rated home release is common, and the real rating
  carries more information than the placeholder. Whether a title has been fetched yet is tracked by the existing metadata-fetch marker,
  not by the rating column.
- Writing or changing `content_rating` bumps the item's change sequence, so delta sync delivers it to
  every device. The first backfill will bump every rated item, and that is expected.
- A metadata fix (`tmdb-fix`) re-fetches the certification with the rest of the metadata.

### 6.2 The ladder, defined once

**FR-241 [RYAN/DESIGN]** A certification maps to an age level by this table and nowhere else. The server
keeps it in one place (ADR-001), and **no client parses certification strings**.

| Level | Key | Label | Movie | TV |
|---:|---|---|---|---|
| 1 | `littleKids` | Little Kids | G | TV-Y, TV-G |
| 2 | `olderKids` | Older Kids | PG | TV-Y7, TV-Y7-FV, TV-PG |
| 3 | `teens` | Teens | PG-13 | TV-14 |
| 4 | `adult` | Adult | R, NC-17 | TV-MA |

Matching ignores case and surrounding whitespace.

**FR-242 [RYAN] The unrated rule.** A title whose certification is `NULL` (FR-240 stores every "not rated"
spelling as `NULL`), or **any string not in the table above**, is **unrated**. Its age level is **4**: hidden on every restricted profile, visible on
Adult profiles. Unknown strings fail closed. The server sends unrated titles as `ageLevel: 4` with
`contentRating: null`, so a client's whole visibility check is `item.ageLevel <= profile.maxAgeLevel`. That
one comparison is all a client may do, and the unrated rule lives only on the server.

*Why this ladder:* it is Friday's proposal, kept because it matches the US maturity tiers Netflix uses
(Little Kids / Older Kids / Teens / Mature), which most parents already know. Refinements: TV-G sits with G
because both mean suitable for all ages. TV-Y7-FV, the fantasy-violence variant TMDb data carries, is named
explicitly with TV-Y7 rather than left to fail closed. Four tiers is the smallest set that separates the
three common child stages from adult, and the unrated rule needs nothing more than "restricted vs not".

**FR-244 [DESIGN]** Changing the ladder is a server migration. It must bump the change sequence of every
item whose level changes, or devices keep the old levels in their cache.

**Known consequence [RYAN rule, flagged]:** home videos, and anything TMDb has no US certification for, are
hidden on restricted profiles. Until a manual rating override exists (deferred, §13), a family's own home
videos are invisible to the kids.

## 7. Enforcement: the server is the gate

**FR-250 [DESIGN]** The server applies the active profile's ceiling to **every** client-facing route. Each
route's class is listed in `docs/api/ProfilesAPI.md` §"Enforcement by route". The classes are:
- **Filtered listing.** Titles above the ceiling are left out. Totals, counts, genre counts and pagination
  reflect only the visible set (FRD-001 FR-082). Covers: items, search, Just Added, Suggested, shows, TV
  shows, genres, library summary, watchlist, progress, playlists, downloads, collections.
- **Refused if above.** Opening a title above the ceiling directly (detail, playback, seasons and episodes
  of a hidden show, trickplay, watchlist add, playlist add, download mark) is refused with
  `content_restricted` (403). A title the viewer reached by deep link, Siri or a stale cache gets an error
  naming the real cause, never a "not found" that blames the library (S2, FRD-001 FR-002).
- **Unrestricted only.** Metadata fixes (`tmdb-search` and `tmdb-fix` for items and shows) and `/admin/*`
  are refused on restricted profiles with `profile_restricted`. Otherwise a viewer could re-match a hidden
  title to a child-rated one and unhide the file. These routes stay under the existing server-admin rule as
  well.
- **Account-scoped replication.** `/sync/items`, `/sync/deleted`, `/sync/status` and `/sync/heartbeat`
  replicate the account's catalog to the device, with `ageLevel` on every item, and are **not** filtered.
  The device filters every read (FR-262). Reason in ADR-001: filtering a delta stream per profile breaks
  the delta semantics, because switching profiles changes what is visible without changing any item, so
  every switch would force a full re-sync, which is ~100x slower over WAN.
- **Exempt.** `/images/{id}` and `/tmdb/image` (public artwork, reachable only by an id taken from a
  filtered listing) and `/playback/{sessionId}/*` (the session id is the capability, and the session was
  gated when it was created).

**FR-251 [DESIGN]** The Synology WebAPI compatibility layer has no way to send the header. It resolves the
profile by FR-221 and applies the same filter to its library, list and stream calls. If it skipped the
filter, it would be a bypass of FR-221.

**FR-252 [DESIGN]** Playback is checked when the session is created. A ceiling lowered mid-stream takes
effect at the next session, not mid-segment.

## 8. The apps

**FR-260 [RYAN, 2026-10-17]** If the account has more than one profile:
- **tvOS** asks every time the app starts: the picker shows after pairing, at every cold launch, and when
  the app returns from the background after more than **30 minutes** (one named constant). The flow is
  pairing → picker → home.
- **iOS/iPadOS** shows the picker after sign-in, then **remembers the selection** across launches, so the
  user does not pick every time. "Switch profile" is always available. A remembered profile that requires a
  PIN is not re-prompted at launch on the same device. A remembered profile that was deleted, or that is no
  longer valid, falls back to showing the picker.

**FR-261 [DESIGN]** Switching profile reloads Continue Watching, the watchlist, the rails and the library
grids. Nothing from the previous profile stays visible, not even briefly (FRD-001 FR-004, FR-005).

**FR-262 [RYAN/DESIGN]** The app's offline and local fallback (the on-device catalog) applies the same
ceiling on **every** read, using each item's server-sent `ageLevel`. A local query that skips the filter is
a defect, even though the server would still refuse playback.

**FR-263 [DESIGN]** Offline: the cached profile list is shown. Profiles without a PIN can be entered. A
PIN-protected profile cannot be entered offline, and the picker says why ("Your NAS needs to be reachable
to check this PIN"). A profile already active stays active through a connection loss.

**FR-264 [DESIGN]** The Top Shelf extension, widgets and Siri/App Intents (PlayVideoIntent,
ShowInAppSearchResultsIntent) act for the active profile, shared through the app group, and never surface a
title above its ceiling. With no known active profile they show nothing profile-specific.

**FR-265 [DESIGN]** On a restricted profile, an empty grid, rail or collection caused by the ceiling says
so, naming the profile's level ("No Little Kids titles in Movies yet"). That message is distinct from
"this library is empty" and from "couldn't load" (FRD-001 FR-001, FR-131).

**FR-266 [DESIGN]** Profile management in the app asks for the owner PIN first, and confirms deletion under
FR-206. A failed PIN shows the real cause: wrong PIN, locked (with time remaining), or NAS unreachable.

**FR-267 [RYAN, 2026-10-17] Both platforms in one release.** iOS/iPadOS and tvOS both ship the
picker and send `X-DSVideo-Profile` in the same release that turns on server enforcement (FRD-000 standard
of done 3). Under FR-221 an iPhone build without the header is held to the most restricted profile in any
family account, so a tvOS-only release would lock owners out of their own library on the phone.

## 9. Kids' collections

**FR-270 [RYAN]** Kids' profiles (maximum age level ≤ 2) browse by **collections** (studio and theme
groupings plus kid-friendly genres) **instead of** the adult genre list.

**FR-271 [RYAN/DESIGN]** Collections are defined **once, server-side, as data**: id, title, kind
(`studio` | `theme` | `genre`), membership rule, audience. A title is a member if it has **any** of the
rule's company entries, **or any** of its TMDb keyword ids, **or any** of its genre names (genres are stored
as names, not ids). **A company entry always names its kind, `company` or `network`, as well as its id.**
TMDb numbers the two separately (company 2 is Walt Disney Pictures, network 2 is ABC), so an id without its
kind is ambiguous and is a defect in the definition. A show is judged at show level and listed once, never
per episode. Membership reads the `item_companies(item_id, kind, company_id, name)` and
`item_keywords(item_id, keyword_id, name)` tables that TASK-915 stores.

**FR-272 [RYAN/DESIGN]** The initial set. Every TMDb id below was checked against themoviedb.org on
2026-10-17. `company:N` means `kind = 'company'`, id N:

| Id | Title | Kind | Rule | Audience |
|---|---|---|---|---|
| `pixar` | Pixar | studio | company:3 (Pixar) | all |
| `disney` | Disney | studio | company:2 (Walt Disney Pictures), company:6125 (Walt Disney Animation Studios), company:3166 (Walt Disney Productions, the pre-1986 classics: *Snow White*, *Cinderella*, *Peter Pan*) | all |
| `dreamworks` | DreamWorks | studio | company:521 (DreamWorks Animation) | all |
| `illumination` | Illumination | studio | company:6704 (Illumination) | all |
| `holiday` | Holiday | theme | keyword 207317 (`christmas`) | all |
| `halloween` | Halloween | theme | keyword 3335 (`halloween`) | all |
| `animation` | Animation | genre | genre "Animation" | kids |
| `family` | Family | genre | genres "Family", "Kids" (TMDb's TV-only kids genre) | kids |

Keyword 65 (`holiday`) is deliberately **not** used. On TMDb it mostly tags vacation films, not seasonal
ones. Walt Disney Productions (3166) is added beyond Ryan's examples, because without it the Disney
collection would miss nearly every classic. Adding a collection is a data change in that one definition.

**FR-273 [RYAN]** The rating filter applies inside every collection. A collection with **no visible titles
for the active profile is hidden**: not listed, not shown empty.

**FR-274 [DESIGN] Who sees which collections.**
- **Kids' profiles (≤ Older Kids):** every collection, `kids` and `all` audiences, in definition order, as
  their browse categories in place of genres.
- **Teens and Adult profiles:** the genre list stays their primary browse, and the `all`-audience studio
  and theme collections are offered as an extra browse row. The `kids` genre-kind collections are left out
  because they would duplicate the Animation and Family genres these profiles already have.
- *Justification:* studio and theme collections serve adults too: a parent choosing a family movie from the
  owner profile, or the Christmas shelf in December. That is M2's "filter in ways that reflect what the user
  is actually looking for" (P1). One definition serving every profile costs nothing extra. Teens keep genres
  because a 13–16-year-old browsing "Pixar / Family" instead of Action / Comedy / Drama would find the app
  built for someone younger. Ryan's instruction was "kids' profiles", and Teens are not kids.

**FR-275 [DESIGN]** The server returns a profile's visible collections, with visible counts, from one
endpoint, and each collection's titles from a second, paged in the same shape as the item listing
(ProfilesAPI.md). Collection titles are data from the server definition. Studio names are proper nouns;
the two theme names are the only copy, and they have one home in the definition.

**FR-276 [DESIGN]** If no collection has a visible title (for example, no TMDb key is configured, so no
companies or keywords are stored), a kids' profile's browse area says there are no collections yet. That
message is distinct from a load failure, and the per-library grids are still reachable.

## 10. Error codes

All JSON errors use the server's existing `{"error": "<code>"}` shape. None is 401 (FR-217).

| Code | HTTP | When |
|---|---:|---|
| `unknown_profile` | 403 | Header names a profile that does not exist in this account (deleted, or another account's). |
| `content_restricted` | 403 | A title above the active profile's ceiling was opened directly, or added to the watchlist, a playlist or downloads. |
| `profile_restricted` | 403 | A restricted profile called a metadata-fix or admin route. |
| `owner_pin_required` | 403 | Profile management without `ownerPin`. |
| `pin_incorrect` | 403 | Wrong PIN (profile verify or owner PIN). Body includes `attemptsRemaining`. |
| `pin_locked` | 429 | Too many failures (FR-215). Body includes `retryAfterSeconds`. |
| `password_incorrect` | 403 | Owner PIN reset with a wrong DSM password or OTP. |
| `invalid_pin_format` | 400 | PIN is not exactly 4 ASCII digits. |
| `invalid_profile_name` | 400 | Name empty or longer than 20 characters after trimming. |
| `duplicate_profile_name` | 409 | Another profile in the account already has the name (ignoring case). |
| `invalid_age_level` | 400 | `maxAgeLevel` not an integer 1–4. |
| `profile_limit_reached` | 409 | The account already has 4 profiles. |
| `owner_pin_not_set` | 409 | Creating a second profile before the owner has a PIN. |
| `owner_profile_immutable` | 409 | Deleting the owner profile, lowering its age level, or clearing its PIN while other profiles exist. |
| `unknown_collection` | 404 | Collection id not defined, or hidden for this profile. |

## 11. Threat model (what this does and does not protect)

- **Protects:** a viewer using the DSVideo apps (and, through FR-221, any older build, the web player and the
  WebAPI layer) from seeing or playing titles above their profile's ceiling, and from entering or managing
  profiles without the right PIN.
- **Does not protect against:** anyone with the DSM password, because they *are* the account (A4); or anyone
  who can write their own HTTP requests with the account's token, who can name any profile in the header,
  since the server asks for no per-request PIN proof (FR-223). A 4-digit PIN is a household lock: the slow
  hash only stops a casual read of the database on the owner's own NAS, and offline brute force of 10,000
  values is trivial.
- **If that ever needs closing:** selecting a profile would issue a profile-scoped token, so the server
  enforces the PIN. That change is to ADR-001 and the API, not to this FRD's behaviour.

## 12. Truth Test per FR

"S5" means the proposed amendment pending Ryan's ruling (TRUTHS.md).

| FRs | Serves | Supports | Violates | Verdict |
|---|---|---|---|---|
| FR-200–207 profiles | S5 | S1, S2 | none | KEEP |
| FR-210–215 PINs, management | S5 | S4 | none (A4: lock, not login) | KEEP |
| FR-216 owner PIN reset via DSM | S5 | A4 holds (DSM stays the identity) | none | KEEP |
| FR-217 no 401 for PIN errors | S2 (errors name the real cause) | — | none | KEEP |
| FR-220–223 active profile | S5 | S1 | none | KEEP |
| FR-230, 231, 233 per-profile data | S5 | S1, S3 | none | KEEP |
| FR-232 migration envelope | S3 (data survives) | — | none | KEEP (required if the feature ships) |
| FR-240 certification storage | P1 (enriched detail: the existing FR-085 "rating" field gets a real value) | S1 | none | KEEP |
| FR-241, 242, 244 ladder, unrated rule | S5 | S1 (one server home) | none | KEEP |
| FR-250–252 enforcement | S5 | S2 (`content_restricted` names the cause) | none | KEEP |
| FR-260–266 apps | S5 | S2 | none | KEEP |
| FR-267 both platforms | FRD-000 standard 3 | S1 | none | KEEP (if the feature ships) |
| FR-270, 273 (kids' scope), 276 kids' collections | S5 | S2 | none | KEEP |
| FR-271, 272, 274 (adult row), 275 collections for Teens/Adult | P1 (findable: browse that reflects what the user is looking for, M2) | S1 | A1/A3: none (reads TMDb metadata only) | KEEP |

No CUTs. Nothing proposed during this work serves nothing or violates an anti-truth.

## 13. Deferred and open

- **DEFER: manual rating override in the metadata fixer.** It would let the owner rate home videos so the
  kids can see them. It serves M2 ("metadata the scanner got wrong must be fixable"). Post-launch ticket.
- **DEFER: network-based kids' collections** (Disney Junior, Nick Jr., PBS Kids). Kids' TV is grouped by
  network rather than production company. TASK-915 already stores networks (`kind = 'network'`), so this is
  only a definition change, but the network ids have not been checked yet. Post-launch ticket.
- **Open (Friday):** the profile-scoped token (§11) is not specified; FR-223 accepts the gap.

## Acceptance Criteria

Storage (TASK-915)
- **AC-002-01** Given a movie whose TMDb `US` release dates carry a theatrical certification, when it is enriched, then `content_rating` holds that string, trimmed. (FR-240)
- **AC-002-02** Given a movie whose `US` theatrical certification is empty or `NR` and whose digital certification is `PG`, when it is enriched, then `content_rating` is `PG`. (FR-240)
- **AC-002-03** Given a show whose `US` content rating is `TV-14`, when it is enriched, then every episode row stores `TV-14` and the show's companies and keywords. (FR-240, FR-271)
- **AC-002-04** Given a title with no `US` certification, or only `NR`, `Not Rated`, `Unrated` or empty, when it is enriched, then `content_rating` is `NULL`. (FR-240)
- **AC-002-05** Given an item whose `content_rating` is written or changed, then its change sequence increases, and `/sync/items?since=<previous cursor>` returns it. (FR-240)
- **AC-002-06** Given a title with a production company and a network that share a numeric id, then `item_companies` holds both rows, told apart by `kind`. (FR-271)

Server (TASK-916)
- **AC-002-10** Given each certification in the FR-241 table, in any letter case and with surrounding whitespace, then the API returns that row's `ageLevel`. Given `NULL`, then `ageLevel` is 4 and `contentRating` is `null`. Given an unknown string (`X`, `M`, `18`), then `ageLevel` is 4. (FR-241, FR-242)
- **AC-002-11** Given an account with 4 profiles, when a fifth is created, then the response is `409 profile_limit_reached` and no profile is created. (FR-200)
- **AC-002-12** Given profiles A and B in one account, when progress and watchlist entries are written under A, then none of them appear under B in `/progress`, `/progress/all`, `/items?filter=justWatched`, `/watchlist` or `/suggested`. (FR-201, FR-230)
- **AC-002-13** Given a restricted profile at level L and a library with titles at every level plus unrated ones, then every route marked F in ProfilesAPI.md returns no title with `ageLevel` > L, with totals equal to the visible count, and every route marked R returns `403 content_restricted` for a title above L. (FR-250)
- **AC-002-14** Given an Adult profile, then unrated titles appear in listings and search and start playback. (FR-242)
- **AC-002-15** Given a request without `X-DSVideo-Profile`: with no restricted profile in the account it is served for the owner; with restricted profiles at levels 3 and 1 it is served for the level-1 profile; with two level-1 profiles, the earlier-created one. In every case the response header names the profile used. (FR-221, FR-222)
- **AC-002-16** Given `X-DSVideo-Profile` naming another account's profile, or a deleted profile, then both requests get `403 unknown_profile` with identical bodies. (FR-220)
- **AC-002-17** Given a create, edit or delete request without `ownerPin`, then `403 owner_pin_required`. With a wrong `ownerPin`, then `403 pin_incorrect` with `attemptsRemaining`. No profile or PIN error anywhere returns 401. (FR-211, FR-217)
- **AC-002-18** Given an owner with no PIN, creating a second profile returns `409 owner_pin_not_set`. Given other profiles exist, clearing the owner's PIN, lowering the owner's level or deleting the owner returns `409 owner_profile_immutable`. (FR-204, FR-212)
- **AC-002-19** Given 5 consecutive wrong PINs on a profile, the sixth attempt, even with the correct PIN, returns `429 pin_locked` with `retryAfterSeconds` of about 300. After the wait, the correct PIN succeeds and resets the counter. (FR-215)
- **AC-002-20** Given a profile with PIN `0420`, then neither the database nor any response contains `0420`, and `GET /profiles` shows only `hasPin: true`. (FR-203, FR-214)
- **AC-002-21** Given the correct DSM password, `POST /profiles/owner/pin/reset` sets the new owner PIN. Given a wrong password, it returns `403 password_incorrect`, not 401. (FR-216, FR-217)
- **AC-002-22** Given a copy of a live database, after migration every account has exactly one owner profile; progress and watchlist row counts per account match before and after, with identical values; a full pre-migration database copy exists; and the pre-migration tables are kept. (FR-232)
- **AC-002-23** Given the pre-migration copy cannot be written, then the migration does not run, the database is unchanged, and the server exits at startup with a log line naming the cause. (FR-232)
- **AC-002-24** Given a restricted profile, `tmdb-search`, `tmdb-fix` (items and shows) and `/admin/*` return `403 profile_restricted`. (FR-250)
- **AC-002-25** Given a restricted profile and a title above its level, a progress write is accepted and stored, and a watchlist add returns `403 content_restricted`. (FR-231)
- **AC-002-26** Given a profile with progress and watchlist entries at level 3, lowering it to level 1 hides them, and raising it back shows them unchanged. (FR-207)
- **AC-002-27** Given profile B is deleted, then B's progress and watchlist rows are gone, and every other profile's rows, every download mark and every media file are unchanged. (FR-206)
- **AC-002-28** Given an account with a restricted profile, then WebAPI compatibility listings leave out titles above that profile's level. (FR-251)
- **AC-002-29** Given any profile, `/sync/items` returns every account item, those above the ceiling included, each with `ageLevel`. (FR-250)

tvOS (TASK-917)
- **AC-002-40** Given an account with more than one profile, on tvOS the picker appears after pairing, at every cold launch, and on return from more than 30 minutes in the background. Given a single-profile account, the app goes straight to home. (FR-205, FR-260)
- **AC-002-40a** Given an account with more than one profile on iOS, the picker appears after sign-in. A relaunch opens straight into the remembered profile without asking again. "Switch profile" opens the picker. A remembered profile that has been deleted brings back the picker. (FR-260)
- **AC-002-41** Given a PIN-protected profile, entering it requires a PIN the server accepts. A wrong PIN says so, a lockout shows the time remaining, and an unreachable NAS is named as the cause. (FR-213, FR-266)
- **AC-002-42** Given a switch from profile A to profile B, no rail, grid or watchlist entry from A is visible at any point after the switch. (FR-261)
- **AC-002-43** Given a restricted profile offline, no local read shows a title above its level. Given a PIN-protected profile offline, it cannot be entered, and the picker explains why. (FR-262, FR-263)
- **AC-002-44** Given an active profile, every request from the app, the Top Shelf extension and App Intents carries its `X-DSVideo-Profile`, and Top Shelf shows no title above its level. (FR-220, FR-264)
- **AC-002-45** Given a device upgraded with stored positions, those positions appear under the owner profile, and local progress written later is kept per profile. (FR-233)
- **AC-002-45a** Given an upgraded device in a family account holding unsent positions, launched offline, or whose profile list fails to load, or which syncs before the list loads: no position is lost and none appears under a restricted profile; they appear under the owner once the list loads. (FR-233, FR-221)
- **AC-002-46** Given a profile deletion, the confirmation says that the profile's history and watchlist will be permanently deleted. (FR-206, FR-266)
- **AC-002-47** Given a restricted profile and a library with no titles at its level, the empty state names the level, and it differs from both the empty-library state and the load-failure state. (FR-265)
- **AC-002-48** Given the release that enables server enforcement, the iOS/iPadOS app also offers the picker and sends `X-DSVideo-Profile`. (FR-267)

Collections (TASK-918)
- **AC-002-60** Given a kids' profile, `GET /collections` returns only collections with at least one visible title, in definition order, genre-kind ones included. Given a Teens or Adult profile, it returns only `audience: all` collections. (FR-273, FR-274)
- **AC-002-61** Given titles tagged company 3, network 2, keyword 207317, keyword 3335 and genre "Kids", then they fall in `pixar`, no collection (network 2 is not Disney), `holiday`, `halloween` and `family` respectively. (FR-271, FR-272)
- **AC-002-62** Given an R-rated Walt Disney Pictures title, it is neither returned nor counted in `disney` for a kids' profile. (FR-273)
- **AC-002-63** Given a show in a collection, it is listed once, and none of its episodes is listed individually. (FR-271)
- **AC-002-64** Given an undefined collection id, or one hidden for the profile, `/collections/{id}/items` returns `404 unknown_collection`. (FR-275)
- **AC-002-65** Given a kids' profile on tvOS, browse shows collections in place of genres. With none visible, it says there are no collections yet, distinct from a load failure. (FR-270, FR-276)
- **AC-002-66** Given the server source, collection ids, rules and titles are defined in exactly one place. (FR-271)

