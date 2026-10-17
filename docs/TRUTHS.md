# DSVideo — Thematic Truths

**Status:** DRAFT, derived 2026-10-17 by Geordi (TASK-914) from `docs/frd/FRD-000-mission.md` (Ryan, 2026-09-12).
**Awaiting:** Ryan's one-pass confirmation, plus a ruling on the pending escalation below.
**Doctrine:** `~/.claude/skills/build-app/THEMATIC-TRUTHS.md`. Every FRD opens with a Truth Test against this file.

Nothing here is new intent. Each truth cites the FRD-000 line it was lifted from. Where FRD-000 is silent,
this file is silent too, and the gap is surfaced rather than filled.

---

## Primary truth

**P1. Every movie and show on the user's Synology NAS is findable and plays at the best quality the device
and link can carry, on iPhone, iPad and Apple TV, at home or away.**

Source: the mission quote, M1 (find and accept), M4 (best quality), M5 (LAN and WAN).
Falsifier: if users mostly watch a small, hand-picked subset and never browse or search the whole library,
"every title findable" is the wrong bar and the primary should narrow to curation.

## Secondary truths

**S1. The server is the single source of truth.** Library, metadata, watch position and watchlist live on
the server; no client invents state another client cannot see.
→ serves P1: "plays on iPhone, iPad and Apple TV" only works as one product if the TV resumes where the
phone stopped. Source: M3.
Falsifier: if a client feature routinely needs state the server cannot hold (for example, device-only
playback state the user expects to roam), the boundary is wrong.

**S2. Beautiful, easy, and honest.** Every control works and can be reached; every error names its real
cause; "nothing here" never looks like "couldn't load".
→ serves P1: a title that is findable in theory but behind a dead control or a lying error is not findable.
Source: M4, standard of done 2.
Falsifier: if users accept vague errors without slower diagnosis or more support load, the honesty bar is
over-built (no evidence of this so far; the project's history says the opposite).

**S3. The user's data survives.** A watch position, a download, or a library the user can see never
silently disappears. A failure to read state is never proof the state is worthless.
→ serves P1: a resume point or download that evaporates turns "plays" into "starts over".
Source: standard of done 1.
Falsifier: if a deliberate purge (for example, sign-out removing downloads, FRD-000 open decision 3) is what
users actually want, the "never" needs a stated exception.

**S4. Private by design.** Media and credentials travel only between the user's devices and their NAS.
Credentials never go in the clear; convenience of connection never outranks the password.
→ serves P1: "at home or away" is only acceptable if away is safe.
Source: M5 final bullet, FRD-001 FR-123.
Falsifier: if a feature the user wants can only work through a third-party relay we operate, this truth and
that feature collide, and Ryan decides.

**S5. Optional profiles inside one account.** Every DSM user with permission already has their own
account and library view. Profiles subdivide a single account: any account may add up to four, each with
its own history and age ceiling, typically so kids can use the shared Apple TV safely. The account holder
decides what each profile can see. Profiles are optional; an account without them works exactly as before.
Source: Ryan, 2026-10-17.
→ serves P1: on a shared Apple TV, "plays and resumes" is only true per person, and a kid can only
"find" the library if what they find is appropriate.
Falsifier: if profiles start being used in place of separate DSM accounts (separate people needing their
own permissions or credentials), that is A4 territory and goes to Ryan, not into a quiet extension.

## Anti-truths

**A1. Not a file organizer.** The app adapts to the folders that exist. It never requires the user to
rename, re-tag or move anything to be found. Source: M1 ("the user does not reorganise their files").
Kills: "just put your shows in Show/Season NN/ and it will work."

**A2. Not a cloud service.** No servers of ours in the media or credential path, no hosted accounts, no
external runtime dependencies on the NAS. TMDb metadata lookups are the one outbound call, and they carry
no user media. Source: FR-123 "media does not pass through third-party servers"; project CLAUDE.md
"No external runtime deps; bundle everything."
Kills: cloud sync of progress, hosted watch history, server-side analytics.

**A3. Not a content acquirer.** The library is what is on the NAS. The app does not download, buy, record
or request content from anywhere. Source: mission, "find and accept movies and shows on my Synology NAS."
Kills: torrent/*arr integration, "add this trailer to my library", DVR.

**A4. Not a second login system.** Signing in is always the user's DSM account (directly, or carried over by
pairing). The app never creates credentials that grant server access on their own. Source: FRD-001 FR-110,
FR-117; API "Log in using DSM credentials"; M5 credential posture.
Kills: app-local usernames/passwords, guest logins without a DSM account, shareable access links.
Note: a lock inside an already-authenticated DSM session (for example, a profile PIN) does not grant
server access and is not a login. That reading is applied in FRD-002 and is part of what Ryan is asked to
confirm.

---

## Pending escalation (Ryan's call)

- (none open)

## Amendment log

- **2026-10-17 · Ryan · S5 added and corrected.** Ryan: "it's still for my account. but on apple TV, my kids
  use the app too, and creating a kid friendly profile makes sense." Then: "anyone with an account on my
  synology NAS, and given permissions, can view the movies and shows on their devices. so we are
  multi-user already. but this is still just my single account and adding optional profiles." The product
  is already multi-user, one DSM account per person. S5 adds optional profiles inside one account; it is
  not a new account or permission system (A4 holds). The FRD-002 Truth Test verdict moves from ESCALATE to
  KEEP. This makes five secondaries, one over the cap of four. Ryan was not asked to merge any, so none
  were merged.
