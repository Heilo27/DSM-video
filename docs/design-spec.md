# DS Reel — Design Spec

**Source file:** `designs/ds-reel-redesign.pen`
**Date:** 2026-03-15
**Designer:** Lumen
**For:** Scotty (implementation)

---

## Design Tokens — Swift Implementation

Replace `DSVideoBrandColor.swift` with the following expanded token set:

```swift
// DSVideoDesignTokens.swift

import SwiftUI

extension Color {
    // Backgrounds
    static let dsBackground      = Color(hex: "#000000")
    static let dsSurface         = Color(hex: "#111111")  // cards, inputs
    static let dsSurfaceHigh     = Color(hex: "#1C1C1E")  // elevated elements
    static let dsSurfaceRaised   = Color(hex: "#2C2C2E")  // current-state legacy

    // Accent
    static let dsAccent          = Color(hex: "#D1262F")  // primary red

    // Status / semantic
    static let dsSuccess         = Color(hex: "#32D583")  // watched badge, complete
    static let dsError           = Color(hex: "#E85A4F")  // error banner
    static let dsWarning         = Color(hex: "#FFB547")  // star ratings

    // Text
    static let dsTextPrimary     = Color.white
    static let dsTextSecondary   = Color.white.opacity(0.70)
    static let dsTextTertiary    = Color.white.opacity(0.45)
    static let dsTextMuted       = Color(hex: "#6B6B70")
    static let dsTextInactive    = Color(hex: "#4A4A50")

    // Borders / separators
    static let dsBorderSubtle    = Color(hex: "#2A2A2E")
    static let dsBorderStrong    = Color(hex: "#3A3A40")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (1, 1, 0)
        }
        self.init(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
    }
}
```

### Typography Scale

```swift
// DSVideoTypography.swift

extension Font {
    static let dsLargeTitle    = Font.system(size: 34, weight: .bold)
    static let dsTitle2        = Font.system(size: 22, weight: .bold)
    static let dsHeadline      = Font.system(size: 17, weight: .semibold)
    static let dsBody          = Font.system(size: 17, weight: .regular)
    static let dsSubheadline   = Font.system(size: 15, weight: .regular)
    static let dsSubheadlineSB = Font.system(size: 15, weight: .semibold)
    static let dsFootnote      = Font.system(size: 13, weight: .regular)
    static let dsCaption       = Font.system(size: 11, weight: .regular)
    static let dsCaption2      = Font.system(size: 11, weight: .semibold)

    // Screen titles (used across all main views)
    static let dsScreenTitle   = Font.system(size: 26, weight: .bold)
}
```

---

## Per-Screen Implementation Notes

### Priority Order
1. **LoginView** — logomark + QuickConnect field (user-facing, blocks onboarding)
2. **GestureVideoPlayer** — remove duplicate play/pause, add AirPlay + captions buttons
3. **ItemDetailView** — taller hero, runtime/director metadata
4. **LibrariesView / MainView** — Home screen redesign with content rails
5. **ItemsGridView** — progress bars on poster cards, watched badge
6. **Search** — recent searches chips, error vs. no-results states
7. **Downloads** — storage indicator, per-item progress

---

### B1 — LoginView

**File:** `DS Video clone/DS Video clone/DSVideo/Views/LoginView.swift`

**Changes:**
- Add logomark: red circle (`#D1262F`, 80pt, cornerRadius 40) containing a white play triangle (SF Symbol `play.fill` or polygon). Centered above form.
- Add app name "DS Reel" at 28pt bold below logomark, tagline "Your NAS, beautifully." at 15pt in `dsTextMuted`.
- Form fields: background `dsSurface` (#111111), cornerRadius 12, height 52. Each field has a left icon (SF Symbols: `network`, `person`, `lock`).
- Field labels: uppercase, 11pt semibold, `dsTextMuted`, 0.8 letter spacing.
- Primary CTA: "Connect" button — full width, 56pt height, `dsAccent` fill, cornerRadius 14.
- Secondary CTA: "Connect via QuickConnect ID" — full width, 52pt, `dsSurface` fill, 1pt `dsBorderSubtle` stroke, cornerRadius 14.
- Divider between primary and secondary CTAs: 1pt line with "or" centered.
- Remove existing bottom toolbar chrome; replace with simple version text footer.
- QuickConnect field: same `address` field — placeholder text should read "192.168.x.x or QuickConnect ID". The existing QuickConnect logic can stay, just needs the placeholder updated.

---

### B2 — Home Screen (MainView / LibrariesView)

**File:** `DS Video clone/DS Video clone/DSVideo/Views/MainView.swift` + `LibrariesView.swift`

**New home screen layout** (replace current plain list):

```
NavigationView
  VStack(spacing: 0)
    // Header
    HStack
      Text("DS Reel")  // dsScreenTitle
      Spacer()
      Button(search icon)

    ScrollView(.vertical)
      VStack(spacing: 24)

        // Continue Watching rail
        if !continueWatchingItems.isEmpty
          SectionHeader("Continue Watching")
          ScrollView(.horizontal, showsIndicators: false)
            HStack(spacing: 12)
              ForEach(continueWatchingItems)
                ContinueWatchingCard(item)  // 200x120, with progress bar at bottom edge

        // Just Added section
        SectionHeader("Just Added", action: "See All")
        ScrollView(.horizontal, showsIndicators: false)
          HStack(spacing: 10)
            ForEach(justAddedItems)
              PosterCard(item)  // 110x165

        // Recently Watched section
        SectionHeader("Recently Watched", action: "See All")
        ScrollView(.horizontal, showsIndicators: false)
          HStack(spacing: 10)
            ForEach(recentlyWatchedItems)
              PosterCard(item, showWatchedBadge: item.isWatched)
```

**New components needed:**

`ContinueWatchingCard` — 200x120, rounded corners 10, image fill, gradient overlay bottom-half, title text at bottom-left (11pt semibold), red progress bar pinned to bottom edge (3pt height, progress fraction * 200 width).

`PosterCard` — 110x165, rounded corners 8, image fill. Optional watched badge: 24pt green circle with checkmark in top-right corner (x: width-32, y: 8).

`SectionHeader` — HStack with title (18pt bold) and optional "See All" link (14pt `dsAccent`).

**Data requirements:**
- "Continue Watching" = items where `watchedPercent > 0 && watchedPercent < 100`, sorted by `lastWatched` desc
- "Just Added" = sorted by `addedDate` desc, first 10
- "Recently Watched" = items where `watchedPercent == 100`, sorted by `lastWatched` desc

---

### B3 — Items Grid (ItemsGridView)

**File:** `DS Video clone/DS Video clone/DSVideo/Views/ItemDetailView.swift` (grid view)

**Changes:**

1. **Sort/filter bar** — horizontal chip row below header. Active chip: `dsAccent` fill, white text. Inactive: `dsSurfaceHigh` fill, `dsTextMuted`. Chips: All, A–Z, Year, Rating. Right side: "Filter" button with sliders icon.

2. **Poster cards** — switch from current layout to `PosterCard` component (see above). 3-column grid, gap 10, horizontal padding 20.

3. **Progress bar** — pinned to bottom edge of each card. 3pt height. Track: `dsBorderStrong`. Fill: `dsAccent`. Width = `cardWidth * watchedPercent`. Only show if `watchedPercent > 0`.

4. **Watched badge** — green circle + checkmark in top-right if `watchedPercent == 100`.

5. **Item count** — show "127 movies" in `dsTextMuted` 13pt below the grid.

```swift
// PosterCard view
struct PosterCard: View {
    let item: VideoItem
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Poster image
            AuthenticatedImage(url: item.posterURL)
                .aspectRatio(2/3, contentMode: .fill)
                .clipped()

            // Progress bar
            if item.watchedPercent > 0 && item.watchedPercent < 100 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.dsBorderStrong)
                            .frame(height: 3)
                        Rectangle()
                            .fill(Color.dsAccent)
                            .frame(width: geo.size.width * item.watchedPercent, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Watched badge
            if item.watchedPercent >= 1.0 {
                Circle()
                    .fill(Color.dsSuccess)
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.black))
                    .padding(8)
            }
        }
        .frame(width: 110, height: 165)
        .cornerRadius(8)
    }
}
```

---

### B4 — Item Detail (ItemDetailView)

**File:** `DS Video clone/DS Video clone/DSVideo/Views/ItemDetailView.swift`

**Changes:**

1. **Hero height** — increase from current ~220pt to **300pt**. Use `AsyncImage` or `AuthenticatedImage` with `.fill` content mode and a bottom gradient overlay (`clear → black at 70–100%`).

2. **Backdrop fallback** — if no backdrop image, show a gradient rectangle (dark surface) with the title rendered large. Do NOT stretch portrait poster to landscape.

3. **Back button** — floating pill button (36pt circle, 50% white overlay) pinned top-left within the hero, y-offset 72pt (below status bar).

4. **Metadata block** (below hero, 16pt top padding):
   - Title: 24pt bold
   - Year • Runtime • Genre: 13pt `dsTextMuted`, separated by bullets
   - Star rating + IMDb score: stars in `dsWarning`, score in white bold
   - "Dir. [Director Name]": 12pt label + 13pt bold name

5. **Action buttons row** (horizontal, gap 12, 16pt vertical padding):
   - Play: fills remaining width, 52pt height, `dsAccent`, cornerRadius 12, play icon + "Play" label
   - Download: 52x52 square, `dsSurfaceHigh`, cornerRadius 12, download icon
   - Trailer: 52x52 square, `dsSurfaceHigh`, cornerRadius 12, film icon

6. **Cast row** — horizontal scroll of 56pt circular avatars with name below (11pt).

7. **Runtime data** — add `runtime` field to `VideoItem` model. Pull from `additional.video.duration` in the Video Station API response (already available, needs surfacing to UI).

---

### B5 — Video Player (GestureVideoPlayer)

**File:** `DS Video clone/DS Video clone/DSVideo/Views/GestureVideoPlayer.swift`

**Critical fixes:**

1. **Remove center play/pause overlay** — delete the large center button entirely. Playback control is exclusively in the bottom control strip.

2. **Top bar** (y: 44pt below top edge, horizontal padding 20):
   - Left: dismiss/back chevron-down in frosted circle
   - Center: title (15pt semibold)
   - Right: AirPlay button (`AirPlayButton` using `AVRoutePickerView`), Captions button (CC icon, toggles subtitle track), Settings gear icon

3. **Scrub bar** (bottom area, above controls):
   - Time elapsed: 12pt, `#FFFFFFB0`
   - Track: full remaining width, 4pt height. Background: `#FFFFFF40`. Fill: `dsAccent`. Thumb: **16pt white circle** (increase from current ~8pt for easier touch target)
   - Time remaining: 12pt, `#FFFFFFB0`

4. **Playback controls strip** (below scrub bar, horizontal, space-between):
   - Skip to start (`backward.end.fill`)
   - Rewind 15s (`gobackward.15`) — use SF Symbol, shows "15" inside
   - Play/Pause — 56pt circle, `#FFFFFF15` background, `play.fill`/`pause.fill` 28pt icon
   - Forward 15s (`goforward.15`)
   - Skip to end (`forward.end.fill`)

5. **AirPlay implementation:**
```swift
import AVKit

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Color.dsAccent)
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
```

6. **Captions/subtitle button:**
```swift
Button(action: { showSubtitlePicker = true }) {
    Image(systemName: "captions.bubble")
        .font(.system(size: 22))
        .foregroundColor(.white)
}
.sheet(isPresented: $showSubtitlePicker) {
    SubtitleAudioPickerView(player: player)
}
```

---

### B6 — Search

**File:** (new or existing search view)

**Changes:**

1. **Live search** — debounce text input 300ms before firing API call. Use `Combine` publisher on the search field.

2. **Empty state** (no query entered):
   - "Recent Searches" section header (15pt semibold, `dsTextMuted`)
   - Chip rows: horizontally scrolling chips, `dsSurfaceHigh` background, history icon + label, cornerRadius 16

3. **No results state** (query returned empty):
   - `magnifyingglass` with X overlay icon (40pt, `dsBorderStrong`)
   - "No results for [query]" — 17pt semibold white
   - "Try a different title, director, or genre." — 14pt `dsTextMuted`

4. **Error state** (network/API failure) — distinct from no results:
   - Red-tinted banner at bottom (`#2C1515` background)
   - Wifi-off icon in `dsError`
   - "Connection error" title + descriptive subtitle
   - "Retry" action in `dsAccent`

5. **Results list** — each row: 42x62 thumbnail + title (15pt semibold) + metadata (12pt `dsTextMuted`) + chevron

---

### B7 — Downloads

**File:** `DS Video clone/DS Video clone/DSVideo/Networking/DownloadManager.swift` + Downloads view

**Changes:**

1. **Storage indicator** at top:
   - "Storage Used" label + "X GB of Y GB" right-aligned
   - Progress bar: full width, 6pt height, `dsBorderStrong` track, `dsAccent` fill
   - Query with `FileManager.default.urls(for: .documentDirectory)` for actual used/available bytes

2. **Download cell states:**
   - **Completed** — `circle-check` icon in `dsSuccess`; no progress bar shown
   - **Downloading** — percentage text + "X GB / Y GB" in secondary row; red progress bar (width = cell width * progress fraction)
   - **Queued** — "Queued" label; empty circle icon in `dsTextMuted`; no progress bar
   - **Paused** — "Paused" label; `circle-pause` icon; partial progress bar shown

3. **Swipe to delete** — standard iOS swipe-left to delete, red destructive action.

---

## New Shared Components

These components are used across multiple screens — build as reusable SwiftUI views:

| Component | Used In | Notes |
|-----------|---------|-------|
| `PosterCard` | Grid, Home, Search | 110x165, progress bar, watched badge |
| `ContinueWatchingCard` | Home | 200x120, landscape, progress bar |
| `SectionHeader` | Home | Title + optional "See All" link |
| `DSTabBar` | All main screens | HOME / SEARCH / DOWNLOADS, active in red |
| `AirPlayButton` | Video Player | Wraps `AVRoutePickerView` |
| `ErrorBanner` | Search, Player | Red-tinted, icon + title + subtitle + retry |

---

## Design Token Swift Package (Optional Refactor)

If time permits, move all tokens into a `DSVideoDesignSystem` micro-package:

```
DSVideoDesignSystem/
  Sources/
    Colors.swift      — all Color extensions
    Typography.swift  — all Font extensions
    Spacing.swift     — padding/gap constants
    Components/
      PosterCard.swift
      SectionHeader.swift
      DSTabBar.swift
      AirPlayButton.swift
      ErrorBanner.swift
```

This avoids scattering tokens across view files and makes future theming trivial.

---

## Implementation Priority (Scotty's order)

| # | Screen/Feature | Effort | Impact |
|---|---------------|--------|--------|
| 1 | Remove duplicate play/pause from GestureVideoPlayer | S | Critical UX bug |
| 2 | Add AirPlay button to player top bar | S | High-request feature |
| 3 | Larger scrub slider thumb (8pt → 16pt) | XS | Touch usability |
| 4 | LoginView logomark + QuickConnect placeholder text | M | Onboarding quality |
| 5 | ItemDetailView hero height 220→300, backdrop gradient | M | Visual quality |
| 6 | ItemDetailView runtime + director metadata | S | Info completeness |
| 7 | PosterCard with progress bar + watched badge | M | Core feature |
| 8 | Home screen content rails (Continue Watching, etc.) | L | Core feature |
| 9 | Sort/filter chips in grid | M | Discovery |
| 10 | Search recent chips + error vs. no-results states | M | Polish |
| 11 | Downloads storage indicator + cell states | M | Polish |
| 12 | DSTabBar component (uppercase labels) | S | Consistency |

---

*Generated by Lumen — DS Reel Design System v1.0*
