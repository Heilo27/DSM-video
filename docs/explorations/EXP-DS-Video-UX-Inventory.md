# EXP: DS video (Synology) UX + feature inventory

Date: 2026-01-08

Sources:

- App Store metadata via iTunes lookup: `https://itunes.apple.com/lookup?id=540949418&country=us`
- Downloaded App Store screenshots saved under:
  - `agent/artifacts/ds-video-reference/screenshots/iphone_*.png`
  - `agent/artifacts/ds-video-reference/screenshots/ipad_*.png`

## App Store listing (high-signal fields)

- **Name**: DS video
- **Bundle id**: `com.synology.DSvideo`
- **Seller**: Synology Inc.
- **Latest version**: 3.4.5 (release date 2022-11-15)
- **Minimum OS**: iOS 13.0
- **tvOS screenshots**: Apple metadata does not include `appletvScreenshotUrls` for this app id; we captured tvOS behaviors via third-party references instead (see “tvOS notes” below).
- **Description excerpt** (as listed): requires a Synology NAS and Video Station 2.3.0; streams video collection; videos sorted into libraries; pulls movie info online; can record TV programs when paired with compatible hardware.
- **Release notes (3.4.5)**:
  - Login page device list issue on iOS 16
  - Playback via third-party players issue
  - Minor fixes

## Screen inventory (from App Store screenshots)

### Login (iPhone)
Screenshot: `agent/artifacts/ds-video-reference/screenshots/iphone_1.png`

- **Branding**: solid red background, centered “DS video”
- **Fields**:
  - Server identifier field (appears to accept hostname / QuickConnect-like id). Right-side blue circular arrow/button suggests device discovery/selection.
  - Username field
  - Password field
- **Toggles**:
  - `HTTPS` (off by default in screenshot)
  - `Remember me` (on in screenshot)
- **Primary action**: large rounded `Login` button
- **Footer actions**:
  - Left: gear icon (settings)
  - Center: “Downloaded Videos”
  - Right: info icon

### Login (iPad)
Screenshot: `agent/artifacts/ds-video-reference/screenshots/ipad_1.png`

- Same red background + centered “DS video”
- A small centered credential card with fields/toggles
- A circular arrow button to submit/login sits to the right of the card
- Footer: gear icon (left), “Downloaded Videos” (center), info icon (right)

### “Just Added / Just Recorded” item view (iPhone/iPad)
Screenshots:
- `iphone_2.png` (“Just Recorded” title)
- `ipad_2.png` (“Just Added” title)

Observed UI elements:

- Top-left shows the current list context (“Just Added” / “Just Recorded”)
- A poster/thumb card with a play overlay icon
- Title + a timestamp-like date string
- Duration shown with a clock icon
- Star rating row (empty stars in screenshot)
- An action row with icons (as seen on iPad screenshot): list, heart, bookmark, share
- iPad top-right includes several action icons (likely download/share/playlist style actions)

### Player (iPhone)
Screenshots:
- `iphone_3.png` (paused player, preview frame centered with black letterboxing)
- `iphone_4.png` (overlay controls on top of video)

Observed playback UI:

- Top-left: close (X) and the title
- Top-right: gear icon (player settings)
- Center: play icon when paused
- Bottom: scrubber with **red progress**; elapsed/remaining shown near the scrubber
- Controls overlay fades on top of video content

### Player (iPad)
Screenshots:
- `ipad_3.png` and `ipad_4.png` (playback UI)
- `ipad_5.png` (gesture tutorial overlay)

Observed playback UI:

- Same close (X) + title, gear icon
- Bottom scrubber (red progress)
- Additional audio control: visible volume slider on the right (in screenshot)
- Gesture tutorial overlay indicates:
  - Pinch in/stretch out: adjust subtitle size
  - Swipe left/right: seek
  - Swipe up/down: volume

## Feature inventory (inferred / confirmed by listing + typical DS video usage)

Confirmed by listing text (App Store metadata):
- Stream video collection from Synology NAS
- Library organization by categories (“libraries”)
- Online metadata retrieval (movie info/art)
- TV recording workflows when paired with supported tuners (legacy Video Station feature)

Common DS video expectations (to be validated with additional research during implementation):
- Movies / TV Shows / Home Videos library segmentation
- Sorting + filtering
- Search
- Resume/continue watching across devices
- Subtitle selection (embedded/external)
- Audio track selection
- AirPlay support
- Downloads/offline viewing (shown in UI entry point “Downloaded Videos”)

## Implications for our clone

- **UX direction**: DS video uses a **simple, high-contrast** UI with strong brand color on login and a **minimal** player chrome.
- **Playback**: we should implement subtitle controls and gesture shortcuts on iPad (and tvOS equivalents via remote gestures).
- **Offline**: “Downloaded Videos” is user-facing; we should include offline download management in v1 (even if initially limited to iPhone/iPad only).

## tvOS notes (no official screenshot set found)

We did not find an official tvOS screenshot set via Apple metadata for the DS video iOS app id. For tvOS parity we’ll lean on:

- Synology marketing/spec pages for Video Station/DS video feature set (resume, subtitles, audio tracks).
- A third-party walkthrough video: “Synology NAS Tip - Installing and Configuring DS Video on to an Apple TV” (`https://www.youtube.com/watch?v=z9K_DnkxQvg`)
