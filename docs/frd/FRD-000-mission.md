# FRD-000 — Mission

**Status:** Authoritative. Stated by Ryan, 2026-09-12.
**Precedence:** This document governs. Where any other FRD, design doc, diagnostic report, or code
comment disagrees with it, this wins and the other is wrong.

---

## The mission, in Ryan's words

> It needs to find and accept movies and shows on my Synology NAS, be able to organize, search, and
> add details about the videos. That server needs to interact with both iOS/iPadOS and tvOS apps to
> display and stream those videos in the best quality possible with a beautiful and easy to use UX.
>
> The mobile apps need to be able to use the Synology QuickConnect architecture to interface with the
> server remotely on WAN as well as on LAN and seamlessly switch between the two.

---

## What that decomposes into

Five obligations. Everything the product does serves one of these; anything that serves none of them
is scope to question.

### M1 — Find and accept the library
Discover movies and shows already on the NAS, on the user's own terms. The user does not reorganise
their files for this app; the app reads what is there.
- A title the user can see in Synology's own file browser must be findable in this app.
- A show whose episodes span more than one folder is ONE show. (This is a recurring defect area —
  see FRD-001 §6 and TASK-900.)
- Accepting the library must not require the user to re-tag, rename, or move anything.

### M2 — Organize, search, and enrich
- Browse by library, by show, by season.
- Search the WHOLE library from anywhere, not one section at a time.
- Add and correct details: metadata the scanner got wrong must be fixable by the user
  (the metadata-fixer surface), not a permanent error.
- Sort and filter in ways that reflect what the user is actually looking for.

### M3 — Serve both platforms from one server
One backend, two clients: iOS/iPadOS and tvOS. The server is the single source of truth about the
library; neither client invents state the other cannot see.
- Watch position set on the phone is the position the TV resumes from, and vice versa.
- A feature present on one platform is not silently absent on the other without a stated reason.
  (iPad specifically is a first-class target, not a stretched phone.)

### M4 — Best quality possible, beautifully
- Direct-play when the file already plays; transcode only when it must. The goal is the best picture
  the device and the link can carry, not the most convenient thing to serve.
- "Beautiful and easy to use" is a REQUIREMENT, not a nice-to-have. A correct app that is ugly or
  confusing has failed this mission statement.
- Which means: a control that exists must work and must be reachable (dead controls are mission
  failures, not polish items); an error message must name the real cause; an empty screen must
  distinguish "nothing here" from "couldn't load".

**Reachability is part of "works."** A control that renders, is enabled, and cannot be tapped is a
dead control — the keyboard covering the only way to submit a filled-in form is the same failure as a
button with an empty action (TASK-906). Every screen that takes text input owes the user a way to
reach its primary action without knowing a keyboard shortcut.

**"Names the real cause" includes failures that happen before the network.** An OS-level refusal to
send a request is not an unreachable server, and must not be reported as one (TASK-907).

### M5 — LAN and WAN, seamlessly, via QuickConnect
This is the requirement no product surface ever stated, and it is core.
- Connect on the LAN when home, over WAN when away, using Synology's QuickConnect architecture —
  including the relay path when direct WAN is not available.
- **Switch between them seamlessly.** The user does not choose a mode, does not re-enter an address,
  and ideally does not notice. Leaving the house mid-episode is a supported scenario.
- Credentials are never sent in the clear to reach this goal. Convenience of connection never
  outranks the safety of the password. (See TASK-892.)

---

## The standard of done

Derived from the mission, these are the lines a change must not cross. They exist because each has
been crossed at least once in this project's history.

1. **The user's data survives.** A watch position, a download, or a library the user sees must not
   silently disappear. A failure to READ local state is never evidence that the state is worthless.
2. **Nothing lies to the user.** Not a control that does nothing, not an error that blames the wrong
   cause, not an empty state that means a failed fetch, not a "downloaded" badge on a file that will
   not play.
3. **Both platforms, or say so.** A feature shipped on one and broken on the other is not shipped.
4. **The remote path is as real as the local one.** A feature that only works on the LAN has met half
   the mission.

---

## Open decisions — Ryan's call, not inferable

Spock's blind reconstruction (FRD-001 §9) identified five questions no product surface could settle.
The mission statement settles none of them, so they remain open. They are recorded here because each
is currently an *assumption in code* rather than a decision:

| # | Question | Current code behavior | Needs |
|---|---|---|---|
| 1 | At what elapsed fraction is a title "in progress" vs "watched"? | `PlaybackProgress.isFinished`: a watched ratio OR inside the final 90s | Ryan's numbers |
| 2 | Is a chosen subtitle/audio track remembered per title, per show, or not at all? | Inconsistent | A ruling |
| 3 | Does signing out delete downloaded media? | Yes — `clearAll()` purges (TASK-807, cross-user residue) | Confirm this is intended |
| 4 | Does season expansion persist across launches? | Yes, since f3f061d | Confirm |
| 5 | Download quality selection / wifi-only downloads | Wifi-only exists (`dsReel.downloadsWifiOnly`, default on); quality selection does not | Is quality selection wanted? |

Item 3 is the one worth a deliberate answer: it is a destructive behavior, and the mission's
"user's data survives" standard and its "no cross-user residue" security posture point in opposite
directions. Today the security posture wins. That may well be right — but it should be a decision on
the record, not an artifact.

---

## How this document is used

- The blind oracle (build-app Phase 7.5, retrofit R1) authors pass criteria from the FRDs. This one
  sits above the others: a requirement that contradicts the mission is a spec bug.
- Per Rule 7 (spec moves with the code), a deliberate behavior change updates its FRD in the same
  commit. A change that alters one of M1–M5 updates THIS file, and is flagged to Ryan in the report.
- FRD-001 is a *reconstruction* derived from product surfaces. This file is *stated intent*. When they
  disagree, this one is right.
