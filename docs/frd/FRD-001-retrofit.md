# FRD-001 — DSM Video (DS Reel): Retroactively Derived Functional Requirements

**Status:** Derived, not originally authored
**Date:** 2026-09-12
**Author:** Spock (Retroactive Test Oracle), Phase R1 of the test retrofit
**Companion artifacts:** `.claude/oracle/{progress,downloads,playback,library,auth,offline}-contract.json`

---

## 0. Provenance and how to read this document

This project shipped without a written functional spec. This FRD was reconstructed **blind** — that is,
without reading any application source, any server source, any existing test, or any diagnostic/QA
report. It was derived exclusively from **product surfaces**, which are promises already made to users:

| Source | Weight |
|---|---|
| App Store description + release notes (iOS and tvOS, `en-US`) | **Stated.** A shipped promise to users. Highest authority. |
| `docs/design-spec.md` (Lumen, DS Reel v1.0) | **Stated** where it describes user-visible behavior or data rules; treated as intent where it describes Swift tokens. |
| `docs/competitive-ux-research.md` — the "Patterns to Adopt" (P01–P12) and category analyses | **Intent / inference.** Establishes the product bar; not a shipped promise. |
| `CLAUDE.md` (product framing) | Context only. |
| Ticketmaster `dsvideo` open-ticket **titles** | Scope signal only; used to confirm which product areas exist, not to describe behavior. |

Every requirement below is tagged:

- **[STATED]** — the product surface literally says this. A violation is a broken promise to a paying user.
- **[INFERRED]** — not written anywhere, but logically entailed by a stated requirement (most often the
  negative case, the empty case, or the boundary of a stated behavior). A violation is a defect, but the
  wording of the requirement is mine, not the product's.

Deliberately **excluded** from derivation: `docs/accessibility-audit.md` (it audits a different app —
"Daily Mirror" — and contains nothing about this product), `docs/api/`, all `diagnostic-*`, `maxreview-*`,
`qa-*`, and reverse-engineering notes.

---

## 1. Scope

DSM Video ("DS Reel") is a client for a personal video library hosted on the user's own Synology NAS,
shipping on iOS/iPadOS and tvOS, backed by a Go server packaged as a DSM package. It browses a
movie/TV library, streams or transcodes it, downloads titles for offline viewing, and tracks watch
progress across devices.

Six functional areas are specified here, named from the user's point of view:
**Progress · Downloads · Playback · Library · Auth · Offline.**

---

## 2. Cross-cutting requirements

These bind every screen in the app and are the source of the most valuable assertions in the contract.

**FR-001 [STATED]** — *Empty and failed must be distinguishable.* A screen that has no content because
there genuinely is none must present an explanatory empty state. A screen that has no content because a
load failed must present a failure state naming the cause and offering retry. The two must never be
represented by the same UI.
*Derivation:* release notes (both platforms) — "consistent empty screens"; design-spec B6 requires a
search **error state "distinct from no results"**; competitive research P09/P10.

**FR-002 [STATED]** — *Error messages must name the real cause.* A failure caused by an unreachable
server must not be reported as bad credentials, an expired session, an unsupported video format, or an
empty library — and the converse for each. Distinguishable categories at minimum: server unreachable,
credentials rejected, account not permitted, session expired, media unplayable, insufficient storage.
*Derivation:* tvOS release notes — "Signing in no longer shows an old error message while a correct
password is working"; competitive research Error States — the named categories.

**FR-003 [STATED]** — *No indefinite spinner is an acceptable terminal state.* Any loading indicator must
resolve, within a bounded time, to either content or a named error with a retry affordance.
*Derivation:* both platforms' release notes — "a clear message and can retry, instead of an endless
loading spinner."

**FR-004 [INFERRED]** — *Stale error text must not survive a success.* When an operation succeeds, any
error message from a prior attempt must no longer be visible.
*Derivation:* generalized from the stated tvOS sign-in fix.

**FR-005 [INFERRED]** — *Truthful state over optimistic state.* The app must not display a state it cannot
honour (a resume point it will not resume from, a "downloaded" file it cannot play, a saved change it
will silently revert). Where a write cannot be completed, either persist it durably for later or tell the
user it failed.

**FR-006 [STATED]** — *tvOS reachability.* Every rendered interactive control on tvOS must be focusable
and activatable with the remote, and no content may be clipped by the display's safe area.
*Derivation:* tvOS release notes — player buttons "previously could not be selected at all"; "Long
descriptions no longer push the cast and Next Episode button off screen"; "Content sits properly inside
the safe area."

**FR-007 [STATED]** — *Accessibility floor.* Setup and diagnostics surfaces carry descriptive assistive
labels; text scales at larger accessibility sizes without controls becoming unreachable; the launch
animation is skipped when Reduce Motion is enabled.
*Derivation:* iOS release notes, ACCESSIBILITY section.

---

## 3. Progress (watch position)

**FR-010 [STATED]** — Watching a title past a meaningful threshold creates a resume point for it and adds
it to Continue Watching.
**FR-011 [STATED]** — Reopening a title with a resume point resumes at that position, not at the start.
**FR-012 [INFERRED]** — Resume positions survive app termination and are correct after a cold start,
read from durable storage.
**FR-013 [STATED]** — Progress is shared across devices: a position advanced on one device is the
position offered on another.
**FR-014 [INFERRED]** — Conflict resolution is last-watch-wins; a device must not overwrite a newer
position from elsewhere with its own older one.
**FR-015 [INFERRED]** — A position recorded while the server is unreachable is retained locally and
reconciled to the server when connectivity returns; it is never discarded.
**FR-016 [STATED]** — Continue Watching contains exactly the titles with progress strictly between zero
and complete, ordered most-recently-watched first. *Derivation:* design-spec B2 data requirements.
**FR-017 [INFERRED]** — With zero in-progress titles the rail is absent rather than rendered empty, and
its absence is not an error.
**FR-018 [STATED]** — Mark as Watched sets a title to fully watched, removes it from Continue Watching,
and clears its stray resume point. Mark as Unwatched reverses this.
**FR-019 [INFERRED]** — A cleared resume point must not be resurrected by a later sync from stale
server state. (Treated as **destructive**: the user deliberately destroyed state and it must stay
destroyed.)
**FR-020 [STATED]** — Poster cards show a progress indicator only when progress is above zero and below
complete, and a watched badge when complete. *Derivation:* design-spec B3 §3–4.
**FR-021 [INFERRED]** — A TV show contributes at most one Continue Watching entry, identifying the
specific partially-watched episode.
**FR-022 [INFERRED]** — Progress reached while the screen is locked (background audio) is recorded.
**FR-023 [INFERRED]** — A deliberate backwards seek is honoured as the new resume point; it is not
overwritten by the furthest point previously reached.
**FR-024 [INFERRED]** — Failure to load Continue Watching presents as a load failure, never as an empty
watch history (instance of FR-001).

---

## 4. Downloads (offline viewing)

**FR-030 [STATED]** — A title can be downloaded for offline viewing; the Downloads surface lists each
download with its state: completed, downloading (with progress and size), queued, or paused.
*Derivation:* design-spec B7 §2.
**FR-031 [STATED]** — **"Downloaded" means playable offline.** A title reported as completed must play
from local storage with the server unreachable. A transfer that did not fully complete must never be
reported as completed.
*Derivation:* iOS release notes — "Play is clearly unavailable for videos that aren't downloaded when
your NAS is offline"; this is only meaningful if the converse holds.
**FR-032 [STATED]** — A download failure is surfaced to the user. A failing download must not silently
vanish from the list.
*Derivation:* FR-005 plus the stated commitment to clear messages; corroborated as in-scope by ticket
TASK-782's title.
**FR-033 [INFERRED]** — A download failure message names the real cause (server unreachable, storage
full, server error) and never blames the video's format or the user's credentials (instance of FR-002).
**FR-034 [INFERRED]** — Completed downloads and their bookkeeping survive relaunch and are playable
after a cold start with no server contact.
**FR-035 [STATED]** — A download can be deleted, via swipe-to-delete among other paths. *Derivation:*
design-spec B7 §3.
**FR-036 [INFERRED, DESTRUCTIVE]** — Deleting a download removes exactly that item by identity, leaves
every other download intact, reclaims its storage, and never deletes media on the NAS. The deletion
survives relaunch.
**FR-037 [INFERRED, DESTRUCTIVE]** — Cancelling an in-progress download leaves no partial file counted
as used storage and never yields a completed state.
**FR-038 [STATED]** — The Downloads screen reports storage used against storage available.
*Derivation:* design-spec B7 §1.
**FR-039 [INFERRED]** — The reported storage figure corresponds to the actual bytes of the listed
downloads and changes by the deleted item's size after a deletion.
**FR-040 [INFERRED]** — A title already downloaded, or already downloading, cannot be enqueued twice;
exactly one entry per title identity exists.
**FR-041 [STATED]** — Downloaded titles are distinguishable in the library from non-downloaded ones, and
with the server offline, Play on a non-downloaded title is presented as unavailable **before** the tap.
**FR-042 [INFERRED]** — A download entry for an episode identifies the specific episode, not just the show.
**FR-043 [INFERRED]** — A completed download whose file has been removed outside the app stops claiming
to be playable.
**FR-044 [INFERRED, DESTRUCTIVE]** — Sign-out handles downloaded media in one consistent, stated way;
partial removal leaving orphaned bytes or entries pointing at missing files is a defect.

---

## 5. Playback

**FR-050 [STATED]** — Playing a title starts video and audio and advances the current time; titles the
server must transcode still play.
**FR-051 [STATED]** — Playback resumes at the title's recorded position, with an option to start over.
**FR-052 [STATED]** — If the NAS drops off the network mid-video, the user gets a clear message and can
retry — never an endless spinner. Retry resumes at the stall position.
**FR-053 [STATED]** — Transient buffering and permanent disconnection are distinguishable; recoverable
buffering never raises the connection-lost error.
*Derivation:* competitive research explicitly frames this distinction as the requirement.
**FR-054 [INFERRED]** — The connection-lost message names the network/server and never the video
format, the file, or the credentials (instance of FR-002).
**FR-055 [STATED]** — An audio interruption (phone call, Siri, another app) leaves playback in a usable
state afterwards; audio resumes properly. The player is never left where the play control does nothing.
**FR-056 [STATED]** — Unplugging headphones or removing AirPods pauses cleanly and leaves playback
resumable.
**FR-057 [STATED]** — **Background audio:** with the setting enabled, audio continues when the screen
locks; the setting can be turned off in Settings.
**FR-058 [INFERRED]** — While playing locked, the Now Playing surface shows this title's name, artwork,
duration and advancing elapsed time, and its controls actually affect playback. *(Stated as a pattern in
competitive research P05; inferred as a requirement from the stated background-audio promise — audio
that keeps playing with no lock-screen control is a half-feature.)*
**FR-059 [STATED]** — Playback Speed lives in Settings, is easy to find, and is easy to set back to
normal. A user must never be stuck playing fast with no way to change it.
**FR-060 [INFERRED]** — The persisted default playback rate is 1x; after a cold start with no explicit
change, playback is at normal speed.
**FR-061 [STATED]** — Subtitle and audio track selection is available in the player; where a language has
both full and forced subtitle variants they are presented as distinguishable, labelled choices.
*Derivation:* design-spec B5 §2/§6 (captions button + picker); competitive research P03; forced/full
split corroborated in scope by TASK-827/828 titles.
**FR-062 [INFERRED]** — A title with no subtitle tracks says so (or disables the control) rather than
showing an unexplained empty list.
**FR-063 [INFERRED]** — Switching audio track continues from approximately the same position rather
than restarting.
**FR-064 [STATED]** — Every player control — skip to start, back 15, play/pause, forward 15, skip to end —
is reachable and activatable with the tvOS remote.
**FR-065 [INFERRED]** — Back 15 / Forward 15 move the position by approximately 15 seconds and clamp
safely at both ends of the runtime.
**FR-066 [STATED]** — On tvOS, Menu closes the controls overlay when it is visible and exits playback
when it is not; Menu is never trapped.
**FR-067 [STATED]** — Pressing Menu during the next-episode countdown cancels it and does **not** start
the next episode.
**FR-068 [INFERRED]** — A completed countdown starts the correct next episode by season/episode
identity and records the finished episode as watched; the final episode of a show offers no countdown.
**FR-069 [INFERRED]** — A user's own seeking — including repeated seeks on a transcoded stream — never
leaves them unable to continue playing the title.
**FR-070 [INFERRED]** — Double-triggering Play yields exactly one playback session.
**FR-071 [STATED]** — With the NAS offline, Play on a non-downloaded title is unavailable up front rather
than failing after the tap.

---

## 6. Library (browse, shows, search, sort/filter, watchlist)

**FR-080 [STATED]** — The app lists every library the server exposes, with content organised using the
server's metadata — posters, episode guides, descriptions.
**FR-081 [INFERRED]** — Zero libraries, or an empty library, presents as an explanatory empty state;
failure to load presents as an error with retry (instance of FR-001).
**FR-082 [INFERRED]** — All titles in a library are reachable, each exactly once, across pagination
boundaries; the displayed item count matches the server's total. *(Item count display stated in
design-spec B3 §5.)*
**FR-083 [STATED]** — TV content is organised as show → season → episode, with seasons and episodes
matching what the server reports.
**FR-084 [INFERRED]** — A show whose episodes are split across multiple folders/paths on the NAS
appears exactly once, with its episodes merged.
**FR-085 [STATED]** — The detail screen shows title, year, runtime, genre, rating, director, cast, and
description. *Derivation:* design-spec B4 §4/§6/§7.
**FR-086 [INFERRED]** — Missing optional metadata is omitted cleanly — never rendered as "null"/"nil" or
an orphaned separator — and **missing artwork must not prevent the detail screen from loading.**
**FR-087 [INFERRED]** — Failed artwork is visually distinguishable from still-loading artwork.
**FR-088 [STATED]** — The Just Added rail surfaces recently added movies and episodes, most recent
first, capped at the documented maximum (10). *Derivation:* description + design-spec B2.
**FR-089 [STATED]** — Search is reachable from the Home screen on iPhone and searches the **whole**
library, not one section, across both movies and TV shows.
**FR-090 [STATED]** — Search distinguishes "no results for <query>" from a connection error, and the
error state offers retry. *Derivation:* design-spec B6 §3–4.
**FR-091 [STATED]** — Recent searches are offered as selectable chips when the field is empty.
*Derivation:* design-spec B6 §2.
**FR-092 [INFERRED, DESTRUCTIVE]** — Clearing recent searches empties them permanently, verified after
relaunch.
**FR-093 [STATED]** — The grid offers sort (All / A–Z / Year / Rating) and filtering.
*Derivation:* design-spec B3 §1.
**FR-094 [INFERRED]** — Sorting never changes the item count; filtering shows only matching items and
reports the matching count; a filter matching nothing presents a filter-attributable empty state with a
way to clear it.
**FR-095 [STATED]** — A watchlist exists, is reachable on iPad, and appears on the tvOS Home screen;
saved items must be viewable on every supported platform.
**FR-096 [INFERRED]** — Adding to the watchlist increases its count by exactly one for that identity;
removal decreases it by exactly one and leaves other entries intact; both survive relaunch.
**FR-097 [INFERRED]** — An empty watchlist explains how to add titles.
**FR-098 [INFERRED]** — A failed refresh of an already-loaded library keeps the existing content visible
with a refresh-failed indication; it must not wipe the grid to empty.
**FR-099 [INFERRED]** — Home-video-type libraries are browsable with whatever metadata exists; they are
not hidden and do not break the library view.
**FR-100 [INFERRED]** — Titles with unusual names (quotes, ampersands, non-ASCII, very long) list, open,
and are findable by search.

---

## 7. Auth (sign in, QuickConnect, pairing, session, sign out)

**FR-110 [STATED]** — Sign-in collects server address (IP **or** QuickConnect ID), username, and password;
successful sign-in reaches library content. *Derivation:* design-spec B1.
**FR-111 [STATED]** — QuickConnect and direct HTTPS are both supported connection paths, including for
remote access.
**FR-112 [STATED]** — The NAS is discovered automatically on the local network; manual IP entry is not
required.
**FR-113 [INFERRED]** — When nothing is discovered, manual entry remains available and the absence of
discovered servers is not an error.
**FR-114 [STATED]** — A correct password never displays a stale error from a previous attempt.
**FR-115 [INFERRED]** — Failure causes are distinguished: wrong credentials; unreachable server;
unresolvable QuickConnect ID; account not permitted to use this application; malformed address;
certificate/secure-transport failure (instance of FR-002).
*Note on account permission:* this one is derived from operational project memory rather than from
product copy, and is flagged as such.
**FR-116 [INFERRED]** — Concurrent sign-in attempts yield exactly one session and one definite outcome.
**FR-117 [STATED]** — **Pairing:** a device signs in by entering a short on-screen code shown on an
already-signed-in device; the account and server connection carry over with no password or server
address re-entry. This works in both directions (iOS→tvOS and tvOS→iOS).
**FR-118 [INFERRED]** — A wrong, expired, or already-used code is rejected with a message naming the
code, leaves the device unpaired, creates no partial session, and allows a retry with a fresh code.
**FR-119 [INFERRED]** — A session established by sign-in or pairing survives relaunch; the user is not
asked to re-authenticate after a cold start.
**FR-120 [INFERRED]** — An unreachable server at launch does not sign the user out and does not report a
credentials failure.
**FR-121 [INFERRED]** — An expired or revoked session is reported as a session problem with a path to
re-authenticate — not as the server being offline or the media being unplayable. After re-authenticating,
progress and watchlist are intact.
**FR-122 [INFERRED, DESTRUCTIVE]** — Sign-out returns the app to the sign-in screen, makes library
content unreachable, persists across relaunch, and leaves **no usable session credential anywhere on the
device** — including data shared with companion extensions or widgets. Surfaces such as a TV top-shelf
row must not continue to show content fetched with the old credentials.
*Note:* corroborated as in-scope by ticket titles TASK-774/775, which is why this is authored at a
high bar; the requirement itself derives from "PRIVATE BY DESIGN".
**FR-123 [STATED]** — **Privacy:** the app connects directly to the user's NAS; media does not pass
through third-party servers. Credentials are not transmitted in cleartext over a path the app itself chose
when a secure path was available.
*Derivation:* "PRIVATE BY DESIGN" (stated); the cleartext clause is inferred from it.
**FR-124 [INFERRED]** — Signing out on one device does not sign out another.

---

## 8. Offline (no server reachable)

**FR-130 [STATED]** — With the NAS unreachable, the app states that the server is offline. It does not sign
the user out and does not report a credentials error.
**FR-131 [STATED]** — An unreachable server never renders as an empty library. "We could not load" and
"there is nothing here" are distinct states on every surface (instance of FR-001, and the single
highest-value requirement in this FRD).
**FR-132 [INFERRED]** — Where library metadata has been cached, it is shown with a visible server-offline
indicator rather than presented as a freshly confirmed live list.
*Derivation:* competitive research P10 states the pattern; treating it as a requirement is inference.
**FR-133 [STATED]** — Offline, Play is unavailable up front on non-downloaded titles, and available and
functional on downloaded ones.
**FR-134 [INFERRED]** — Downloaded titles are visually distinguishable offline so the user can see what is
playable now.
**FR-135 [INFERRED]** — The Downloads list is truthful offline — it does not require the server to render,
and zero downloads reads as "nothing downloaded", not as a server failure.
**FR-136 [STATED]** — Search offline is a connection error with retry, not "no results".
**FR-137 [INFERRED]** — Offline progress and offline watched/watchlist changes are retained and
reconciled on reconnection, or the user is told at the time that they could not be saved.
**FR-138 [INFERRED]** — Cached content, the downloads list, and the signed-in session all survive a cold
start while offline.
**FR-139 [INFERRED]** — On reconnection, retry (or foregrounding) restores live content, clears the
offline indicator, and requires no re-sign-in; items removed from the NAS stop being offered.
**FR-140 [INFERRED]** — A download cannot be started offline; the attempt is refused with the real reason
and leaves no entry claiming to be playable. A transfer interrupted by connectivity loss reports an
interrupted state, never completed.
**FR-141 [INFERRED]** — Every surface reports the offline condition consistently; no screen shows a
success-looking or blank state while another reports offline.
**FR-142 [STATED]** — The offline error screen on tvOS is focus-navigable; its retry control can be
reached and activated (instance of FR-006).

---

## 9. Requirements the product surfaces could not settle

Recorded honestly rather than guessed:

1. **Thresholds.** No product surface states the elapsed fraction at which a title becomes "in progress",
   nor the fraction at which it becomes "watched", nor the stall duration before the connection-lost error
   fires. The contract therefore asserts the *existence and consistency* of thresholds and resumption
   "within 2 seconds of where the viewer left off", not specific numbers. **These need Ryan's numbers.**
2. **Track-selection memory.** Whether a chosen subtitle/audio track is remembered per title, per show,
   or not at all is unstated. OC-PLY-024 asserts only that behavior is consistent and that an explicitly
   disabled track is never silently re-enabled.
3. **Sign-out and downloads.** Whether sign-out deletes downloaded media is unstated. FR-044 /
   OC-DWN-026 require *one consistent* outcome rather than prescribing which.
4. **Season expansion memory.** OC-LIB-014 is the one assertion in the whole set marked
   `must_verify: false`, because no surface states whether expansion persists.
5. **Download quality selection and wifi-only** appear in the competitive research as patterns Plex has;
   nothing in DSM Video's own copy promises them. **Not specified here.** If they exist, they are
   unspecified features.

---

## 10. Module coverage summary

| Module | Assertions | Notes on derivation strength |
|---|---:|---|
| progress | 28 | Strong. "Continue Watching" and mark watched/unwatched are explicit App Store promises; design-spec supplies the exact membership rules. |
| downloads | 26 | Medium-strong. The *existence* and cell states are stated (design-spec B7); the "downloaded means playable" contract is inferred from one release-note sentence and is the most important inference in this document. |
| playback | 40 | Strongest. The iOS and tvOS release notes enumerate playback behaviors in unusual detail. |
| library | 42 | Strong for browse/search/watchlist; sort/filter specifics come from the design spec rather than shipped copy. |
| auth | 29 | Medium-strong. Pairing, QuickConnect, Bonjour and privacy are stated; the failure-cause taxonomy is largely inferred. |
| offline | 23 | Medium. Two release-note sentences plus a privacy promise carry it; the cached-content behavior (FR-132) is the weakest link and is the one area where the contract may be asserting a product decision that was never made. |

---

*This FRD is a reconstruction. Where it and the shipped app disagree, that is the point: this document
says what was promised, and the retrofit's job is to find out which promises hold.*
