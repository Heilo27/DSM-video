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
*Clarified 2026-10-18 (TASK-1040):* a server failure is never reported as a bare "Server error." or as a
code turned into a sentence. A profile change the server could not complete (it failed to generate an ID
or secure a PIN before writing anything) says the server failed, that nothing was saved, and to try
again and check the server logs on the NAS. A QuickConnect lookup the NAS could not complete says the
lookup service could not be reached from the NAS, points at the NAS's internet connection, and offers
signing in by address instead; it is never reported as an ID that was not found (that is its own message,
FR-115). A code the app has no copy for is still shown as a plain sentence, but only for malformed
requests the user cannot act on.

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

**FR-008 [AMENDED 2026-10-17, FRD-002]** — *Visibility is per profile.* Wherever this FRD says "the whole
library", "every title", "all titles" or a count of titles (FR-082, FR-089, FR-094 and the rest), it means the
titles visible to the **active profile** under its age ceiling (FRD-002 §6–§7). Titles hidden by the
ceiling are not "missing", and an empty view caused by the ceiling says so (FRD-002 FR-265).

---

## 3. Progress (watch position)

**FR-010 [STATED]** — Watching a title past a meaningful threshold creates a resume point for it and adds
it to Continue Watching.
**FR-011 [STATED]** — Reopening a title with a resume point resumes at that position, not at the start.
**FR-012 [INFERRED]** — Resume positions survive app termination and are correct after a cold start,
read from durable storage.
**FR-013 [STATED; AMENDED 2026-10-17, FRD-002]** — Progress is shared across devices **per profile**: a
position advanced on one device under a profile is the position offered on every other device under the
**same** profile, and it is never offered to a different profile. A request that names no profile (an app
build without profile support) reads and writes progress as the account's most restricted profile if one
exists, otherwise as the owner profile (FRD-002 FR-221). An account with only its owner profile behaves
exactly as before. FR-014–FR-025 apply per profile.
**FR-014 [INFERRED; DESTRUCTIVE rule stated 2026-10-17, TASK-960]** — Conflict resolution is
last-watch-wins, by when the viewer watched, not by when the save reached the server. A device must not
overwrite a newer position from elsewhere with its own older one, even when it was offline and its older
save arrives last. A device whose clock runs ahead is treated as watching when the server received the save,
so a wrong clock cannot pin a position forever. A device whose save loses re-fetches the position that
stands, so it never keeps showing its own stale one.
**FR-015 [INFERRED]** — A position recorded while the server is unreachable is retained locally and
reconciled to the server when connectivity returns; it is never discarded.
*Clarified 2026-10-18 (TASK-1012):* when this device cannot open its local store, nothing can be kept
locally, so this promise cannot hold and the user is told (FR-005). From launch, and for as long as it
lasts, a banner on iPhone, iPad and Apple TV says watch history can't be saved on this device and that
where you stop is saved only while the NAS is reachable. It never promises a later sync. A store that
opens shows no banner.
*Clarified 2026-10-18 (TASK-1034):* when this device's local store was found damaged and was rebuilt
empty, the store works but starts with no library, which would otherwise look like lost data. On the
launch where that happens, a notice on iPhone, iPad and Apple TV says the offline library was damaged and
rebuilt, and that videos reappear as they sync from the server. It is information, not a fault: it is
distinct from the unavailable-store banner above, clears itself after a few seconds (nothing to tap on
Apple TV), and does not return on later launches. A store that opened normally shows no notice.
**FR-016 [STATED]** — Continue Watching contains exactly the titles with progress strictly between zero
and complete, ordered most-recently-watched first. *Derivation:* design-spec B2 data requirements.
**Complete [DESIGN, 2026-10-17, TASK-962]** — "Complete" means one thing everywhere: the position is above
zero and either past 95% of the runtime or within the last 90 seconds of it. A title is "started" from 5%.
The Continue Watching and Recently Watched rails, the poster-card indicator and badge (FR-020), the show
page's Resume-or-next-episode choice (FR-011) and the restart-from-zero on reopening all read that one
rule (`PlaybackProgress.isFinished`; the rail SQL mirrors it). A 22-minute episode stopped 80 seconds from the
end is therefore complete: its show offers the next episode, not a resume.
**Thresholds, one set [DESIGN, 2026-10-18, TASK-1017]** — Three numbers, all in `PlaybackProgress`, and
nothing else in the app carries a threshold of its own. *Started* is 5% and up (inclusive): only a started
title is a resume point and belongs in Continue Watching. *Complete* is past 95%, or within the last 90
seconds. *Indicator* is any position above zero that is not complete. They are different questions with
different answers below 5%: a title at 3% is unwatched (not a resume point, not in Continue Watching, and
on a show page it is the next episode to play, not skipped), yet its card and its episode row still draw
a bar of 3%, because progress above zero is shown. Every surface reads them: the rails, poster cards, the
episode rows on the show page (check when complete, ring otherwise, nothing at zero), the downloaded-item
resume bar, and the show page's Resume-or-next-episode choice.
**FR-017 [INFERRED]** — With zero in-progress titles the rail is absent rather than rendered empty, and
its absence is not an error.
**FR-018 [STATED]** — Mark as Watched sets a title to fully watched, removes it from Continue Watching,
and clears its stray resume point. Mark as Unwatched reverses this.
**FR-019 [INFERRED]** — A cleared resume point must not be resurrected by a later sync from stale
server state. (Treated as **destructive**: the user deliberately destroyed state and it must stay
destroyed.) This includes an older save replayed from an offline device after the clear, or after a
title was marked watched: it never brings back the resume point or un-watches the title (TASK-960).
**FR-020 [STATED]** — Poster cards show a progress indicator only when progress is above zero and below
complete, and a watched badge when complete. *Derivation:* design-spec B3 §3–4.
**Card indicator [DESIGN, 2026-10-17, TASK-978]** — One function decides what a poster card draws
(`PlaybackProgress.cardIndicator`), and the iOS grid and rails and both tvOS cards use it. At position zero
the card draws nothing: no bar, no empty track, no percentage in its VoiceOver label. Complete (see FR-016)
draws the watched badge and no bar, on every card shape (the tvOS landscape card drew no badge until TASK-1018, and the iOS Continue Watching card none until TASK-1035). One view draws the badge on all of them (`CardWatchedBadge`). Anything between draws a bar whose width is exactly the fraction watched;
there is no minimum width and no upper cutoff (iOS used to hide the bar below 2% and above 98%).
**FR-021 [INFERRED]** — A TV show contributes at most one Continue Watching entry, identifying the
specific partially-watched episode.
**FR-022 [INFERRED]** — Progress reached while the screen is locked (background audio) is recorded.
**FR-023 [INFERRED]** — A deliberate backwards seek is honoured as the new resume point; it is not
overwritten by the furthest point previously reached.
**FR-024 [INFERRED]** — Failure to load Continue Watching presents as a load failure, never as an empty
watch history (instance of FR-001).
**FR-025 [DESIGN, 2026-10-17, TASK-941]** — When the server re-keys a title (for example after its file
moves or is converted to a new container), every profile's watch progress follows the title to its new
identity, and every device picks that up at its next sync: no device keeps offering the position under
the title's old identity, and none needs any other progress change to happen first. A re-key that
touches no progress causes no progress refetch.

---

## 4. Downloads (offline viewing)

**FR-030 [STATED]** — A title can be downloaded for offline viewing; the Downloads surface lists each
download with its state: completed, downloading (with progress and size), queued, or paused.
An in-flight row reads "Queued" until the first bytes arrive, then percent plus bytes received of the
total ("42% · 310 MB of 1.2 GB", bytes alone when the total is unknown); a paused row reads "Paused".
Queued never renders like downloading. *(TASK-979)* A paused row shows the percent it had reached when
it paused (its bar keeps that length), also after the app is relaunched; the percent and the byte count
are cleared when the download is cancelled, completes, fails, or the user signs out. *(TASK-1021)*
*Derivation:* design-spec B7 §2.
**FR-031 [STATED]** — **"Downloaded" means playable offline.** A title reported as completed must play
from local storage with the server unreachable. A transfer that did not fully complete must never be
reported as completed.
*Derivation:* iOS release notes — "Play is clearly unavailable for videos that aren't downloaded when
your NAS is offline"; this is only meaningful if the converse holds.
**FR-032 [STATED]** — A download failure is surfaced to the user. A failing download must not silently
vanish from the list. A transfer that finishes but whose file cannot be kept on the device leaves
Downloading for a retryable Failed row naming storage as the cause, leaves no orphaned bytes behind, and
never sits at 100% (TASK-971). A Failed row stays on the Downloads screen, across a relaunch, until the
user retries or dismisses it; every Failed row offers both, none is Dismiss-only (TASK-994).
*Derivation:* FR-005 plus the stated commitment to clear messages; corroborated as in-scope by ticket
TASK-782's title.
**FR-033 [INFERRED]** — A download failure message names the real cause (server unreachable, storage
full, server error) and never blames the video's format or the user's credentials (instance of FR-002).
*Clarified 2026-10-17 (TASK-961):* only a server answer that the session is gone says the session
expired. A download the server refuses for a title above the profile's age rating names the age rating;
a download refused because its profile no longer exists names that and returns to the profile picker
like any other request (FRD-002 FR-206). A refusal with no stated reason never claims the session expired.
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
**FR-040 [INFERRED]** — A title already downloaded, already downloading, or paused (or failed and
awaiting retry), cannot be enqueued twice; exactly one entry per title identity exists. A request for
such a title opens no second transfer and hands back the playback session opened for the request. The
title page offers Resume (not Download) for a paused download.
**FR-041 [STATED]** — Downloaded titles are distinguishable in the library from non-downloaded ones, and
with the server offline, Play on a non-downloaded title is presented as unavailable **before** the tap.
A downloaded title carries a small "downloaded" mark in the top-left corner of its poster card (library
grid, home rails, collections, search results wide enough to hold it) and an inline mark in its episode
row; the mark is also spoken ("Downloaded"). With the server unreachable, a card for a title that is not
downloaded is dimmed (and spoken as "Not available offline") while its page still opens. The mark follows
the playable download (FR-043, FR-262: on disk and allowed for the active profile) and disappears the
moment the download is deleted, without a relaunch. iOS only: the Downloads surface does not exist on
tvOS, so tvOS cards carry no mark and are never dimmed for this.
**FR-042 [INFERRED]** — A download entry for an episode identifies the specific episode, not just the show.
An episode's download reads "Show · S1 · E2 · Episode title"; a missing part is left out (never an empty
segment or a repeat), so two "Pilot"s of different shows, and two episodes of one show, are told apart,
and the show name appears once. A blank episode title leaves "Show · S1 · E2". *(TASK-980)*
**FR-043 [INFERRED]** — A completed download whose file has been removed outside the app stops claiming
to be playable. *(OC-1054)* [DESIGN, 2026-10-18, TASK-1046]: this holds while the app is running, not
only after a relaunch. When the Downloads screen appears, and when the app returns to the foreground, the
list is checked against the files on disk and a title whose file is gone leaves it, with its neighbours
untouched. Reading the list does not itself check the disk (large libraries), so a file removed while
another screen is open is noticed at the next of those two moments.
**FR-044 [INFERRED, DESTRUCTIVE]** — Sign-out handles downloaded media in one consistent, stated way;
partial removal leaving orphaned bytes or entries pointing at missing files is a defect.
Unfinished downloads (in flight, paused or failed) and their records go with sign-out too; none comes back
as the next user's paused or failed row (TASK-947).
**FR-045 [INFERRED]** — **Downloads survive the app being closed.** The system may end the app while a
transfer continues in the background (TASK-947):
- A transfer that finishes while the app is closed lands as a completed download with the title and
  age level it started with, or as a Failed row stating the cause; it is never silently discarded.
- A transfer still running when the app comes back is shown downloading with its progress, and tapping
  Download for that title joins it; a second transfer for the same title never starts (FR-040).
- A transfer stopped with progress kept (paused, network lost, app force-quit) shows as paused and
  continues from where it stopped. If the server no longer holds the session it was cut from, it starts
  over on a fresh one rather than failing. A stop with nothing to continue shows as Failed, naming why
  (connection, storage, app closed, Background App Refresh off, system stopped it).
- A download that completes in a background relaunch, before the app can sign in to the server, is kept
  at once; releasing its playback session and fetching its poster wait for the app to be running with a
  session, and are not lost if the app closes in between (TASK-994).
- A pause that races a transfer finishing never drops the finished file.
- *Accepted limit:* a transfer resumed from saved data and cut again by a relaunch restarts on a fresh
  session only once the app is running with a server session; until then its Failed row says to start
  it again.
- An unfinished download whose transfer was lost with the app shows as Failed ("interrupted") and can be
  started again.

---

## 5. Playback

**FR-050 [STATED]** — Playing a title starts video and audio and advances the current time; titles the
server must transcode still play.
**FR-051 [STATED]** — Playback resumes at the title's recorded position, with an option to start over.
**FR-052 [STATED]** — If the NAS drops off the network mid-video, the user gets a clear message and can
retry — never an endless spinner. Retry resumes at the stall position.
*Clarified 2026-10-17 (TASK-991):* when the app moves between the home and away addresses
mid-video (M5), the video picks up again on the new address near where it was, with no tap. A video
that failed to load for lack of network retries itself when the network returns. If the new address
cannot play it either, the message names that failure, not the one that led to it.
*Clarified 2026-10-17 (TASK-1008):* a video that stopped mid-playback because the network dropped
also retries itself when the network returns at the same address, picking up near where it stopped.
A video that stopped for any other reason waits for the user's Retry.
*Clarified 2026-10-17 (TASK-1009):* a video or download requested just as the app moves between
addresses plays or downloads from the address the app is now using, never from the one it just left.
**FR-053 [STATED]** — Transient buffering and permanent disconnection are distinguishable; recoverable
buffering never raises the connection-lost error.
*Derivation:* competitive research explicitly frames this distinction as the requirement.
**FR-054 [INFERRED]** — The connection-lost message names the network/server and never the video
format, the file, or the credentials (instance of FR-002).
*Clarified 2026-10-17 (TASK-1007):* the reverse holds too: a failure that is not a connection
failure never blames the server. A video this device cannot decode says so, and a restart of the
system's media services says so and invites a retry, never "cancelled" or "cannot connect".
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
*Clarified 2026-10-17 (TASK-965):* the artwork is the title's poster, or its backdrop when it has no
poster. A title with neither shows no picture, never the previous title's, and its name, duration and
time still show. When autoplay moves to the next episode, the artwork changes with it.
*Clarified 2026-10-17 (TASK-1011):* a title played from Downloads, or a downloaded copy played from its
own page, shows the same artwork. The poster saved with the download comes first, so the picture shows
offline; with no saved poster, the title's poster or backdrop from the catalog is used.
**FR-059 [STATED]** — Playback Speed lives in Settings, is easy to find, and is easy to set back to
normal. A user must never be stuck playing fast with no way to change it.
**FR-060 [INFERRED]** — The persisted default playback rate is 1x; after a cold start with no explicit
change, playback is at normal speed.
**FR-061 [STATED]** — Subtitle and audio track selection is available in the player; where a language has
both full and forced subtitle variants they are presented as distinguishable, labelled choices.
Every audio track the source carries is offered, with no carve-out: a title with a second language
or a commentary track lists each one in the audio picker, labelled by its title, else its language,
else "Track N", with the source's default track preselected. A single-audio title plays exactly as
before and its picker shows one track. This holds in the iOS and tvOS apps whether they play the
file directly or the server converts it to HLS. The playback response lists the same tracks in its
`audioTracks` array, named and defaulted exactly as the HLS master playlist names them (one source,
the probe), whatever way the title is served. [TASK-1004] The web player never loses a track
either. A single served file gives a browser only one reachable track: the realtime remux it
uses for a file in a non-browser container carries one audio stream, and a file the browser
could play as is plays only its default track, with no way to switch outside Safari. So a web
request for a title with two or more audio tracks is always served as the HLS audio renditions,
the video copied rather than re-encoded when the browser could have played it directly.
[TASK-1003, TASK-1028] The web player then shows an Audio menu listing every track by the same
label, the default ticked, and switching keeps playing; a quality change keeps the chosen track.
A single-audio title is served exactly as before (direct or remux) and shows no Audio menu, since
there is nothing to choose. The apps are unaffected: they still direct play such a file and
offer its tracks themselves. [TASK-1028]
The web player's Quality menu (Auto, 1080p, 720p, 480p) must actually change what is served: it
sends the same quality values the apps send and the server accepts, the whole `p`-suffixed
set, so choosing 720p caps the picture at 720 lines instead of silently staying on Auto. The menu
and the server share one list of values, and a test fails if they drift apart. [TASK-1031]
*Derivation:* design-spec B5 §2/§6 (captions button + picker); competitive research P03; forced/full
split corroborated in scope by TASK-827/828 titles.
**FR-062 [INFERRED]** — A title with no subtitle tracks says so (or disables the control) rather than
showing an unexplained empty list.
**FR-063 [INFERRED]** — Switching audio track continues from approximately the same position rather
than restarting.
Library normalization never costs a title an audio track: a converted file keeps every audio track
of the original, each with its language and title, and a conversion that would drop one is
rejected and the original kept.
**FR-064 [STATED]** — Every player control — skip to start, back 15, play/pause, forward 15, skip to end —
is reachable and activatable with the tvOS remote.
**FR-065 [INFERRED]** — Back 15 / Forward 15 move the position by approximately 15 seconds and clamp
safely at both ends of the runtime.
**FR-066 [STATED]** — On tvOS, Menu closes the controls overlay when it is visible and exits playback
when it is not; Menu is never trapped.
*Clarified 2026-10-18 (TASK-1047):* while the playback-failed screen is up, the player behind it is
inert. Play/Pause, skip, seek, the lock-screen and Control Center transport commands and the VoiceOver
transport actions do nothing; Select and the d-pad stay on Retry and Dismiss; and Menu is Dismiss, with
no earlier press spent on controls that are not on screen.
**FR-067 [STATED]** — Pressing Menu during the next-episode countdown cancels it and does **not** start
the next episode.
**FR-068 [INFERRED]** — A completed countdown starts the correct next episode by season/episode
identity and records the finished episode as watched; the final episode of a show offers no countdown.
**FR-069 [INFERRED]** — A user's own seeking — including repeated seeks on a transcoded stream — never
leaves them unable to continue playing the title.
**FR-070 [INFERRED]** — Double-triggering Play yields exactly one playback session.
*Clarified (TASK-1010):* a shortcut that starts playback (FR-071's list) opens the player once, on
arrival at the title's detail screen. Coming back to that screen (closing the player, going back from
a screen opened from it, switching tabs back) never reopens the player. If playback was unavailable on
arrival, it stays a decision for that visit: the player does not open later when the NAS returns.
Opening the title again from a shortcut auto-plays again.
**FR-071 [STATED]** — With the NAS offline, Play on a non-downloaded title is unavailable up front rather
than failing after the tap. This includes shortcuts that start playback directly (the Home hero's Play,
a Continue Watching card, opening an episode to play): they land on the title's detail screen with Play
unavailable instead of opening the player.

---

## 6. Library (browse, shows, search, sort/filter, watchlist)

**FR-080 [STATED]** — The app lists every library the server exposes, with content organised using the
server's metadata — posters, episode guides, descriptions. The server exposes every library it is configured to scan — Movies, TV Shows and Home Videos — and no library whose folder is not configured. [TASK-985]
**FR-081 [INFERRED]** — Zero libraries, or an empty library, presents as an explanatory empty state;
failure to load presents as an error with retry (instance of FR-001).
**FR-082 [INFERRED]** — All titles in a library are reachable, each exactly once, across pagination
boundaries; the displayed item count matches the server's total. *(Item count display stated in
design-spec B3 §5.)* Identity is the server's id: the client applies no second rule, so distinct ids that
share title, year and runtime (two files of one film) are each a tile. The same id twice is one tile.
**FR-083 [STATED]** — TV content is organised as show → season → episode, with seasons and episodes
matching what the server reports.
**FR-084 [INFERRED]** — A show whose episodes are split across multiple folders/paths on the NAS
appears exactly once, with its episodes merged. On a restricted profile the merge is decided from the episodes that profile can
see, in the show list and the show's seasons and episodes alike, so the detail lists the episodes the
header counted (FRD-002 FR-250). [TASK-924] The DS Video web plane (`TVShow` / `TVShowEpisode`
`list` and `getinfo`) follows the same rule, and its result never depends on database row order. [TASK-995]
The inverse holds too: a folder is ONE show. When a folder holds episodes of more than one show, the
folder takes the name most of its episodes carry, and all of its episodes list under that show, in the
apps and on the web plane alike (one grouping path, `groupEpisodesByShow`); a sequel's own folder is its
own show. Every episode appears in exactly one show. [TASK-999]
**FR-085 [STATED]** — The detail screen shows title, year, runtime, genre, rating, director, cast, and
description. *Derivation:* design-spec B4 §4/§6/§7.
**FR-086 [INFERRED]** — Missing optional metadata is omitted cleanly — never rendered as "null"/"nil" or
an orphaned separator — and **missing artwork must not prevent the detail screen from loading.**
**FR-087 [INFERRED]** — Failed artwork is visually distinguishable from still-loading artwork.
**FR-088 [DESIGN, 2026-09-16, Ryan; reconciled 2026-10-17, TASK-920]** — The server decides what is new.
Just Added shows the newest titles as the server reports them, newest first, at most **16**. A show with
new episodes appears once, as that show, not once per episode. On a restricted profile the rail holds only
titles that profile can see and is not trimmed short (FRD-002 FR-250). Offline, the device's own list of
its newest synced titles stands in, under the same rules. The rail has no watched filter: a title the
profile has started or finished is listed exactly while it is among the newest, online and offline alike
(TASK-986; it also appears in Continue Watching or Recently Watched). The demo library builds its Just Added rail with the same function as the offline list, so it has no watched filter either (TASK-1035). The device's own list is shown only until the server answers, or when the server cannot be reached: a server answer that is empty (a profile whose ceiling hides every new title, a library with nothing added) empties the rail, and the device's list is not put back (TASK-1020). *Derivation:* 0c9b4cd (Ryan: "the server decides
what is new, because it is the one that knows"), superseding design-spec B2's client-side "first 10". The
cap of 16 is what the iPhone and Apple TV apps already request and what the server defaults to. The /web
player sends no `limit` on Just Added or Suggested and takes the server's default for each, so its Just
Added rail is the same 16 as the native apps and the number lives only on the server. [TASK-920]
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
**FR-095 [STATED; AMENDED 2026-10-17, FRD-002]** — A watchlist exists **per profile**, is reachable on iPad,
and appears on the tvOS Home screen; a profile's saved items must be viewable under that profile on every
supported platform. Entries above the profile's age ceiling are hidden, never deleted (FRD-002 FR-207).
**FR-096 [INFERRED]** — Adding to the watchlist increases its count by exactly one for that identity;
removal decreases it by exactly one and leaves other entries intact; both survive relaunch.
**FR-097 [INFERRED]** — An empty watchlist explains how to add titles.
**FR-098 [INFERRED]** — A failed refresh of an already-loaded library keeps the existing content visible
with a refresh-failed indication; it must not wipe the grid to empty. This covers the Libraries list (the
list stays, a "Couldn't refresh" notice with Retry sits above it; the full-screen error is only for a first
load with nothing to keep) and the library grid on iOS and tvOS. The kept grid must still answer what the user
asked for: if the failed load was for a different genre filter or library, the old grid is not shown as that
result, so the error screen applies instead. Offline, an unfiltered grid falls back to the on-device catalog.
**FR-099 [INFERRED]** — Home-video-type libraries are browsable with whatever metadata exists; they are
not hidden and do not break the library view.
**FR-100 [INFERRED]** — Titles with unusual names (quotes, ampersands, non-ASCII, very long) list, open,
and are findable by search. That includes one-character titles ("M", "Z", "1"): as-you-type search waits
for two characters, but an explicit search (the Search key, a recent search, or Siri) runs at any non-empty
length, and a lone character shows a "press Search" hint instead of a blank screen.

**FR-143 [DESIGN, DESTRUCTIVE, 2026-10-17, TASK-933/937]** — *A server scan resolves doubt toward keeping.*
A folder the server cannot read keeps every title already known under it, and the failure is logged with
the folder and the reason. A library whose folder shows no videos at all (for example an unmounted volume)
while titles are known for it deletes nothing; clearing such a library is done by removing it in settings.
One library that fails to scan does not stop the others, and every failed library is reported. Watch
progress for a title that really was removed is kept for 30 days before it is erased, so a folder that
comes back restores its positions. Of the original files kept after a video is converted, the newest 3 are
kept whatever their age; older ones follow the retention window. (Each change narrows a deletion path;
flagged to Ryan.)

**FR-144 [DESIGN, 2026-10-17, TASK-929]** — *Secrets never reach the server log.* Request logging never
records a body. A query string may be logged, but passwords, one-time codes, session ids, tokens and DSM's
trusted-device token are redacted from it, and from any URL, wherever a request is logged.
*Clarified 2026-10-18 (TASK-1048, widened by TASK-1052):* the other direction holds too: every 5xx the
server answers (`server_error`, `db_error`, `tmdb_error`, `ffmpeg_failed`, `image_fetch_failed`, 503s and
the rest) leaves a log line naming the request method and path (never the query string), the status, the
code, the step that failed and the error underneath it, so a failure that reached a device can be traced on
the NAS. That line carries no PIN, password, token, cookie value or PIN hash, including any a library
error echoes back from a request URL. One helper writes every 5xx, so a new failure site cannot forget the
line; a 5xx that still bypasses it (a DSM status passed straight through) leaves one fallback line saying
no cause was recorded. A failure that repeats is not allowed to flood a NAS log: one site writes at most 3
lines per 30 seconds, and the next failure after that window opens first reports how many were suppressed.
**FR-145 [DESIGN, 2026-09-15, TASK-920]** — *Suggested is decided by the server.* The Suggested rail
offers titles that share a genre with what the viewer watched most recently, from one server request, and
leaves out anything the viewer has already started. It never draws on another profile's history, and with
no history it is simply absent rather than filled with guesses. *Derivation:* 0a117a4; DSVideoBackendAPI.md
`/suggested`; FRD-002 FR-250 for the profile ceiling.
**FR-146 [DESIGN, 2026-09-16, TASK-920]** — *The Apple TV Top Shelf gets you back into what you were
watching.* It shows Continue Watching, with resume bars, as widescreen artwork, and falls back to Just Added
when nothing is in progress, so a caught-up viewer still sees content rather than a bare icon. It refreshes
when Continue Watching changes, so a title just finished does not linger. [DESIGN, 2026-10-17, TASK-992]
Refreshing means the app tells tvOS the shelf changed whenever it writes a different shelf or clears one;
tvOS reloads only when told. A rewrite that leaves the shelf as it was tells it nothing. On an account with a restricted
profile, FRD-002 FR-264 narrows this. *Derivation:* 38c6cb5.
**FR-147 [DESIGN, 2026-09-16, TASK-920]** — *Siri can find a title and open it.* App-scoped phrases
resolve against the library. "Play <title> in DSM Video" opens the title's detail page, with Play already
focused. If nothing matches, it opens search with the phrase filled in and says so, rather than failing silently.
"Find <title> in DSM Video" opens search results for the phrase, on iPhone and iPad as well as Apple TV
[DESIGN, 2026-10-17, TASK-993]: iPhone and iPad had no reader for the request, so the app opened and did
nothing. They now show search, over whatever tab is open, with the phrase filled in and the search already run.
The search is an explicit one, so a one-character title ("M") runs; it is not added to recent searches, which
hold only what the viewer typed. A request is acted on once. Neither phrase starts playback [DESIGN, 2026-10-18, TASK-1045, OC-2184]:
Ryan decided a Siri request takes the viewer to the title's detail page and leaves Play to them (resuming from a
voice command, with no position on screen, loses the viewer's place); earlier wording that Siri "plays or resumes"
the title is withdrawn. A bare "play <title>" without the app name is out of reach: that is
an Apple TV-app catalog partnership, not an API. Siri results obey the active profile's ceiling (FRD-002
FR-264). *Derivation:* 542d543.
**FR-148 [DESIGN, 2026-10-17, TASK-959]** — *Every control in the /web player shows when it is pressed,
focused from the keyboard, and disabled.* One shared style covers all buttons (primary, secondary, close,
player menu, next episode, filter chips, sidebar items): a pressed button visibly dips, a keyboard-focused
one draws a clear outline, a disabled one is dimmed with a not-allowed cursor and does not lift on hover.
There is one primary-button look; the Play button is that button, only larger. The sign-in error tint
follows the theme's danger colour in both light and dark. *Derivation:* TRUTHS S2 (every control works and
can be reached). The web player carries the apps' brand red, #D1262F, as its accent in both themes
(decided by Friday for Ryan, 2026-10-17, replacing the earlier blue). The colour is defined once, as
the page's `--brand-red` custom property; the accent tokens (normal, hover, tinted background) and the
logo and avatar gradients all derive from it, so it cannot drift between themes. [TASK-1000, TASK-959 AC4]

---

## 7. Auth (sign in, QuickConnect, pairing, session, sign out)

**FR-110 [STATED]** — Sign-in collects server address (IP **or** QuickConnect ID), username, and password;
successful sign-in reaches library content. *Derivation:* design-spec B1.
*Clarified 2026-10-18 (TASK-1015):* "localhost", with or without a port, is a server address, never a
QuickConnect ID: the app connects to it directly and does not look it up with QuickConnect. A name made
of letters, digits, hyphens and underscores with no dot or port is otherwise read as a QuickConnect ID.
**FR-111 [STATED]** — QuickConnect and direct HTTPS are both supported connection paths, including for
remote access.
*Clarified 2026-10-17 (TASK-1030):* a device that signed in with a QuickConnect ID, or that received one
through pairing, keeps that ID and tries it whenever it connects again: at launch, on reconnect and at
the next sign-in, alongside any home or away address it also knows. Connecting successfully through an
address QuickConnect returned does not replace the ID. The sign-in screen shows the ID, not the address
that answered. Signing in with a direct address instead stops the device from using the old ID.
*Clarified 2026-10-18 (TASK-1053):* looking up a QuickConnect ID through the server is limited like
signing in: ten lookups a minute from one device address, shared with the sign-in and pairing limit, after
which the answer is `rate_limit_exceeded` and the sign-in page says to wait a minute. An ID that is not
letters, digits, hyphens or underscores (at most 64, starting with a letter or digit) is refused as
`invalid_quickconnect_id` without contacting Synology, so the NAS cannot be used to look up arbitrary names.
*Clarified 2026-10-18 (TASK-1056):* the address a video plays from is the address the app is connected
through: on the home network, through the away address, or through QuickConnect, each gets stream links
on that same address, and QuickConnect links are always secure (`https`). The server needs no public
address configured for this, and does not warn that one is missing. A server owner may still pin every
stream link to one address, at the cost of the other connection paths.
**FR-112 [STATED]** — The NAS is discovered automatically on the local network; manual IP entry is not
required.
**FR-113 [INFERRED]** — When nothing is discovered, manual entry remains available and the absence of
discovered servers is not an error.
*Clarified 2026-10-17 (TASK-950):* the search for servers ends. If nothing is found within about eight
seconds, the "looking" indicator stops and the screen says no servers were found; on iPhone it points the
user to the address field, and on Apple TV it says so above the manual sign-in option. It is worded as
information, not as an error. A server that answers later still appears.
**FR-114 [STATED]** — A correct password never displays a stale error from a previous attempt.
**FR-115 [INFERRED]** — Failure causes are distinguished: wrong credentials; unreachable server;
unresolvable QuickConnect ID; account not permitted to use this application; malformed address;
certificate/secure-transport failure (instance of FR-002).
*Clarified 2026-10-17 (TASK-974):* a QuickConnect ID that yields nothing to connect to has three
separate messages, on sign-in and on pairing alike. An ID QuickConnect does not know is named as not
found. An ID that is registered but whose NAS publishes no address says so and points at the
QuickConnect setting in DSM. A lookup that never reached QuickConnect says QuickConnect couldn't be
reached. "Invalid server address" is reserved for input that is neither a parseable address nor
shaped like a QuickConnect ID (letters, digits, hyphens).
*Clarified 2026-10-18 (TASK-1049):* the /web sign-in page follows the same rule. When a QuickConnect ID
cannot be looked up, the page says which of these it is: the DSVideo server it came from could not be
reached, that server could not reach QuickConnect, QuickConnect has no address for the ID, or the answer
was something the page does not recognise (the server's own error code is shown). Each message says what
to do next, and the page never quietly signs in against a guessed "<id>.quickconnect.to" address: that
host is DSM's portal, not DSVideo, and a browser cannot call it from the page. If QuickConnect does return
an address the page cannot sign in to, it says so and points at that address's /dsvideo/ page.
*Clarified 2026-10-17 (TASK-949):* Local Network access turned off for the app is its own cause, named
as such wherever it stops something: the server search, sign-in, and a request mid-session (the banner).
It is never reported as "No network connection" or as the device being offline, because the device's
network works. On iPhone the message offers a way straight to the app's Settings. When the saved
remote address still works, the app keeps using it as for any unreachable local server.
*Clarified 2026-10-17 (TASK-1006):* "wherever it stops something" includes a video that fails to play,
the Apple TV connection indicator, and the message after a watchlist change that could not be saved.
Each names Local Network access, in the same words as iPhone's banner and permission message.
*Note on account permission:* this one is derived from operational project memory rather than from
product copy, and is flagged as such.
**FR-116 [INFERRED]** — Concurrent sign-in attempts yield exactly one session and one definite outcome.
**FR-117 [STATED]** — **Pairing:** a device signs in by entering a short on-screen code shown on an
already-signed-in device; the account and server connection carry over with no password or server
address re-entry. This works in both directions (iOS→tvOS and tvOS→iOS).
*Clarified 2026-10-17 (TASK-972):* the code works on a device that has never connected to any server.
The signed-in device's ways to reach the server (its home address, its away address, its QuickConnect
ID) travel with the code. The new device finds the server on its own local network, redeems the code
there, and keeps both the address that answered and the addresses that came with the code, so it can
reach the server away from home afterwards. First-time pairing therefore needs the new device on the
same network as the server; away from home, a never-connected device signs in with the server address
instead. A device that already has an address uses that address and does not search, so a mistyped
address fails as a mistyped address. If no server is found, the message says so; if Local Network
access is off, it says that (FR-115, TASK-949). A wrong code is reported as a wrong code, never as an
invalid server address (FR-118). On iPhone and iPad the code from a signed-in Apple TV is entered on the
sign-in screen under "Have a code from your Apple TV?"; on Apple TV the code from a signed-in phone is
entered on its sign-in screen. A code is single-use and short-lived, and once 20 wrong codes have been
tried from any devices while codes are outstanding, every outstanding code stops working and a new one must be generated. Codes and
session tokens never appear in logs (FR-144).
**FR-118 [INFERRED]** — A wrong, expired, or already-used code is rejected with a message naming the
code, leaves the device unpaired, creates no partial session, and allows a retry with a fresh code.
**FR-119 [INFERRED]** — A session established by sign-in or pairing survives relaunch; the user is not
asked to re-authenticate after a cold start.
**FR-120 [INFERRED; duration rule 2026-10-17, TASK-973]** — An unreachable server at launch does not sign
the user out and does not report a credentials failure, **however long the outage lasts**. The app keeps
trying to reach the server for as long as it stays unreachable (backing off to a slow cadence after the
first few minutes, and trying again at once whenever the app returns to the foreground). Giving up on
reaching the server never ends the session; only the server rejecting the session (FR-121) does.
**FR-121 [INFERRED]** — An expired or revoked session is reported as a session problem with a path to
re-authenticate — not as the server being offline or the media being unplayable. After re-authenticating,
progress and watchlist are intact.
*Clarified 2026-10-18 (TASK-1013):* the device never decides on its own that a session has expired. A
session that looks expired or close to expiring when the app opens is renewed with the server; if the
server cannot be reached, the user stays signed in with no sign-in message (FR-120). When the server
refuses the session and signing in again with the saved password does not work either, the session ends
with the session-expired message, rather than carrying on with a session the server will not accept.
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
**FR-150 [DESIGN, 2026-10-18, TASK-747]** — *A title's cast shows their photos, and the server remembers who they are.*
On a title's detail page the cast list shows each actor's name, the character they play when it is known,
and their photo. An actor without a photo shows their name with a plain placeholder, never a broken image.
The server keeps each title's cast as an ordered list in billing order, taken from the same TMDb lookup
that supplies the rest of the title's details, so a re-scan or a metadata fix replaces the list rather than
adding to it. Cast from a title that is removed from the library is removed with it.
*Existing libraries:* titles scanned before this change have names only. An administrator can ask the server
to fill in the photos and characters for them (`POST /admin/metadata/refresh?scope=cast`). That run reads
each title's own TMDb record, never searches by title again, so a title whose match was fixed by hand keeps
its match. It asks TMDb once per show or movie, not once per episode, goes slowly so it never competes with
playback or a scan, can be run again at any time, and changes nothing but the cast. A title for which TMDb
lists no usable cast is checked once and then left alone, so repeat runs do not keep asking about it; a
lookup that fails is retried on the next run. Until a title is filled in, its detail page shows the names it
already had, without photos.
*Photos:* a photo is fetched from TMDb by the server the first time someone views it and kept in the image
cache, so the app never contacts anyone but the user's own NAS (S4, A2). The cache has a size limit so
photos cannot fill the NAS disk: 1 GB by default, set with `DSVIDEO_IMAGE_CACHE_MAX_MB` (`0` means no
limit). When the cache is over its limit the least recently viewed images are removed first, down to 90% of
the limit, and an image fetched in the last two minutes is never removed. A removed image is simply fetched
again when next viewed.
*Derivation:* P1 (the cast list shows who is actually in the film, not just names). Ryan, 2026-10-18: show
cast photos on the detail page. [TASK-747]
**FR-149 [DESIGN, 2026-10-18, TASK-1055]** — *The app suggests updating a server that is older than the app
expects.* Each app release names the newest server it is built for (the "recommended" server version, in
the server package's `MAJOR.MINOR.PATCH-BUILD` form, e.g. 0.3.9-0002). After sign-in, and again each time
the app returns to the foreground, while the server is reachable, the app asks the user's own server which
version it is running. If that version is **older** than the recommended one, a notice appears; if it is the
same, newer, or cannot be read (a development build of the server, an empty or missing version), nothing
appears. Versions are compared as numbers field by field, so 0.3.10-0001 is newer than 0.3.9-0002.
*What the notice says:* that a newer server is available; the version the server is on and the recommended
one; that the newer one has fixes and new features; and the steps: download the server package from
heiloprojects.com/dsmvideo, then on the NAS open Package Center, choose Manual Install, and pick the
downloaded file. The wording is for anyone who opens the app, because the app does not know whether the
account is an administrator on a server this old: it adds "if you don't manage the NAS, pass this on to
whoever does." On iPhone and iPad a **Download Update** button opens that page. Apple TV cannot open a
web page, so it shows the short address and a QR code to scan with a phone. Both have **Not Now**.
*Behavior:* the notice never blocks anything; the app keeps working underneath it. **Not Now** is
remembered on this device for the recommended version it was shown for, so it stays away until a later app
release recommends a newer server, and then returns. Signing out clears it. A failed or skipped check
(device offline, server unreachable, demo mode) neither shows nor hides the notice, because not being able
to ask says nothing about the server's version. The recommended version is kept equal to the version the
server package in this repository ships by an automated check, so a server release cannot go out while the
app still recommends the previous one.
*Derivation:* P1 and S2 (honest: the user is told the real reason a newer app and an older server may not
work well together, and given the way to fix it). S4 and A2 hold: the version is read from the user's own
NAS, nothing is sent to anyone else, and the download page is not in the media or credential path.
Ryan, 2026-10-18: "for anyone using the iOS/tvos app. If it detects that their server is not updated, it
suggests downloading the update and installing it." [TASK-1055]
**FR-152 [DESIGN, 2026-10-18, TASK-748]** — *A person with no server is shown how to install one, and the
first connection to a server says what it found.* Three parts.
*(1) Install the server.* The help sheet on the sign-in screen has an **Install the server** topic, and
Settings > Help has the same steps; both read ONE list (download the package from heiloprojects.com/dsmvideo,
install it from Package Center > Manual Install, point it at the Movies and TV folders, note the NAS
address), so they cannot disagree.
*(2) When the install link appears.* A failed sign-in or pairing offers the install help **only when no
DSVideo server answered**: the network was unreachable or timed out, or a host answered but is not DSVideo
Server. It is never offered for a wrong password, a permission refusal (401/403), a Local Network
permission denial, a failed QuickConnect lookup, or a TLS/certificate failure, because in each of those a
server is there or the fix is elsewhere. A host that answers the sign-in request with a bodyless 404 (a
NAS with DSM but no DSVideo Server) says so honestly: "Something answered at this address, but it isn't
DSVideo Server. Is DSVideo Server installed on your NAS?", and it gets the install help. The link is
shown for the error on screen only; a later, different error does not inherit it. On iPhone and iPad the
link opens the download page; Apple TV (sign-in and pairing screens) shows the short address and a QR
code, with no new button.
*(3) First connection.* The first time the user signs in to a server, once the first sync has finished the
app shows "Found N libraries, M videos" (singular when 1; thousands separated) for a few seconds. It is
computed after the sync, so it never delays or blocks sign-in, and the count is only what the active
profile may see (a Teen profile is not told about hidden titles). It appears **once per server**: servers
are told apart by QuickConnect ID when one is used, else by address and port, and a server is marked
as welcomed only when the moment was shown. A server with nothing synced yet shows nothing and stays
pending. Only a sign-in the user started (the Sign In button, or a pairing code) triggers it; a silent
reconnect of an existing install does not. Signing out clears anything pending but not the memory of
servers already welcomed.
*Acceptance:* AC-1 the Install the server topic exists on both screens from one step list and the link is
`RecommendedServer.downloadURL`; AC-2 the link appears for unreachable and not-DSVideo and for nothing
else; AC-3 the moment shows once per server and never blocks sign-in; AC-4 Apple TV sign-in and pairing
show the address and QR code on a no-server-answered failure and every tvOS button keeps `.focused()`;
AC-5 this requirement.
*Derivation:* P1 and S2 (honest: the error names the real cause; a person with no server is shown the
way to get one). Ryan, 2026-10-18 (onboarding gaps found by walking a first-time user through the app).
[TASK-748]

---

## 8. Offline (no server reachable)

**FR-130 [STATED]** — With the NAS unreachable, the app states that the server is offline. It does not sign
the user out and does not report a credentials error.
*Clarified 2026-10-17 (TASK-973, TASK-953):* the server-offline indicator appears as soon as any request
fails to reach the server, from any screen, including a cold start onto cached content. It is not
deferred until a background check notices. It clears as soon as the server answers again. A cancelled
request (for example, the user navigating away) is not an outage and changes nothing.
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
(Realised by the FR-041 mark and dimming; one rule, `DownloadManager.badgeState`, drives every card.)
**FR-135 [INFERRED]** — The Downloads list is truthful offline — it does not require the server to render,
and zero downloads reads as "nothing downloaded", not as a server failure.
**FR-136 [STATED]** — Search offline is a connection error with retry, not "no results".
**FR-137 [INFERRED]** — Offline progress and offline watched/watchlist changes are retained and
reconciled on reconnection, or the user is told at the time that they could not be saved.
Watchlist changes take the second path: a change the NAS does not receive is undone (a removed title
returns to its old place) and a brief message says so, naming the cause (no internet connection, or the
NAS can't be reached).
**FR-138 [INFERRED]** — Cached content, the downloads list, and the signed-in session all survive a cold
start while offline.
**FR-139 [INFERRED]** — On reconnection, retry (or foregrounding) restores live content, clears the
offline indicator, and requires no re-sign-in; items removed from the NAS stop being offered.
**FR-140 [INFERRED]** — A download cannot be started offline; the attempt is refused with the real reason
and leaves no entry claiming to be playable. A transfer interrupted by connectivity loss reports an
interrupted state, never completed.
**FR-141 [INFERRED]** — Every surface reports the offline condition consistently; no screen shows a
success-looking or blank state while another reports offline.
*Clarified 2026-10-17 (TASK-988):* Apple TV shows the same indicator, in the same words as iPhone, over
the top of every screen including detail screens. It never takes focus, and it clears when the server
answers again with no re-sign-in.
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
