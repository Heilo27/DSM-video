# Competitive UX Research — DS Reel

**Date:** 2026-03-15
**Scope:** UX patterns across 8 categories for 8 apps, focused on patterns worth adopting for DS Reel (a Synology NAS media player for iOS/tvOS/macOS).

**Apps analyzed:** Infuse 8, Plex (2025 redesign), Emby, VLC for iOS, MUBI, Netflix, Disney+, Apple TV app

---

## 1. Library Browsing

### Infuse 8
- **Grid-first layout.** Poster-centric 2-column to 4-column adaptive grid depending on device width. No list fallback by default — pure visual browsing.
- **"Library" concept is server-based.** Each connected source (Plex, Jellyfin, SMB, SFTP, iCloud) appears as a top-level source. Within a source you browse by folder hierarchy or by scraped category (Movies, TV Shows, Collections).
- **Smart sorting.** Sort by title, date added, release year, duration, rating. Infuse 8's revamped browsing infrastructure delivers noticeably faster list and item loading on large libraries (10,000+ items).
- **Collections.** Scraped movie franchise collections (e.g., "Marvel Cinematic Universe") surface as a browsable section. User-created lists (Favorites) show as a dedicated row.
- **Recently Added / Up Next.** The home screen prominently surfaces "Up Next" (resume watching + next unwatched episode) and "Recently Added" as horizontally-scrolling shelves above the full library.
- **Filters.** Genre, resolution (4K, HDR, HD), audio format (Dolby Atmos, DTS:X), file format. Filters are accessible via a toolbar icon; active filters show a badge count.

### Plex (2025 Redesign)
- **Home is curated.** First screen presents "On Deck" (continue watching), "Recently Added," and personalized recommendation rows — not the raw library. Plex separates personal media from streaming content.
- **"My Media" dedicated tab.** The 2025 redesign adds a distinct tab for personal server libraries, separate from Plex's own streaming content. This addresses the core pain point of personal libraries getting buried under ad-supported content.
- **Favorited libraries.** Users can mark libraries as favorites; those libraries get their own tabs within the My Media section. Enables quick one-tap access to specific content types.
- **Grid vs. list toggle.** Users can switch between poster grid and a detail list view (showing metadata like resolution, duration, year inline). Grid is default.
- **Horizontal shelves on home.** Each row is a horizontally-scrollable shelf labeled by category (continue watching, genre, decade, recently added, etc.). The 2025 redesign expands artwork size significantly in these shelves.
- **Collections & playlists.** Auto-generated collections from TMDb/TVDb data. Manual playlists. Both surface on the home screen if populated.

### Emby
- **Home dashboard is fully customizable.** Users configure which "widgets" appear on the home screen: Next Up, Latest Media, Continue Watching, My Views, Recommended. Order is drag-rearrangeable.
- **Views = libraries.** Each Emby library (Movies, TV Shows, Music, etc.) appears as a "View" with a large card on the home. The visual is a collage of posters from that library's content.
- **Filtering is extensive.** By genre, year, rating, tags, resolution, studio, actors. Filters persist per-session.
- **List and grid.** Both supported with user preference stored. The list view shows inline metadata: year, rating, duration, file format badge.

### Apple TV App (native)
- **Horizontal shelf architecture.** The "Watch Now" tab is entirely shelf-based — rows labeled "Up Next," "What to Watch," branded content rows, "Apple TV+ Titles." No grid on the main home.
- **Library tab for purchased content.** A dedicated "Library" tab shows all purchased/rented iTunes content in a grid, sortable by type (Movies, TV Shows, Kids).
- **Up Next is central.** The topmost shelf is always "Up Next" — currently-watching and planned content. Tapping directly plays or resumes.

### Netflix
- **Vertical-scrolling home with horizontal rows.** Each row is a genre or algorithm-generated category. Rows are labeled. Content displays as landscape thumbnails (16:9 aspect ratio) rather than portrait posters — a distinctive choice.
- **"Continue Watching" row.** Always near the top. Shows progress bar on each card. A long-press on the card reveals "Remove from Continue Watching" — a friction-reducer for abandoned content.
- **Top 10 row.** Numbered poster cards (1–10) in your country — social proof signal.
- **N-Slate tiles.** The top card on the home screen plays a looping video preview automatically, no interaction required. This drives engagement but requires server-side assets most NAS apps cannot provide.

### MUBI
- **Editorial-first.** The home screen is a curated "Now Showing" list — 30 films at a time — presented as a vertical stack of landscape hero cards, each with a short editorial blurb. This is genre-first browsing, not title-first.
- **"Library" for past content.** Watched, Watchlisted, and Downloaded films accessible under a separate Library tab — minimal sorting.
- **Dark mode by default.** MUBI's visual language is cinematic: deep blacks, minimal chrome, film-grain textures.
- **Categories via "Moods" and "Plots"** rather than standard genre tags. "Intimate," "Unsettling," "Festival Favorites."

### Disney+
- **Tab-based by brand.** Disney, Pixar, Marvel, Star Wars, National Geographic. Navigation is brand-first rather than genre- or library-first. Relevant for franchise-heavy content; not applicable to NAS.
- **"For You" personalized home.** New "For You" tab replaces the old generic home. Content recommendations improve with viewing history.
- **Continue Watching always visible.** Top of the For You tab. Cards show large thumbnails with episode title and progress bars.

---

## 2. Poster/Card Design

### Standard Aspect Ratios
- **2:3 (portrait, "movie poster" ratio)** — universal across Infuse, Plex, Emby, MUBI, Apple TV app for movies and TV shows. This is the industry standard for poster cards.
- **16:9 (landscape)** — Netflix uses this almost exclusively for its card tiles. Also used for episode thumbnails in all apps.
- **1:1 (square)** — used for music/podcast apps; not relevant for video.

### Overlays and Badges
- **Watched indicator.** Small checkmark or eye icon in the corner (Infuse, Plex). Alternatively a desaturated/dimmed poster for watched content (some Plex clients). Infuse uses a subtle eye icon in the lower-right corner with a 40% opacity overlay.
- **Quality badges.** Infuse overlays HDR, Dolby Vision, Dolby Atmos, DTS:X badges in the upper-right corner of the poster. These are semi-transparent pills on the actual artwork. Plex shows resolution badges (4K, HDR) on the card as a small ribbon.
- **Continue watching progress bar.** A thin bar at the bottom of the poster card, ~4px height, colored with the app accent color. Used by Plex, Netflix, Disney+. Netflix adds the episode title as text below the bar for series. Infuse shows "Up Next" text on the card itself when part of a series watch queue.
- **Downloaded/offline badge.** A small download arrow icon (Plex) or a green cloud-with-checkmark (Infuse) in the corner. Applied on top of the poster artwork.
- **Rating overlay.** Plex optionally shows star rating (1–5) as a small gold star row at the bottom of the card. Infuse shows IMDb/Rotten Tomatoes rating in a pill on the card detail panel, not on the grid card itself.
- **Unplayed count.** For TV show cards in the grid, Plex and Emby show a blue circle with the unplayed episode count in the upper-right corner. Useful at a glance without opening the show.

### Card Interaction on Hover/Focus
- **Scale on focus.** All apps scale the card slightly on focus/hover (105–110%). Infuse uses a pronounced lift + shadow animation. Plex uses a scale with parallax tilt. Netflix uses scale with a detail popover appearing after a delay.
- **Netflix detail expand.** After ~1.5 seconds of hover on desktop, a card expands in-place to show: short description, ratings, genres, action buttons (Play, Add to List, More Info). Mobile Netflix uses tap → full detail view without the expand pattern.

### DS Video current state
DS Reel uses a 2:3 adaptive grid with gradient overlays showing title + year. No watched badges. No quality indicators. No progress bars on cards. No unplayed counts for TV shows.

---

## 3. Detail Views

### Netflix
- **Hero image fills the top ~40% of the screen.** On iOS, the hero transitions in from the card thumbnail. The hero image is usually a landscape still or title treatment, not a poster.
- **Action buttons directly below the hero.** "Play" as the primary, full-width CTA. Secondary buttons: "Download," "Add to List," "Rate," "Share." All icons with labels.
- **Match score / percentage.** Netflix shows a green "97% Match" pill next to the title based on user taste profile.
- **Episode carousel for series.** A horizontal scroll of episodes immediately below the actions, with thumbnail + title + duration + short synopsis.
- **Cast displayed as horizontal scroll.** Each cast member shows a circular photo + name + character name. Scrollable row.
- **"More Like This" section.** Algorithmic recommendations shown as card grid below the main content.

### Plex
- **Backdrop image at full width.** Pulled from metadata. A gradient fades from the backdrop to black for the content below.
- **Rating prominently placed.** Rotten Tomatoes / audience score shown as a Tomatometer icon + percentage in the first row of metadata.
- **Quick-action row.** Play (primary), Trailer, Download, Watchlist, Rate, More — horizontal icon buttons with labels below each icon.
- **Extras section.** Behind-the-scenes, deleted scenes, featurettes if available from metadata provider.
- **Similar content.** A "More Like This" shelf at the bottom.

### Infuse
- **Clean vertical layout.** No backdrop at the top — starts with a horizontal layout of poster (left) + metadata (right) on iPad; on iPhone, poster is centered above metadata.
- **Metadata row.** Year, duration, resolution tag (4K HDR), audio tag (Atmos). These are displayed as small gray pills in a horizontal row.
- **Rating sources.** IMDb, Rotten Tomatoes, Metacritic shown as small logos with scores.
- **Action buttons.** Play (prominent), Trailer (if available), Watchlist (heart icon), Edit (manual metadata correction).
- **Cast and crew.** Horizontal scroll of cast cards with photo + name + character. Crew section below.
- **File info section.** A collapsible section showing: filename, file size, container, video codec, audio codec, subtitle tracks, audio tracks. This is a key power-user feature relevant to NAS/local file users.

### Apple TV App
- **Large hero + bold title treatment.** Title text overlaid directly on the hero image with a dark gradient. Very cinematic.
- **Prominent rating and runtime.** Displayed as plain text in a metadata row below the title.
- **"Play" takes entire width.** Plus a row of secondary actions: "Add to Up Next," "Rent," "Buy," share options.
- **Extras tab.** A tab UI to switch between details, extras, and related content without scrolling.

### DS Reel current state
ItemDetailView uses a backdrop at the top (~230px on iPhone, 450px on tvOS) with a title + year overlay. Below: metadata pills (year, rating, genres) in a scrollable horizontal row. Play button (full width). Download button/state. Summary text. Cast section (text only, no photos). No ratings displayed. No file info. No trailer option. No "More Like This" section.

---

## 4. Video Player Controls

### Standard iOS Gesture Pattern (industry-wide)
This pattern is consistent across Infuse, VLC, Plex, and aligns with the iOS 16 system player:

| Zone | Gesture | Action |
|------|---------|--------|
| Anywhere | Single tap | Show/hide controls |
| Left third | Double-tap | Skip back (10s) |
| Right third | Double-tap | Skip forward (10s) |
| Left half | Vertical swipe | Brightness |
| Right half | Vertical swipe | Volume |
| Anywhere horizontal | Horizontal drag | Scrub |

DS Reel implements this entire standard pattern. The core gesture layer is solid.

### Infuse-specific player features
- **Jog-wheel scrubbing.** When paused, placing a finger on the edge of the screen and making a circular motion activates a jog-wheel — precise frame-by-frame or slow-motion scrubbing. This is a power-user feature for editors and sports viewers.
- **Playback speed.** 0.5x to 3x in 0.25x increments. Shown as a badge in the player top bar.
- **Chapter navigation.** If the file has chapter markers (MP4/MKV), the scrubber shows chapter marks as tick marks. Tapping left/right edges of the screen (with "Chapter Controls" setting enabled) jumps between chapters.
- **Subtitle styling.** Font, size, color, shadow, vertical position all configurable in-player via a dedicated subtitle settings panel.
- **Audio track selection.** Quick-access button in the player toolbar. Switching is instant.
- **Picture-in-Picture.** Supported on iPhone and iPad. Works via the native PiP API.
- **AirPlay.** Routing button directly in the player controls.
- **Lock screen controls.** Full Now Playing integration — artwork, title, timeline scrubber visible on the lock screen and in Control Center.

### VLC for iOS
- **Most permissive gesture mapping.** VLC allows customizing which gestures do what in settings. Default matches industry standard but can be remapped.
- **Long-press on scrubber.** Shows a larger, more precise scrubbing handle. Regular scrubbing is coarse.
- **Playback speed accessible via swipe.** A two-finger vertical swipe on the screen changes playback speed (non-default, settable).
- **3D Touch / Haptic Peek.** On supported devices, force-pressing the video surface gives a quick position preview.

### Netflix Player
- **"10 seconds" skip is double-tap.** The skip distance is fixed at 10s forward (right double-tap) and 10s back (left double-tap). No UI to change this.
- **Episode end card.** At the end of an episode, a full-screen card appears with 5-second countdown auto-advancing to next episode. "Watch credits" / "Skip" / "Next Episode" options.
- **Intro/credits skip button.** A prominent "Skip Intro" or "Skip Credits" button appears when entering those sections, auto-detected by Netflix's server-side chapter data.
- **Playback speed.** 0.5x, 0.75x, 1x, 1.25x, 1.5x. Accessed via a speech bubble icon in the player controls — confusingly grouped with subtitle settings.

### DS Reel current state
GestureVideoPlayer implements the standard five-zone gesture pattern, double-tap skip (±10s), playback speed menu (0.5x to 2x), a timeline scrubber with elapsed/remaining time, and a centered play/pause button. Volume indicator shown on hardware button press. Brightness indicator on vertical swipe left.

**Missing from DS Reel player:**
- Subtitle track selection
- Audio track selection
- Picture-in-Picture
- AirPlay routing button
- Chapter markers on scrubber
- Skip intro/credits button
- Next episode countdown/auto-play
- Lock screen Now Playing controls (media metadata integration with MPNowPlayingInfoCenter)
- Pinch-to-zoom (fill vs. fit mode)

---

## 5. Search

### Plex
- **Universal search.** Searches across libraries, Plex streaming catalog, actors/directors, studios. A single search box returns mixed results grouped by category (Movies, TV Shows, People, etc.).
- **Recent searches.** A row of recent search terms shown as removable chips below the search field when it's focused and empty.
- **Search suggestions.** As you type, inline suggestions appear. These are sourced from your library metadata, not just titles.
- **Result cards.** Same poster card design as the library grid. Results are grouped by type (movies, episodes, actors) in sections.
- **Filter within results.** After getting results, a filter row appears to narrow by type, year, genre.

### Infuse
- **Library-scoped search.** Searches only your connected sources. No streaming catalog mixing.
- **As-you-type results.** Results appear immediately without requiring a submit. Cards appear in the standard grid format.
- **Recent searches.** Shown below the search bar as tappable chips.
- **Smart match.** Searches titles, descriptions, actor names, and director names. Finding "Nolan" surfaces all Christopher Nolan films.

### Netflix
- **Search is a first-class tab.** Always visible in the tab bar.
- **Trending searches.** When search is focused with no text, a grid of trending/popular titles appears with thumbnail images.
- **Category browsing in search.** Below trending searches, a row of genre/mood category tiles appears for exploratory browsing without typing.
- **Instant results.** Results appear as you type, no submit required. Layout is a 3-column grid.
- **People search.** Typing an actor name returns a person card + their filmography.

### DS Reel current state
SearchView uses `.searchable` on a NavigationStack. No recent searches. No as-you-type suggestions — requires keyboard submit (`onSubmit`). Empty state shows a generic "Search Videos" message. Results display as a 2-column adaptive grid. No category browsing in empty search state.

---

## 6. Downloads / Offline

### Plex
- **Downloads tab in navigation.** Plex has a dedicated "Downloads" section with sub-tabs: Downloading (in progress), Downloaded (completed).
- **Per-item download controls.** From the detail view, a download icon initiates a download. Users can select quality (Original, Maximum, High, Medium, Low) — useful when the original 4K MKV would fill storage.
- **Storage indicator.** The Downloads screen header shows total space used by downloads and the available free space, as a progress bar.
- **Queue management.** Active downloads show title, quality, progress percentage, estimated time remaining. Can pause/resume individual downloads.
- **Offline badge.** Downloaded items show a green checkmark download badge in the library grid — helps users know which items are available offline at a glance.
- **Wifi-only setting.** Downloads can be restricted to wifi. Settable per-download or globally.
- **Expiry.** Plex downloads expire if not watched within 30 days (DRM protection for streaming content). Personal media downloads don't expire.

### Infuse
- **Background download.** Downloads continue when the app is backgrounded. This is a significant advantage over Plex's iOS app (Plex requires foreground).
- **Download queue.** A Downloads section shows queued, active, and completed downloads. Queue is reorderable.
- **iCloud sync for download list.** Infuse syncs your download queue state across devices. Useful if managing downloads on iPad to watch on Apple TV.
- **Offline indicator.** In the library grid, downloaded items show a small offline/available indicator. Items from unavailable servers show a server-offline indicator rather than being hidden.

### DS Reel current state
DownloadsView shows a grid of downloaded items with poster, title, and file size. Context menu on each cell offers "Delete Download." Detail view shows download state (not started / in progress with percentage / downloaded). Active downloads require the app to remain in foreground (same constraint as Plex). No storage indicator showing total usage. No download quality selection. No wifi-only toggle. No offline badge in the library grid.

---

## 7. Navigation

### iOS — Tab Bar Pattern
- **Standard 4–5 tab structure.** Most apps (Plex, Netflix, Disney+, Apple TV) use a bottom tab bar with 4–5 items.
- **Netflix:** Home, Search, New & Hot, Downloads, More.
- **Plex (2025):** Home, For You/Discover, My Media, Live, Search.
- **Disney+:** For You, Search, Downloads, Profile.
- **Apple TV app:** Watch Now, Apple TV+, Store, Library, Search.
- **DS Reel:** Home, Libraries, Search, Downloads, Settings. Good parity with industry pattern.

### iPad — Sidebar Pattern
- **NavigationSplitView.** Infuse, Plex, and Apple TV app all use a persistent sidebar on iPad, showing navigation items and library sections. The sidebar is collapsible.
- **Sidebar shows connected servers/sources.** Infuse shows each connected source in the sidebar with a disclosure arrow. Plex shows each library in the sidebar. This gives iPad users a much more powerful nav structure than the iPhone tab bar.
- **DS Reel already implements NavigationSplitView on iPad.** The implementation has Browse (Libraries, Search, Downloads) and Settings sections. However, it defaults the detail view to `LibrariesView` rather than a home/dashboard view — a minor first-load awkwardness.

### tvOS — Focus Engine
- **Shelf-based home.** All major tvOS apps (Infuse, Plex, Netflix, Apple TV) use horizontal shelves as the primary home layout. This works with the Siri Remote's directional swipe/click model.
- **Tab bar on top.** tvOS apps typically put a horizontal tab bar at the top of the screen (not bottom like iOS), since focus movement flows downward.
- **Large focus targets.** tvOS cards are typically 300–400px wide to provide comfortable focus targets. Focused cards scale to 115–120% of their resting size.
- **Full-screen backdrop on focus.** When a TV show or movie card receives focus, many apps (Plex, Netflix) replace the background with a blurred/dimmed version of that item's backdrop image. Creates a cinematic feel.
- **DS Reel TVMainView.** The current implementation uses a NavigationStack with a LibrariesView inside a TVMainView wrapper. This is functional but lacks the shelf-based home layout that all major tvOS apps use. No full-screen backdrop on focus. No horizontal shelf architecture.

### macOS — Sidebar as Primary Navigation
- **Sidebar replaces tab bar.** All macOS apps use a persistent sidebar. Infuse for macOS has a sidebar with sources on the left, content grid on the right.
- **DS Reel uses NavigationSplitView on macOS.** The `split` layout is activated for macOS. Appropriate choice.

---

## 8. Empty / Loading / Error States

### Loading
- **Skeleton screens.** Infuse, Plex, and Netflix all use skeleton/shimmer loading screens rather than spinners. The skeleton mimics the layout that will appear — poster-shaped gray blocks in the grid positions, text-shaped bars where titles will appear. This dramatically improves perceived performance.
- **Progressive loading.** Plex loads the first few rows immediately and continues loading as the user scrolls. Infuse does the same with its grid — the first 20 items appear instantly, rest load as you scroll.
- **DS Reel uses ProgressView() spinners.** A centered spinner while libraries or items load. Simple but perceived as slower than skeleton loading.

### Empty States
- **Contextual empty state illustrations.** Netflix shows a character or movie frame when a category is empty. Plex shows a custom illustration with a clear call-to-action.
- **DS Reel uses `ContentUnavailableView`.** This is the iOS 17 system component. It renders an icon, title, and description. It's appropriate and system-native, but generic.
- **Better empty state pattern.** For an empty library: explain that the library exists but has no content, and link to documentation for adding content. For search with no results: show similar/suggested titles. For downloads with none: explain how to download with a visual walkthrough.

### Error States
- **Inline retry.** Plex and Infuse show error states inline (not modal alerts) with a "Retry" button in the same location where the content would have appeared. No need to navigate away.
- **Specific error messages.** Best apps distinguish: "Server offline," "Connection refused," "Authentication expired," "Item unavailable," rather than generic "Something went wrong."
- **DS Reel uses ContentUnavailableView for errors.** Shows a triangle warning icon + error message string. No retry button visible in all cases (LibrariesView and ItemDetailView have `.task { await load() }` and `.refreshable { await load() }` but no inline retry CTA in the empty/error state).

### Connection Loss During Playback
- **Buffering indicator vs. error.** When streaming from a NAS and wifi drops, players need to distinguish between "buffering (will recover)" and "server disconnected (cannot recover)." AVPlayer handles buffering automatically; but when the server is completely gone, the player stalls permanently without a useful error.
- **Infuse timeout behavior.** After ~30 seconds of stall, Infuse pops a dialog: "Playback stalled. Would you like to retry?" with Retry/Cancel options.
- **DS Reel current behavior.** The isBuffering indicator shows a spinner, but there is no timeout logic to detect a permanent server disconnect and surface a recovery UI.

---

## NAS-Specific Patterns

### First-Run Setup and Server Connection

#### Plex
- **Account-first.** Plex requires creating a Plex account before adding a server. This enables cloud features (remote access, sync, watch history). The first-run flow is: Create Account → Allow Plex to find servers on the network (Bonjour discovery) → OR manually enter server URL. The Plex app then provisions a JWT from the Plex account service.
- **Server discovery UI.** After logging in, Plex shows a "Choose a server" screen listing all discovered Plex Media Servers on the local network as tappable cards. Each card shows: server name, owner name, local vs. remote indicator.
- **Remote access setup.** Plex walks through port forwarding or Plex Relay setup for remote access during onboarding.

#### Emby
- **Server-first.** Enter the server address (or auto-discover on LAN), then authenticate with Emby credentials. No central account required for local use.
- **LAN auto-discovery.** Emby client scans for Emby Server broadcasts on the local network. Found servers appear in a list. Manual address entry available as fallback.
- **Connect codes.** Emby offers a "Quick Connect" feature — the app shows a numeric code; you approve it in the server's web UI. Eliminates password entry on TV remotes.

#### Infuse
- **No account required for basic use.** Add a source directly: SMB, SFTP, Plex, Emby, Jellyfin, WebDAV, iCloud. Each source type has its own connection setup flow. Plex/Emby sources authenticate via their respective APIs.
- **Source validation on add.** When adding a source, Infuse tests the connection and shows a "Connected" / "Could not connect" result before you confirm.
- **Offline fallback.** If a source is unavailable, Infuse still shows the items from that source (using cached metadata) with a "Server offline" indicator on the source row. Tapping an offline item shows a "Server unavailable" sheet rather than navigating to a broken detail view.

#### DS Reel current state
LoginView collects server URL (or QuickConnect ID), username, and password. HTTPS toggle. No LAN auto-discovery. No server validation feedback before submitting. No offline-source graceful degradation — if the NAS is unreachable after login, views load empty with a generic error string.

### Metadata: Local vs. Scraped

#### Infuse
- **Scrapes from TMDb, TVDb, MusicBrainz** automatically based on filename matching. Shows a "Fetching metadata" state in the toolbar during initial scan.
- **Manual metadata correction.** If Infuse matches incorrectly, you can long-press a title and "Edit" to manually search for the correct match. This replaces the scraped data for that file.
- **Embedded metadata preferred.** Files with embedded MKV/MP4 tags (title, year, poster URL) use those first; scraped data fills gaps.
- **"Use Local Metadata" mode.** For home videos or files without matches, Infuse falls back to showing the raw filename, file duration, and codec info instead of leaving a blank poster.

#### Plex
- **Server-side scraping.** Plex Media Server does all scraping; the iOS app only displays results. The server runs matching on file names/paths. Resolution metadata, audio codec detection is also server-side.
- **"Fix Incorrect Match"** context menu option on the server. Long-tap → Fix Match → Search → pick the correct match. Change propagates to all clients.
- **Local assets.** Placing a `poster.jpg` or `movie-name.jpg` next to the video file overrides scraped artwork.

### Mixed Content (Movies + TV + Home Videos)

#### Plex
- **Libraries are type-scoped.** A Plex library is either Movies, TV Shows, Music, or Photos/Home Videos — not mixed. The UI for each type is completely different (movie = grid, TV = show/season/episode hierarchy, home videos = chronological gallery). Mixing types is prevented by design.
- **Home Videos library type.** Plex has a dedicated "Home Videos" library type. Items in it are displayed with date-taken metadata rather than title-based metadata.

#### Infuse
- **Sources can contain mixed types.** Infuse is folder-centric; a single source can contain movies, TV shows, and home videos. Infuse uses file-naming conventions and scraping results to classify each file. If a file doesn't match any scraped title, it's treated as a "Home Video."
- **Browse by type.** Within a source, Infuse offers tabs for Movies, TV Shows, Other — filtering across the full source to show only that type.

#### DS Reel current state
Libraries are Video Station library types (movie/tv/home). The UI does route TV to `TVShowsView` vs. `ItemsGridView` for other types. There's no "home videos" treatment — home videos fall into the generic ItemsGridView grid. No browse-by-type filtering within a single library.

---

## tvOS-Specific Patterns

### Layout Architecture
- **Top tab bar.** Apple TV HIG mandates (and enforces via convention) that the primary navigation live in a horizontal tab bar at the top of the screen. All major apps follow this: Infuse, Plex, Netflix, Apple TV app, Disney+. On tvOS, tab labels auto-focus via the Siri Remote's up swipe from the main content area.
- **Shelf rows as home.** The first screen after launching should be a shelf-based layout: labeled rows of content that scroll horizontally. Vertical scroll advances between rows. This maps precisely to the Siri Remote's circular touch surface.
- **DS Reel TVMainView.** Currently wraps a LibrariesView inside a NavigationStack. This results in a vertical list of library names — accurate but not the visual-first shelf pattern users expect from a tvOS video app.

### Focus and Animation
- **Card scale on focus: 115–120%.** The focused card scales up with a subtle shadow/lift. The cards adjacent to the focused one shift slightly to create depth. Infuse's implementation is particularly polished.
- **Background parallax.** When a card is focused, many apps replace the background with a dark, blurred backdrop image of that content. Infuse does this with a gentle parallax tilt. Plex does this with a full background blur.
- **Focus guide placement.** Critical buttons (Play, Download, Watchlist) should be the default focus on the detail view. The first focusable item on a new screen should always be the primary action.

### Remote Gestures
- **Swipe up from content area → tabs.** Standard tvOS pattern: swiping up from any content brings focus to the top tab bar.
- **Play/Pause button** should always play/pause current content or the focused item, even when controls overlay is not visible.
- **Select (click) on video preview** should begin playback immediately, without requiring a detail view navigation.
- **Menu button** goes back to the previous screen or dismisses an overlay. Apps should never intercept the Menu button in a way that traps the user.

### Now Playing for tvOS
- **Now Playing metadata.** tvOS requires implementing `MPNowPlayingInfoCenter` to populate the "Now Playing" item in the Siri Remote's app switcher. Artwork, title, artist (for TV: show name), elapsed time, total duration must all be set.
- **Remote skip commands.** `MPRemoteCommandCenter` should handle skip forward/back commands from the Siri Remote's playback buttons. This also enables media key support on external Bluetooth keyboards and game controllers.

---

## Patterns to Adopt

These are specific, actionable recommendations for DS Reel, ordered roughly by impact-to-effort ratio.

### P01 — Skeleton Loading for Library and Detail Views
**What:** Replace `ProgressView()` spinners with shimmer skeleton screens that mimic the expected layout.
**Where:** LibrariesView, ItemsGridView, ItemDetailView.
**Impact:** High perceived performance improvement. Infuse, Plex, Netflix all do this. SwiftUI 's `.redacted(reason: .placeholder)` modifier provides this almost for free.
**Effort:** Low — use `.redacted(reason: .placeholder)` on placeholder data objects.

### P02 — Continue Watching Home Row
**What:** A "Continue Watching" shelf on the home screen showing items with >0% progress, ordered by most-recently-watched.
**Where:** LibraryHomeView / new HomeView.
**Impact:** Core engagement feature. Every major video app (Netflix, Plex, Disney+, Infuse) places this above the fold. The API already tracks resume position per item; this just needs surfacing.
**Effort:** Medium — requires a new API query for in-progress items, plus a new shelf component.

### P03 — Subtitle and Audio Track Selection in Player
**What:** A button in the player control bar opening a sheet to pick subtitle and audio tracks embedded in the file.
**Where:** GestureVideoPlayer.
**Impact:** Critical for multi-language content and for users with hearing accessibility needs. Infuse, VLC, and Plex all implement this. Without it, DS Reel cannot serve international users or users with subtitles needs.
**Effort:** Medium — AVPlayer exposes `AVPlayerItem.asset.tracks` for audio tracks; subtitles require checking for `AVMediaCharacteristicLegible` tracks and enabling via `AVPlayerItem.selectMediaOption`.

### P04 — Picture-in-Picture Support
**What:** Enable PiP on iOS/iPadOS via `AVPictureInPictureController` or `AVPlayerViewController`.
**Where:** GestureVideoPlayer (iOS only).
**Impact:** High quality-of-life for iPad users and iPhone users who multitask. Apple requires PiP for video apps. Plex, Infuse, Netflix all support it.
**Effort:** Low-medium — wire up `AVPictureInPictureController`. The custom player layer approach used by GestureVideoPlayer requires explicit PiP integration rather than getting it for free from `AVPlayerViewController`.

### P05 — Lock Screen / Now Playing Integration
**What:** Populate `MPNowPlayingInfoCenter` with title, artwork, duration, elapsed time. Handle `MPRemoteCommandCenter` for play/pause, skip forward/back.
**Where:** GestureVideoPlayer / PlayerSheet.
**Impact:** Users lose track of what's playing when the device is locked. Accessibility for headphone controls (play/pause from remote). Essential for tvOS. Expected on iOS.
**Effort:** Low — well-documented API. GestureVideoPlayer already tracks all needed data (currentTime, duration, title).

### P06 — Progress Bar on Poster Cards
**What:** A thin (3–4px) progress bar at the bottom edge of each poster card for in-progress items.
**Where:** ItemsGridView poster cards, SearchResultCell, DownloadedItemCell.
**Impact:** Users can see at a glance what they've started without opening the detail view. Plex, Netflix, Disney+ all do this. Low visual noise — the bar is only visible when progress > 0.
**Effort:** Low — requires passing resume position data alongside the item summary in the API response and rendering a `Rectangle` overlay on the card.

### P07 — Watched Badge on Poster Cards
**What:** A small checkmark or "eye" icon badge in the corner of fully-watched items.
**Where:** ItemsGridView poster cards.
**Impact:** Helps users quickly identify what they've already seen when browsing a large library. Infuse and Plex both implement this.
**Effort:** Low — requires the API to return a "watched" boolean or % complete field.

### P08 — Recent Searches and As-You-Type Results
**What:** (a) Show recent search terms as chips below the search field when focused/empty. (b) Trigger search on text change after a 300ms debounce rather than requiring keyboard submit.
**Where:** SearchView.
**Impact:** Reduces friction for repeat searchers. The current submit-required pattern feels dated compared to Infuse, Netflix, Plex.
**Effort:** Low-medium — recent searches stored in UserDefaults; debounce via a `@State` publisher or `Task` with a sleep.

### P09 — Inline Retry Button in Error States
**What:** Add a "Retry" button directly in the `ContentUnavailableView` or error state, instead of requiring pull-to-refresh.
**Where:** LibrariesView, ItemDetailView, any view with an error state.
**Impact:** Reduces friction when a transient error occurs (NAS briefly unreachable). Plex and Infuse show an inline retry.
**Effort:** Very low — `ContentUnavailableView` accepts an `actions` parameter for buttons.

### P10 — Offline-Aware Server Status
**What:** When the NAS is unreachable (no internet / outside home network), show a server-status indicator instead of a generic error. Show cached library content (greyed out / with "offline" badge) rather than an empty error screen.
**Where:** LibrariesView, ItemDetailView.
**Impact:** NAS apps are uniquely prone to this. Infuse's handling is the gold standard — it shows your full library from cache and clearly indicates which items can be played offline vs. need server. Leaving users with an empty screen when they're just on cellular is a trust-breaker.
**Effort:** High — requires client-side caching of library metadata and per-item status tracking.

### P11 — tvOS Shelf Layout on Home
**What:** Redesign TVMainView to use a shelf-based layout: "Continue Watching," "Recently Added," per-library rows. Replace the vertical list of library names.
**Where:** TVMainView.
**Impact:** The current list-of-library-names feels like a settings screen, not a TV app. All major tvOS apps use shelf rows. This is the most visually jarring gap in the tvOS experience.
**Effort:** Medium — requires horizontal ScrollView rows with LazyHStack content, plus the continue-watching data from P02.

### P12 — Quality Badges on Poster Cards
**What:** Overlay small resolution/format badges (4K, HDR, Dolby Vision) in the upper-right corner of poster cards for items where the NAS reports resolution metadata.
**Where:** ItemsGridView poster cards.
**Impact:** Helps users who care about quality differentiate items in a large library. Infuse and Plex both do this.
**Effort:** Low — requires the API response to include resolution/HDR metadata and rendering a small text pill overlay.

### P13 — Pinch-to-Zoom (Fill vs. Fit Mode) in Player
**What:** Two-finger pinch gesture in the player toggles between `videoGravity = .resizeAspect` (fit) and `.resizeAspectFill` (fill). Show a brief "Fill" / "Fit" indicator bubble.
**Where:** GestureVideoPlayer.
**Impact:** Important for content with black bars (2.35:1 films). Netflix, Infuse, and VLC all support this. The current player is locked to `.resizeAspect`.
**Effort:** Low — toggle `playerLayer.videoGravity` on pinch gesture.

### P14 — File Info Section in Detail View
**What:** A collapsible "File Info" section at the bottom of ItemDetailView showing: filename, file size, video codec, resolution, audio codec, audio channels, subtitle tracks.
**Where:** ItemDetailView.
**Impact:** Power feature for NAS users. They often have mixed-quality rips and need to know what they're about to play. Infuse shows this prominently. Plex buries it.
**Effort:** Medium — requires the API to surface codec/format metadata from Video Station's file info endpoint.

### P15 — Storage Usage Indicator in Downloads
**What:** A header bar in DownloadsView showing: storage used by downloads / total device storage, as a visual progress bar.
**Where:** DownloadsView.
**Impact:** Users managing large offline libraries on a 64GB iPhone need this. Plex provides it. The current DownloadsView shows nothing about storage budget.
**Effort:** Low — `FileManager.default.attributesOfFileSystem(forPath:)` provides device storage stats; sum of `DownloadedItem.fileSize` provides download usage.

---

## Missing Features in DS Reel vs. Competitors

The following features are present in one or more competitors but absent from DS Reel.

| Feature | Infuse | Plex | Emby | VLC | Netflix | DS Reel |
|---------|--------|------|------|-----|---------|---------|
| Subtitle track selection in player | Yes | Yes | Yes | Yes | Yes | **No** |
| Audio track selection in player | Yes | Yes | Yes | Yes | Yes | **No** |
| Picture-in-Picture | Yes | Yes | Yes | No | Yes | **No** |
| Now Playing / Lock Screen controls | Yes | Yes | Yes | Yes | Yes | **No** |
| Chapter markers on scrubber | Yes | Yes | Yes | No | No | **No** |
| Skip intro/credits button | No | Yes (some) | Yes | No | Yes | **No** |
| Pinch to fill screen | Yes | Yes | No | Yes | Yes | **No** |
| Continue Watching home row | Yes | Yes | Yes | No | Yes | **No** |
| Skeleton loading screens | Yes | Yes | No | No | Yes | **No** |
| Progress bar on poster cards | Yes | Yes | Yes | No | Yes | **No** |
| Watched badge on poster cards | Yes | Yes | Yes | No | No | **No** |
| Recent searches chips | Yes | Yes | No | No | No | **No** |
| As-you-type search results | Yes | Yes | No | No | Yes | **No** |
| Trending/suggested search empty state | No | No | No | No | Yes | **No** |
| Storage indicator in Downloads | No | Yes | No | No | N/A | **No** |
| Download quality selection | No | Yes | Yes | No | Yes | **No** |
| Background downloads (iOS) | Yes | No | No | No | Yes | **No** |
| LAN server auto-discovery | Yes | Yes | Yes | No | N/A | **No** |
| Offline source graceful degradation | Yes | Partial | No | N/A | N/A | **No** |
| tvOS shelf-based home | Yes | Yes | Yes | No | Yes | **No** |
| tvOS background image on focus | Yes | Yes | No | No | Yes | **No** |
| Cast photos in detail view | Yes | Yes | Yes | No | Yes | **No (text only)** |
| File info section in detail view | Yes | Buried | Buried | Yes | No | **No** |
| Quality badges on poster cards | Yes | Yes | No | No | No | **No** |
| Ratings display (IMDb/RT) in detail view | Yes | Yes | No | No | Yes | **No** |
| AirPlay button in player | Yes | Yes | Yes | Yes | Yes | **No** |
| Inline error retry button | Yes | Yes | No | No | No | **No** |

**Priority assessment:** The top critical gaps — in order of user-facing impact — are:
1. Subtitle / audio track selection (P03) — accessibility + international users
2. Now Playing / Lock Screen controls (P05) — system integration expected on iOS
3. PiP (P04) — multitasking, App Store expectation
4. Continue Watching home row (P02) — core engagement loop
5. AirPlay routing in player — trivial to add, high request frequency

---

## Summary

DS Reel has a solid functional foundation: the gesture player is well-implemented, the grid layout is appropriate, and the API integration covers the core streaming use case. The gaps are largely in polish, discoverability, and system integration — exactly the features that differentiate good apps from great ones in a competitive category.

The highest-leverage improvements are on the player (subtitles, audio, PiP, Now Playing) and on home-screen engagement (Continue Watching row, progress bars on cards). The tvOS experience needs architectural investment — the current linear list does not meet user expectations set by Infuse and Plex on Apple TV.

---

## Sources

- [Infuse 8 — Now Available | Firecore](https://firecore.com/blog/infuse-8-now-available)
- [Infuse video player updated with new design and Vision Pro app — 9to5Mac](https://9to5mac.com/2024/10/15/infuse-video-player-vision-pro-app/)
- [Plex unveils dramatic redesign for iPhone app — 9to5Mac](https://9to5mac.com/2024/11/22/plex-new-iphone-app-design/)
- [A New Plex Experience is Coming — Plex Blog](https://www.plex.tv/blog/the-new-plex-experience/)
- [New Plex Mobile App With Streamlined Interface Rolling Out — MacRumors](https://www.macrumors.com/2025/04/02/new-plex-mobile-app-now-rolling-out/)
- [Plex Is Rewriting Its Apps from Scratch — How-To Geek](https://www.howtogeek.com/plex-mobile-tv-app-redesign-2025/)
- [Playback Controls — Firecore Support](https://support.firecore.com/hc/en-us/articles/215090987-Playback-Controls)
- [VLC Playback Gestures — VideoLAN iOS Documentation](https://docs.videolan.me/vlc-user/ios/3.X/en/basic/playbackgestures.html)
- [Disney+ App Redesign — Disney Plus Official](https://www.disneyplus.com/explore/articles/disney-plus-app-redesign-new-features)
- [Netflix UX Case Study — Pixel Plasma / Medium](https://medium.com/@pixelplasmadesigns/netflix-ux-case-study-the-psychology-design-and-experience-afecb135470f)
- [Mastering Video Player Controls: UX Best Practices — Vidzflow](https://www.vidzflow.com/blog/mastering-video-player-controls-ux-best-practices)
- [Skeleton UI Design Best Practices — Mobbin](https://mobbin.com/glossary/skeleton)
- [tvOS Focus Engine Best Practices — Oxagile](https://www.oxagile.com/article/tvos-focus-engine-best-practices/)
- [Designing for tvOS — Apple Developer](https://developer.apple.com/design/human-interface-guidelines/designing-for-tvos)
- [Downloads for iOS and Android — Plex Support](https://support.plex.tv/articles/download-ios-android/)
- [MUBI UX Case Study — Pete Keenlyside / Medium](https://pete-keenlyside.medium.com/i-gave-myself-an-hour-to-redesign-mubi-ux-case-study-8c63088bbd6b)
- [Everything new with the redesigned iOS 16 video player — 9to5Mac](https://9to5mac.com/2022/06/23/ios-16-video-player/)
