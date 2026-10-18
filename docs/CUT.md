# DSVideo — Cut log

Scope that failed the Truth Test against `docs/TRUTHS.md` (Rule 8). Each entry names what was cut, the
verdict, and why. A cut is reversible: Ryan can reinstate any item, and a truth amendment re-tests the list.

| Date | Item | Source | Verdict | Why |
|---|---|---|---|---|
| 2026-10-18 | Playful & Vibrant theme | TASK-763 | CUT | Serves no truth; three themes (Classic, Nitrate, Cinematic) already ship. Needs a paid design pass. |
| 2026-10-18 | Bold & Experimental theme | TASK-764 | CUT | Same as TASK-763. |
| 2026-10-18 | Household presence ("Melissa is 20 min into this") | TASK-749 | CUT | Violates FR-201 [RYAN]: a profile never sees another profile's history. Reinstating needs FR-201 amended. |
| 2026-10-18 | Ambient mode / colour bleed / film grain | TASK-749 | CUT | Styling only; serves no truth. |
| 2026-10-18 | Intro/credits detection by fingerprinting | TASK-749 | CUT | Per-episode audio/frame analysis is heavy NAS CPU (project rule: watch NAS CPU); chapter-title Skip Intro already exists. No FRD. |
| 2026-10-18 | AirPlay queue (AVQueuePlayer) | TASK-749 | CUT | No FRD or AC; single-title AirPlay already works. Serves P1 only marginally. |
| 2026-10-18 | Sprint-mode parallel conversion | TASK-760 | CUT | Parallel ffmpeg on NAS hardware cuts against the CPU/memory rule; the single worker already clears the backlog. Clobber fix already shipped. |
| 2026-10-18 | Configurable library scan schedule | TASK-744 | CUT | No truth asks for it; the 5-minute scan works. |
| 2026-10-18 | Home memory rows (rewatched / never finished / on this day) | TASK-751 | CUT | No FRD, serves no truth; home rails are server-owned (FR-145). |
| 2026-10-18 | Per-genre home rails, TMDb franchise grouping for adults | TASK-751 | CUT (superseded) | FR-145 single Suggested rail; FR-274 limits collections to Kids/Teens (Ryan). |
| 2026-10-18 | Drag a download out to Files (iPad) | TASK-756 | CUT | Leans into A1 (not a file organizer); serves no truth. |
| 2026-10-18 | Loading skeletons | TASK-757 | CUT | Cosmetic; S2's "empty never looks like couldn't load" is already met by separate loading/error/empty states. |
| 2026-10-18 | Progress write coalescing | TASK-744 | CUT | Risks losing watch position (S3); the ticket itself declined it. |
