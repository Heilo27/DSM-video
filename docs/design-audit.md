# DS Reel — Design Audit

**Date:** 2026-03-15
**Auditor:** Lumen
**Scope:** iOS, macOS, tvOS — all screens
**Standards applied:** Apple HIG (iOS 17/18), WCAG 2.1 AA

---

## Overall Grade: C+

The app has a functional, clean dark theme and a consistent component vocabulary (poster cells, backdrop headers, metadata pills). The foundation is solid. However, it falls short of premium video app standards in several areas: the design system is embryonic (single brand color, no token system), information density is low, and multiple screens are missing expected features that users of apps like Infuse, Plex, or Emby take for granted.

---

## Design System Assessment

### Brand Color
```swift
DSReelBrandColor.background = Color(red: 0.82, green: 0.15, blue: 0.19)  // ~#D1262F
```

**Issues:**
- Only one token exists. The name `.background` is semantically wrong — it's used as an accent/action color, not a background color. On `LoginView` it IS used as a background, but everywhere else it is a button fill or tint.
- No surface hierarchy tokens: no `surface`, `surfaceElevated`, `divider`, `textPrimary`, `textSecondary`, `textTertiary`.
- All colors are hardcoded throughout: `Color(white: 0.06)`, `Color(white: 0.08)`, `Color(white: 0.10)`, `Color(white: 0.14)`, `Color(white: 0.16)`. These are scattered and inconsistent — the same semantic role (e.g., "button background") uses different literal values in different files.
- `CircularProgressView` in TVShowDetailView.swift hardcodes the brand color as a raw `Color(red: 0.82, green: 0.15, blue: 0.19)` instead of using `DSReelBrandColor.background`. This means any brand color change would silently miss this component.

**Recommendation:** Expand design tokens to at minimum:
- `DSReelBrandColor.accent` (rename from `.background`)
- `DSReelBrandColor.surface` (e.g. `Color(white: 0.10)`)
- `DSReelBrandColor.surfaceHigh` (e.g. `Color(white: 0.16)`)
- `DSReelBrandColor.textPrimary`, `textSecondary`, `textTertiary`

### Typography
No custom font. Uses SF Pro (system font) throughout. This is acceptable but results in a generic feel. No type scale is defined — font sizes are selected ad hoc at each call site.

### Spacing
No spacing token system. Margin values of 8, 12, 16, 24, 32, 48 appear inconsistently without rationale. A 4pt or 8pt grid would bring coherence.

---

## Screen-by-Screen Findings

---

### Screen 1: Login (iOS/macOS)

**Strengths:**
- Clean centered layout on brand red background.
- Text fields grouped in a white card with divider separators — familiar, unambiguous.
- `minHeight: 44` on fields meets the HIG 44pt touch target minimum.
- Capsule-shaped login button with full width and 52pt height is prominent and easy to tap.
- `accessibilityLabel` present on the QuickConnect button.
- Loading state replaces button label with `ProgressView` — correct behavior.
- Error message shown inline below the button.
- `Remember me` and `HTTPS` toggles — practical for a NAS app.

**Weaknesses:**
1. **No app icon or logo mark.** The app is identified only by the text "DS Reel" in `.semibold` at 40pt. Premium apps use a logomark or wordmark with a symbol. The system symbol `play.rectangle.fill` used in `AboutView` could anchor a logo treatment on the login screen.
2. **Title typography is weak.** `system(size: 40, weight: .semibold, design: .default)` with no letter-spacing or custom styling. No subtitle or tagline.
3. **Bottom toolbar cluttered.** Settings gear, "Downloaded Videos" text link, and info button sit in an `HStack` at the bottom. These are three visually different affordances with no consistent styling. "Downloaded Videos" is a text-only button — it does not look tappable.
4. **`showSettings` is unreachable.** Settings is also available in the main tab bar after login. Offering it before login (bottom-left gear) is potentially confusing.
5. **Toggle labels are 75% opacity.** `foregroundStyle(.white.opacity(0.75))` on toggle labels can fail WCAG AA contrast ratios against the brand red background (needs verification; likely fails at smaller sizes).
6. **No "Forgot password" consideration.** Not a native app concern per se, but no explanation of what credentials are (DSM username, not a DS Reel account) could confuse new users.
7. **QuickConnect button** (`arrow.right.circle.fill`) is visually disconnected from its field — a user might not associate it with the "Server or QuickConnect ID" input.

---

### Screen 2: QuickConnect Sheet

**Strengths:**
- Uses standard `Form` with section headers and footers — appropriate for settings-type data entry.
- Lock icon with green/orange coloring for encrypted/unencrypted — good visual differentiation.
- Loading overlay (`ProgressView` with material background) is polished.

**Weaknesses:**
1. **Server list shows raw URLs** (e.g. `http://192.168.1.100:5000`) with no friendly hostname resolution. A user who set up QuickConnect on `mynas` sees `http://192.168.1.100:5000` with no friendly label. The NAS hostname (`server["name"]` if available) could be shown.
2. **Error state uses red `Label`** inside a `Section` — the red feels alarming for a "not found" error. Should be a neutral informational tone with actionable copy.
3. **"Find" button** placement (top-right toolbar) is non-obvious for an action that the user might expect as a button below the field.

---

### Screen 3: Libraries (iOS)

**Strengths:**
- `ContentUnavailableView` used for error and loading — correct.
- `.refreshable` for pull-to-refresh.
- Library type icons (`tv`, `film`, `house`, `play.rectangle`) — clear differentiation.

**Weaknesses:**
1. **Plain list, zero visual richness.** A list of three text labels with SF symbols is the entry point to the app's content. There is no imagery, no preview thumbnails, no item counts, no last-watched metadata. Plex/Infuse show library artwork or thumbnails in the library list.
2. **No empty state for zero libraries.** If the API returns an empty library list with no error, the view shows an empty `List` with no message. `ContentUnavailableView("No Libraries", ...)` is needed.
3. **No sort/filter.** Not critical at library level (usually 2–5 items) but should be noted.
4. **Navigation title "Libraries" is generic.** Could be "DS Reel" at the top level with a user-visible greeting or NAS name.

---

### Screen 4: Library Home ("Just Added")

**Weaknesses:**
1. **Name mismatch.** The tab is labeled "Home" (with `play.rectangle` icon) but the view title is "Just Added". Users expect "Home" to mean a curated landing page (Continue Watching + Just Added + Recently Viewed). This view just shows the first library's items with no curation.
2. **No "Continue Watching" section** on iOS home. The tvOS home has it; iOS home does not. This is the single most valuable feature of a video app and it's absent from the iOS home tab.
3. **No personalization.** No greeting, no NAS name, no user-specific context.

---

### Screen 5: Items Grid (Movies/Videos Library)

**Strengths:**
- Adaptive grid (`minimum: 140`) is appropriate for iOS.
- Poster cell design is clean: gradient overlay, title + year in footer.
- `accessibilityLabel` includes watched percentage.
- `.refreshable` present.
- Watch progress bar using brand accent color is present.

**Weaknesses:**
1. **Progress bar render bug.** The progress bar for watched items uses an `offset(y: height)` hack to position below the poster card, placing it outside the card's clip boundary. This means the progress bar is clipped by whatever contains the `GeometryReader`. On many layouts it will be invisible. Progress should be rendered inside the ZStack, pinned to the card bottom (like the tvOS `TVPosterCard` implementation, which correctly uses a `VStack(spacing: 0)` with a `ProgressView` inside the ZStack).
2. **No sort or filter controls.** Users cannot sort by year, rating, title, or date added. Cannot filter by genre. This is table-stakes for a video library app.
3. **No "watched" / "unwatched" badge.** No visual indicator distinguishes fully watched items from unwatched, beyond the partially-filled progress bar (which is absent for unwatched and invisible for fully-watched).
4. **Cell footer text is too small.** `.footnote.weight(.semibold)` for the title and `.caption2` for the year at 140pt cell width are on the edge of legibility. At 140pt width the title is ~124pt wide, giving roughly 8-9 characters of display space for `.footnote` text.
5. **Pagination loads all items at once.** The code paginates through the full library (up to unlimited items) and holds them all in memory. For large libraries (500+ movies) this is a noticeable delay and memory concern. The UI shows no progress during pagination beyond a single `ProgressView`.
6. **No empty grid state.** If a library has no items, an empty `ScrollView` is shown with no message.

---

### Screen 6: Item Detail (Movie/Episode)

**Strengths:**
- Backdrop hero header with gradient fade — cinematic, appropriate for a video app.
- Title + year overlay on the gradient — readable with text shadow.
- Metadata pills (year, rating, genres) in horizontal scroll — compact, elegant.
- Play button with brand color + shadow — prominent CTA.
- Download section with all three states (idle, downloading with progress, downloaded) is well-implemented.
- Cast list is present.
- Resume position is fetched and passed to the player.
- Error state in header uses `ContentUnavailableView`.

**Weaknesses:**
1. **Header height is only 230pt on iOS.** This is tight for a full-bleed cinematic hero. Netflix/Plex/Infuse use ~300–350pt. The transition from header to content feels abrupt.
2. **Backdrop fallback uses poster image (portrait).** When no backdrop is available, the code uses `detail.images.poster.id` as the backdrop — a portrait 2:3 poster stretched/cropped into a 16:9 landscape frame. This looks terrible for most movies. A solid color with the movie title and a subtle texture would be preferable.
3. **No runtime / director / writer.** Common fields in a video detail view. The metadata pills show year, rating, genres — but no runtime despite the fact that `durationSeconds` is available on `ItemSummary` (though not confirmed on `ItemDetail`).
4. **Cast section is a plain list.** No avatar images, no role categorization (cast vs crew), plain `.footnote` rows. A horizontal scroll with profile photos (if available) would be significantly better.
5. **No rating display.** If TMDb metadata is configured, the rating score could be shown.
6. **"Play (Downloaded)" label is verbose.** The play button label switches to "Play (Downloaded)" when offline. This is functional but not elegant — a small badge or offline icon would be cleaner.
7. **Download button uses generic dark gray** (`Color(white: 0.14)`) — no visual connection to the brand. On tvOS the download button is hidden (iOS-only) which is correct, but the button visual hierarchy could be stronger.
8. **No share / add-to-watchlist actions.** These are expected in any premium video app.
9. **Loading state is minimal.** While loading, the header shows a solid black rectangle with centered `ProgressView`. A skeleton/shimmer would feel less jarring.

---

### Screen 7: Gesture Video Player

**Strengths:**
- Custom gesture layer (swipe-to-scrub, side-swipe for volume/brightness) is a premium feature — matches VLC/Infuse behavior.
- Scrub preview overlay (large time + delta) is excellent.
- Volume and brightness indicators with `ultraThinMaterial` — polished.
- Skip animation bubbles with direction indicator — good feedback.
- Controls auto-hide after 2.5s.
- Landscape lock on iOS with restoration on dismiss.
- Progress sync debouncing (10s interval, 15s seek threshold) — smart.
- Accessibility actions for gesture-based controls are present.
- Playback speed menu (0.5x–2.0x) — valuable feature.

**Weaknesses:**
1. **No subtitle/audio track selection.** No way to change audio language or enable subtitles. This is a critical missing feature for any video app with multi-language content.
2. **No AirPlay button.** Users expect to AirPlay to Apple TV. The route picker (`AVRoutePickerView`) is absent from the player controls.
3. **No Picture-in-Picture (PiP) support.** Standard expectation for iOS video players.
4. **xmark button top-left does not animate.** Dismissal is instant. A fade or slide-down transition would feel more native.
5. **Controls show a duplicate play/pause button.** There is a large centered play/pause button (50pt icon) AND a second play/pause button in the bottom control strip. The center button is not needed when controls are visible — this is visual redundancy.
6. **No chapter/next episode support.** No way to skip to next episode in a TV show season.
7. **Progress bar slider thumb is not shown.** The iOS `Slider` uses `.tint(.white)` but no custom thumb styling. The default thumb is tiny against the full-width scrub area; it doesn't communicate "draggable" clearly.
8. **tvOS player is read-only.** The tvOS progress bar is a visual-only `Capsule` — not interactive. Scrubbing via swipe gesture is not implemented for tvOS remote.
9. **Controls auto-hide in 2.5s even when paused.** Controls should remain visible indefinitely when paused. The code correctly cancels the task on pause (line 603) but only for the explicit toggle — not all pause sources.

---

### Screen 8: Search

**Strengths:**
- `ContentUnavailableView` for pre-search, no-results, and searching states — correct usage.
- Results use the same poster cell design as the grid — visual consistency.
- Black background aligns with the dark theme.

**Weaknesses:**
1. **Search requires explicit submit.** Search only fires on `.onSubmit(of: .search)` — the keyboard's "Search" button. There is no search-as-you-type or debounced live search. Users who expect results to appear while typing will be confused.
2. **No search filters.** Cannot filter by year, genre, library, or content type (movie vs episode).
3. **No search history.** Recent searches are not persisted.
4. **Searching state shows bare `ProgressView` at 60pt offset.** A skeleton grid would be more informative.
5. **Error state is silently discarded.** On search failure, `results = []` and `hasSearched = true` — the view shows "No Results" even on network error. The error is not surfaced.

---

### Screen 9: Downloads

**Strengths:**
- Same poster cell design as the main grid — consistency.
- Context menu for deletion — standard interaction pattern.
- Empty state with `ContentUnavailableView` — correct.
- File size shown as subtitle — useful.

**Weaknesses:**
1. **No download progress visible on the Downloads tab.** Active downloads appear in `ItemDetailView` but there is no indication in the Downloads tab that something is downloading. Infuse/Plex show download progress on the cell.
2. **No sort order.** Downloads are shown in whatever order the file system or `DownloadManager` returns them — no title/date/size sort.
3. **Deletion requires context menu.** On a content browser, context menus are the right pattern — but a swipe-to-delete would be more discoverable.
4. **No total storage usage indicator.** No summary of how much device storage is used by downloads.
5. **`.onAppear` only.** Downloads list only refreshes when the view appears. No live updating during a download.

---

### Screen 10: Settings

**Strengths:**
- Standard `Form` layout — correct for settings.
- Server URL and HTTPS toggle in same section — logical grouping.
- TMDb API key instructions are thorough and link to the website.
- Visual confirmation (green checkmark) when API key is configured.
- Destructive logout button with `.role = .destructive` styling.

**Weaknesses:**
1. **Server URL is shown as plain `Text`.** The base URL `appState.baseURL` is rendered with `Text(appState.baseURL)` — no monospace font, no copy affordance, no visual distinction from regular content text. It looks like a label, not data.
2. **No ability to change server URL from Settings.** The user can only change the server URL by logging out and going back to the login screen. Settings should allow editing the base URL directly.
3. **HTTPS toggle is redundant here.** The toggle exists in both LoginView and SettingsView. If the server URL is `https://...` the toggle shouldn't be editable — it should reflect the protocol of the configured URL.
4. **No app version in Settings.** The version is only visible in `AboutView` (accessible from login screen). After logging in, there's no way to check the version without logging out.
5. **No HLS/streaming quality setting.** No option to cap streaming bitrate for slower connections.
6. **No haptic feedback setting.** Player gestures could benefit from haptic confirmation.

---

### Screen 11: About

**Weaknesses:**
1. **Blue `play.rectangle.fill` icon.** The About screen uses a generic blue SF Symbol as the app icon. This has zero brand identity. It should use the brand red at minimum, or an actual app icon asset.
2. **Only accessible from Login screen.** After logging in, the About view is not reachable without logging out. It should be in Settings.
3. **Minimal content.** Version + one-line description. Could include: open source licenses, credits, changelog link, privacy policy link.

---

### Screen 12: TV Shows Grid (iOS)

**Strengths:**
- Consistent with movies grid — same cell design, adaptive columns.
- Season/episode count as subtitle on cells — informative.
- `.refreshable` present.

**Weaknesses:**
1. Same issues as Items Grid: no sort/filter, no watched status badge.
2. **Season count vs episode count logic inconsistency.** For single-season shows, the subtitle shows episode count ("10 episodes"). For multi-season shows it shows season count ("3 seasons"). While logical, this means two shows side-by-side can show incomparable metadata.

---

### Screen 13: TV Show Detail / Season Viewer

**Strengths:**
- Collapsible seasons with chevron indicator — good for shows with many seasons.
- Episode rows with number badge, title, duration, and circular progress indicator.
- Correct inline loading per season section (lazy-loaded episodes).
- `divider` between episodes — clean separation.

**Weaknesses:**
1. **Header uses poster image (portrait) in a landscape/wide frame.** Same issue as ItemDetailView — portrait poster is cropped into a landscape header. Shows like Breaking Bad with a recognizable landscape backdrop look correct; shows with only portrait posters look bad.
2. **No episode thumbnail images.** Episodes rows show only text and a progress circle. Episode thumbnails (if available from the API) would make scanning much easier.
3. **No "Play Next Episode" button.** The show detail page has no smart play button. The user must navigate to the correct season, find the right episode, and tap it. A "Continue Watching S02E03" button at the top would be premium.
4. **Season header touch target.** The collapsible season header button uses `.padding(.vertical, 12)` — 12pt vertical padding is at the minimum for comfortable tapping. Should be 16pt minimum.
5. **Silent episode load failure.** If episode loading fails, there is no error shown (`// silent failure` in code). The section appears empty with no explanation.
6. **Circular progress view hardcodes brand color.** `CircularProgressView` uses raw `Color(red: 0.82, green: 0.15, blue: 0.19)` instead of `DSReelBrandColor.background`.

---

### Screen 14: Apple TV Pairing (iOS)

**Strengths:**
- Clear instructions with monospaced input field.
- QR code scanner option with the camera — reduces friction.
- 6-digit validation before enabling the Pair button.

**Weaknesses:**
1. **"Scan QR Code" button uses `.bordered` style** while the primary "Pair" button uses `.borderedProminent`. The visual hierarchy between the two actions (primary + secondary) is correct but the divider between them is overly dramatic — a simple spacing gap would suffice.
2. **No illustration or visual.** An Apple TV icon or diagram showing where to find the pairing code on screen would reduce support burden.
3. **Error message placement.** Error text appears above the Pair button, between the text field and the button. This creates a layout shift when errors appear.

---

### Screen 15: tvOS Login

**Strengths:**
- Correct tvOS sizing (66pt field height, 600pt max width, 60pt padding).
- `.borderedProminent` button style — correct for tvOS.
- Disabled state checks for empty fields.

**Weaknesses:**
1. **No QuickConnect support on tvOS.** The iOS login has a QuickConnect button; tvOS requires manually typing the full server IP. This is painful on a tvOS remote.
2. **Field styling is `white.opacity(0.15)` background** — fields are nearly invisible on the dark red background. Should use `.regularMaterial` or a higher opacity.
3. **Inconsistency with iOS login:** iOS has HTTPS toggle and Remember Me; tvOS has neither. Settings persistence on tvOS is handled differently and the lack of "remember me" means re-entering credentials after app updates.

---

### Screen 16: tvOS Home

**Strengths:**
- Horizontal scroll rails for "Continue Watching", "Just Added", and per-library rows — this is the canonical tvOS video app layout.
- `LazyHStack` for performance.
- Library rail headers are NavigationLinks to the full grid.
- `TVPosterCard` includes progress bar inside the ZStack — correct (unlike the iOS poster cell which uses the offset hack).

**Weaknesses:**
1. **No navigation title on TVHomeView.** The `NavigationStack` in `TVHomeView` has a toolbar item but no `.navigationTitle`, so the top bar shows nothing except the Pair button. Should show the NAS name or "DS Reel".
2. **"Just Added" uses addedAt sort** — numeric Unix timestamp vs ISO date with string fallback. Edge cases where `addedAt` is empty or zero could produce wrong ordering.
3. **Library rails silently fail.** `TVLibraryRail.load()` catches errors and ignores them — the rail simply shows empty. No loading indicator on the rail itself.
4. **No search on tvOS.** There is no search tab or search entry point on tvOS at all.
5. **TVPosterCard has fixed 300x450pt size.** This hardcoded size ignores the adaptive grid column width. On a 4K TV the cards will look small; on smaller screens they may not fit.

---

## Priority-Ranked Improvement List

### Critical (App quality / user trust)

| # | Issue | Screen | Impact |
|---|-------|--------|--------|
| C1 | **Progress bar render bug** — iOS poster cell progress bar uses `offset(y: height)` outside clip boundary, making it invisible | ItemsGridView | Every watched movie shows no progress |
| C2 | **"Home" tab shows no Continue Watching** — the most valuable feature of a video app is absent from iOS | LibraryHomeView | Core user workflow broken |
| C3 | **Search error silently shows "No Results"** — network failures are indistinguishable from empty results | SearchView | Users get confused, think content is missing |
| C4 | **No subtitle/audio track support in player** — essential for any video library | GestureVideoPlayer | Subtitles completely unavailable |
| C5 | **CircularProgressView hardcodes brand color** — won't update if brand color changes | TVShowDetailView | Tech debt that will bite on rebrand |

### High (Significant UX gaps)

| # | Issue | Screen | Impact |
|---|-------|--------|--------|
| H1 | **No sort or filter on grids** — cannot sort by year, title, date added, genre | ItemsGridView, TVShowsView | Browsing large libraries is painful |
| H2 | **Backdrop fallback uses portrait poster** — portrait image stretched into landscape header looks bad | ItemDetailView, TVShowDetailView | Visual degradation for ~40% of items |
| H3 | **No AirPlay button in player** | GestureVideoPlayer | Core Apple ecosystem feature missing |
| H4 | **No Picture-in-Picture** | GestureVideoPlayer | Expected iOS feature |
| H5 | **No "Continue Watching S02E03" button** on TV show detail | TVShowDetailView | Users must manually find resume point |
| H6 | **No QuickConnect on tvOS login** | TVMainView (TVLoginView) | Difficult login on tvOS remote |
| H7 | **Server URL not editable in Settings** — must log out to change server | SettingsView | Poor operator experience |
| H8 | **tvOS has no search** — zero search capability | TVMainView | No way to find content on TV |
| H9 | **Login screen has no logomark** — brand identity absent at first impression | LoginView | Weak brand presence |
| H10 | **About screen not reachable after login** — version/info inaccessible while logged in | SettingsView, AboutView | Support friction |

### Medium (Polish and feature parity)

| # | Issue | Screen | Impact |
|---|-------|--------|--------|
| M1 | **No "watched" badge** — no visual indicator for 100% watched items | ItemsGridView | Difficult to track what's been seen |
| M2 | **Search is submit-only** — no live/debounced results | SearchView | Friction vs. modern search UX |
| M3 | **Duplicate play/pause button** in player controls | GestureVideoPlayer | Visual redundancy, confusing controls layout |
| M4 | **No active download progress in Downloads tab** | DownloadsView | Unclear where to monitor ongoing downloads |
| M5 | **App version only on Login > About** | AboutView | Unnecessary friction |
| M6 | **Episode rows have no thumbnail** | TVShowDetailView | Visual scanning is text-only |
| M7 | **No next-episode button in player** | GestureVideoPlayer | Must manually navigate to next ep |
| M8 | **Downloads tab: no sort, no storage usage total** | DownloadsView | Missing metadata |
| M9 | **Season collapse touch target: 12pt padding** (should be 16pt minimum) | TVShowDetailView | Borderline HIG compliance |
| M10 | **tvOS login field styling** — `white.opacity(0.15)` fields nearly invisible on red | TVMainView | Legibility issue |
| M11 | **Bottom toolbar on login** — three visually inconsistent elements | LoginView | Cluttered, unclear affordances |
| M12 | **ItemDetail header only 230pt** — cinematic hero feels undersized | ItemDetailView | Missed premium feel |
| M13 | **Cast section is a plain list** — no avatars or horizontal scroll | ItemDetailView | Visually underdeveloped |
| M14 | **tvOS home has no navigation title** | TVMainView (TVHomeView) | Missing context in top bar |
| M15 | **Libraries list has no artwork or thumbnails** | LibrariesView | Dull entry point |

### Low (Nice-to-have polish)

| # | Issue | Screen | Impact |
|---|-------|--------|--------|
| L1 | **No skeleton/shimmer loading states** — bare `ProgressView` throughout | All loading screens | Feels less premium |
| L2 | **Design token system is minimal** — single color token, no surface/text tokens | Global | Maintenance risk, inconsistency |
| L3 | **No haptic feedback** in player for skip/scrub | GestureVideoPlayer | Minor tactile polish |
| L4 | **Server URL as plain Text in Settings** — no monospace, no copy affordance | SettingsView | Minor UX friction |
| L5 | **Pairing view has no illustration** | PairingCodeView | Instruction clarity |
| L6 | **QuickConnect server list shows raw IPs** | QuickConnectSheet | Unfriendly for non-technical users |
| L7 | **About screen uses generic blue SF Symbol** | AboutView | No brand identity |
| L8 | **"Home" tab label doesn't match content** | MainView | Misleading tab label |
| L9 | **Search history not persisted** | SearchView | Convenience feature absent |
| L10 | **No watchlist/favorites** | Global | Expected premium feature |

---

## Per-Screen Summary Scorecard

| Screen | Layout | Typography | Color | Navigation | Touch Targets | Error States | Grade |
|--------|--------|------------|-------|------------|---------------|--------------|-------|
| Login | B | C | B | B | A | B | B |
| QuickConnect | B | B | B | B | A | C | B- |
| Libraries | C | B | B | C | A | B | C+ |
| Library Home | D | B | B | D | A | B | C- |
| Items Grid | B | C | B | B | A | C | B- |
| Item Detail | B+ | B | B | B | A | B | B |
| Video Player | A | B | A | B+ | A | B | A- |
| Search | B | B | B | B | A | D | C+ |
| Downloads | B | B | B | B | A | B | B- |
| Settings | B | B | B | C | A | B | B- |
| About | C | B | D | D | A | — | D+ |
| TV Shows Grid | B | C | B | B | A | B | B- |
| TV Show Detail | B | B | B | B | B | C | B- |
| Pairing | B | B | B | B | A | B | B |
| tvOS Login | B | B | C | C | A | B | C+ |
| tvOS Home | A | B | B | B | A | C | B+ |

---

## Quick Wins (Implement in < 1 day each)

1. **Fix progress bar in `ItemPosterCell`** — move progress indicator inside the ZStack, pinned to bottom, same pattern as `TVPosterCard`.
2. **Replace hardcoded `Color(red:...)` in `CircularProgressView`** with `DSReelBrandColor.background`.
3. **Add `ContentUnavailableView("No Libraries", ...)` to empty library list.**
4. **Surface search errors** instead of silently showing "No Results".
5. **Add app version to SettingsView** (copy from AboutView — one-liner).
6. **Rename `DSReelBrandColor.background` to `DSReelBrandColor.accent`** and fix all usages.

---

## Recommended Next Steps (Priority Order)

1. **Implement iOS Home "Continue Watching" rail** — mirrors tvOS implementation, massive UX value.
2. **Fix poster cell progress bar** — critical visual bug.
3. **Add sort/filter to ItemsGridView and TVShowsView** — sort by title, year, date added.
4. **Add AirPlay route picker to GestureVideoPlayer** — single `AVRoutePickerView` embed.
5. **Add subtitle/audio track menu to player** — `AVPlayerItem.asset.tracks` enumeration.
6. **Expand design token system** — rename accent, add 3-4 surface tokens, fix all hardcoded grays.
7. **Add "Play Next Episode" / "Continue S0xExx" button** to TV show detail.
8. **Add QuickConnect support to tvOS login.**

---

*Audit covers source code review. Visual rendering not verified against live device. Contrast ratios estimated from color values, not measured against rendered pixels.*
