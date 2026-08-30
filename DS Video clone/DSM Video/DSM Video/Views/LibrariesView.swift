import SwiftUI
import os.log

private let loadLog = Logger(subsystem: "com.dsm.dsvideo", category: "LibraryLoad")

#if !os(tvOS)
// MARK: - LibrarySearchSheet

/// A self-contained search sheet scoped to a single library. Presented from the
/// magnifying-glass button in a library view's nav bar. Reuses the caller's data
/// and destinations so search results push to the same detail screens as the grid.
struct LibrarySearchSheet<Item: Identifiable, Destination: View>: View {
  let title: String
  let items: [Item]
  let filter: (Item, String) -> Bool
  let destination: (Item) -> Destination
  let rowLabel: (Item) -> AnyView

  @Environment(\.dismiss) private var dismiss
  @State private var query: String = ""
  @FocusState private var fieldFocused: Bool

  private var results: [Item] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    return items.filter { filter($0, q) }
  }

  var body: some View {
    NavigationStack {
      Group {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
          ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                 description: Text("Type a title to search this library."))
        } else if results.isEmpty {
          ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                 description: Text("No matches for \"\(query)\""))
        } else {
          List(results) { item in
            NavigationLink {
              destination(item)
            } label: {
              rowLabel(item)
            }
            .listRowBackground(Color.black)
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
        }
      }
      .background(Color.black.ignoresSafeArea())
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: title)
      .navigationTitle("Search")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
    .preferredColorScheme(.dark)
  }
}
#endif

struct LibrariesView: View {
  @Environment(AppState.self) private var appState
  @State private var libraries: [Library] = []
  @State private var isLoading: Bool = false
  @State private var error: String?

  /// Pass `true` when this view is embedded as the detail column of a
  /// `NavigationSplitView`. The split view itself acts as the navigation
  /// container, so wrapping in a second `NavigationStack` would produce
  /// double nav bars and broken back-navigation on iPad/macOS.
  var isEmbedded: Bool = false

  var body: some View {
    let content = Group {
      if isLoading && libraries.isEmpty {
        ProgressView("Loading libraries")
          .accessibilityLabel("Loading libraries, please wait")
          .accessibilityAddTraits(.updatesFrequently)
      } else if let error {
        // FIX-18: retry button for transient network failures on the libraries screen
        VStack(spacing: 12) {
          ContentUnavailableView("Couldn't load libraries", systemImage: "exclamationmark.triangle", description: Text(error))
          Button("Retry") { Task { await load() } }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Retry loading libraries")
        }
      } else if libraries.isEmpty {
        ContentUnavailableView("No Libraries", systemImage: "square.grid.2x2", description: Text("No video libraries found on your server."))
      } else {
        // Each library is a labeled, clearly-bounded artwork card: a section
        // title above ("Movies" / "TV Shows"), then a bordered box with a small
        // poster collage and the item count.
        ScrollView {
          VStack(alignment: .leading, spacing: 28) {
            ForEach(libraries) { lib in
              VStack(alignment: .leading, spacing: 10) {
                Text(lib.title)
                  .font(.title.weight(.bold))
                  .foregroundStyle(.white)
                  .accessibilityAddTraits(.isHeader)

                NavigationLink {
                  if lib.kind == "tv" {
                    TVShowsView(library: lib)
                  } else {
                    ItemsGridView(library: lib)
                  }
                } label: {
                  LibraryCard(library: lib, height: 170)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(lib.title)
                .accessibilityHint("Opens \(lib.title)")
              }
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 20)
        }
      }
    }
    .navigationTitle("Libraries")
    .background(Color.black.ignoresSafeArea())
    .task { await load() }
    .refreshable { await load(force: true) }
    .onChange(of: appState.homeLibraries) { _, libs in
      // Only update if the set of library IDs changed — updating when content is
      // already loaded pops any pushed NavigationLink destination (e.g. TVShowsView)
      // and cancels its in-flight .task, preventing TV shows from loading.
      if !libs.isEmpty && libs.map(\.id) != libraries.map(\.id) {
        libraries = libs
      }
    }
    .onChange(of: appState.sessionToken) { _, token in
      if token == nil {
        libraries = []
        error = nil
      }
    }

    if isEmbedded {
      content
    } else {
      NavigationStack { content }
    }
  }

  private func load(force: Bool = false) async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      libraries = DemoData.libraries
      return
    }
    // Use already-fetched libraries from AppState to avoid redundant network call (TASK-410).
    // Skip the cache when force=true (e.g. pull-to-refresh — TASK-518).
    if !force && !appState.homeLibraries.isEmpty {
      libraries = appState.homeLibraries
      return
    }
    error = nil
    isLoading = true
    defer { isLoading = false }

    do {
      let response = try await appState.api.libraries()
      libraries = response.libraries
    } catch {
      appState.handleConnectionFailure(error)
      let errorMsg = (error as? APIError)?.userMessage ?? "Unknown error."
      self.error = errorMsg
    }
  }
}

// MARK: - LibraryCard

/// A tall artwork card for a single library. Loads a few recent posters to build
/// a collage backdrop and shows the library's item count. Tapping it (via the
/// enclosing NavigationLink) opens the library.
private struct LibraryCard: View {
  @Environment(AppState.self) private var appState
  let library: Library
  let height: CGFloat

  @State private var posterIDs: [String] = []
  @State private var demoAssets: [String] = []
  @State private var itemCount: Int?
  @State private var didLoad = false

  private var icon: String {
    switch library.kind {
    case "tv": return "tv"
    case "movies", "movie": return "film"
    case "home", "homevideo": return "house"
    default: return "play.rectangle"
    }
  }

  private var countLabel: String? {
    guard let n = itemCount, n > 0 else { return nil }
    let noun: String
    switch library.kind {
    case "tv": noun = n == 1 ? "show" : "shows"
    default: noun = n == 1 ? "title" : "titles"
    }
    return "\(n) \(noun)"
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      // Artwork collage backdrop
      collage
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()

      // Strong bottom gradient anchoring the footer so the count row stays
      // legible over any artwork.
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.45),
          .init(color: .black.opacity(0.75), location: 0.8),
          .init(color: .black.opacity(0.95), location: 1.0),
        ],
        startPoint: .top, endPoint: .bottom
      )

      // Footer: icon + item count, with a chevron affordance.
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: icon)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Color.dsAccent)
          .accessibilityHidden(true)
        if let countLabel {
          Text(countLabel)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.white.opacity(0.7))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
    }
    .frame(height: height)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.dsBorderStrong, lineWidth: 1)
    )
    // Make the ENTIRE card a single tap target. Without this, only the opaque
    // rendered pixels (text/icons) register taps, so transparent gaps between
    // collage tiles aren't tappable — which made parts of the card dead.
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    // TASK-693/698: redact in app switcher / screen recordings.
    .privacySensitive()
    #if os(iOS)
    .hoverEffect(.lift)
    #endif
    .task { await loadArtwork() }
  }

  // MARK: Collage

  @ViewBuilder
  private var collage: some View {
    if appState.isDemoMode {
      tileGrid(demoAssets.map { CollageTile.asset($0) })
    } else if !posterIDs.isEmpty {
      tileGrid(posterIDs.map { CollageTile.remote($0) })
    } else {
      placeholderFill
    }
  }

  private enum CollageTile {
    case asset(String)
    case remote(String)
  }

  /// Lay tiles out edge-to-edge. 1 tile fills; 2 split horizontally; 3–4 form a 2×2.
  @ViewBuilder
  private func tileGrid(_ tiles: [CollageTile]) -> some View {
    if tiles.isEmpty {
      placeholderFill
    } else if tiles.count == 1 {
      tileView(tiles[0])
    } else if tiles.count <= 3 {
      HStack(spacing: 2) {
        ForEach(Array(tiles.prefix(2).enumerated()), id: \.offset) { _, t in tileView(t) }
      }
    } else {
      let four = Array(tiles.prefix(4))
      VStack(spacing: 2) {
        HStack(spacing: 2) { tileView(four[0]); tileView(four[1]) }
        HStack(spacing: 2) { tileView(four[2]); tileView(four[3]) }
      }
    }
  }

  @ViewBuilder
  private func tileView(_ tile: CollageTile) -> some View {
    Group {
      switch tile {
      case .asset(let name):
        Image(name).resizable().scaledToFill()
      case .remote(let id):
        AuthenticatedImage(
          url: appState.api.imageURL(id: id, width: 400),
          token: appState.sessionToken,
          usesTunnelCookie: appState.api.usesTunnelCookie
        )
        .scaledToFill()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
  }

  private var placeholderFill: some View {
    Rectangle()
      .fill(Color(white: 0.12))
      .overlay(
        Image(systemName: icon)
          .font(.system(size: 56, weight: .regular))
          .foregroundStyle(.white.opacity(0.18))
          .accessibilityHidden(true)
      )
  }

  // MARK: Load

  private func loadArtwork() async {
    guard !didLoad else { return }
    didLoad = true

    if appState.isDemoMode {
      let items = library.kind == "tv" ? DemoData.tvItems : DemoData.movieItems
      demoAssets = items.compactMap { DemoData.posterAssetNames[$0.id] }.prefix(4).map { $0 }
      itemCount = items.count
      return
    }

    do {
      if library.kind == "tv" {
        // TV: the shows endpoint gives one entry per show — an accurate show count
        // (not episodes) and clean per-show posters, so no episode-dedup needed.
        let resp = try await appState.api.tvShows(libraryId: library.id)
        posterIDs = resp.shows.compactMap { $0.posterImageId }.prefix(4).map { $0 }
        itemCount = resp.shows.count
      } else {
        // Movies: one entry per film. Dedup by item id defensively and take four.
        let resp = try await appState.api.items(libraryId: library.id, limit: 40)
        var seen = Set<String>()
        var unique: [String] = []
        for item in resp.items where seen.insert(item.id).inserted {
          if let img = item.posterImageId ?? item.backdropImageId {
            unique.append(img)
            if unique.count == 4 { break }
          }
        }
        posterIDs = unique
        itemCount = resp.effectiveTotal
      }
    } catch {
      loadLog.warning("LibraryCard: artwork load failed for \(library.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
      // Leave placeholder; card still works as a navigation target.
    }
  }
}

// MARK: - LibraryHomeView

struct LibraryHomeView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  // TASK-787: scenePhase handling moved to the app-level owner; no longer needed here.

  /// Bottom inset that keeps the last rail clear of the floating tab bar (TASK-884).
  /// The bar grows with Dynamic Type, so a fixed height that clears it at medium does not
  /// clear it at the accessibility sizes — where the defect was worst (the whole
  /// "Recently Watched" header was hidden behind the bar).
  private var tabBarClearance: CGFloat {
    dynamicTypeSize.isAccessibilitySize ? 132 : 76
  }

  /// Pass `true` when this view is embedded inside an existing NavigationStack
  /// (e.g. the iPad split-view detail column) to avoid nesting stacks.
  var isEmbedded: Bool = false

  // Fires once per session when the first content rail appears — VoiceOver announcement
  @State private var hasAnnouncedContent: Bool = false

  // MARK: - Body

  var body: some View {
    let content = Group {
      if (appState.homeIsLoading || appState.homeIsCacheDecoding) && appState.homeAllRailsEmpty {
        ProgressView("Loading content")
          .tint(Color.dsTextPrimary)
          .accessibilityLabel("Loading content, please wait")
          .accessibilityAddTraits(.updatesFrequently)
      } else if let error = appState.homeError {
        VStack(spacing: 16) {
          ContentUnavailableView(
            "Couldn't load content",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
          Button("Retry") { Task { await appState.homeLoad() } }
            .buttonStyle(.bordered)
            .accessibilityLabel("Retry loading content")
        }
      } else if appState.homeAllRailsEmpty && !appState.homeIsLoading && !appState.homeIsCacheDecoding {
        ContentUnavailableView(
          "Nothing here yet",
          systemImage: "play.rectangle",
          description: Text("Add videos to your NAS to get started.")
        )
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 28) {
            // Cinematic hero (full-bleed). Renders only on the Cinematic theme — on
            // Classic / Nitrate HomeHero is an EmptyView, so the layout below is
            // exactly the prior top-rail arrangement. Featured from Just Added.
            HomeHero(items: appState.homeJustAdded)

            // TASK-742: these are curated, finite, mixed-library lists — a "See All"
            // that dumps the user into a single library grid is misleading, so they
            // carry no See-All. Full browsing lives in the Libraries tab.
            if !appState.homeContinueWatching.isEmpty {
              HomeRail(
                title: "Continue Watching",
                items: appState.homeContinueWatching,
                seeAllLibrary: nil,
                useLandscapeCards: true
              )
            }
            if !appState.homeJustAdded.isEmpty {
              HomeRail(
                title: "Just Added",
                items: appState.homeJustAdded,
                seeAllLibrary: nil
              )
            }
            if !appState.homeRecentlyWatched.isEmpty {
              HomeRail(
                title: "Recently Watched",
                items: appState.homeRecentlyWatched,
                seeAllLibrary: nil
              )
            }
          }
          .padding(.top, ThemeHolder.shared.current.usesCinematicChrome ? 0 : 16)
          .padding(.bottom, 16)
        }
        .background(alignment: .top) {
          // Atmospheric light streaks sit behind all content (no-op on flat themes).
          ZStack(alignment: .top) {
            Color.dsBackground
            AtmosphereBackground().frame(height: 560)
          }
          .ignoresSafeArea()
        }
        // Bottom clearance for the floating tab bar, on EVERY theme (was gated on
        // usesCinematicChrome — TASK-789 — but iOS 26's tab bar floats on all of them), and
        // scaled with Dynamic Type because the bar grows with it.
        //
        // TASK-884 RESOLVED. Do not inflate this number chasing a screenshot.
        //
        // A pixel probe kept reporting lit pixels behind the bar at AX5 and four separate
        // attempts were made to widen clearance here. The probe was measuring the wrong thing:
        // at AX5 the app opens at the TOP of the list, so what sits behind the bar is simply
        // the NEXT rail's header passing under translucent glass mid-scroll — which is iOS 26's
        // intended edge-to-edge scrolling, not an occlusion defect. This inset governs the END
        // of the scrollable content, which is the part that actually has to clear the bar, and
        // it does: card titles and years are clear at every Dynamic Type size.
        //
        // The real structural bug that surfaced during that hunt was in MainView, where the
        // offline banner was a ZStack sibling with a full-height Spacer(); it is now an
        // .overlay so it cannot distort the container's sizing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
          Color.clear.frame(height: tabBarClearance)
        }
      }
    }
    .preferredColorScheme(.dark)
    .navigationTitle("Home")
    // On Cinematic the hero owns the top edge — hide the nav bar so the backdrop runs
    // full-bleed under the status bar. Flat themes keep the standard "Home" title.
    .toolbar(ThemeHolder.shared.current.usesCinematicChrome ? .hidden : .automatic, for: .navigationBar)
    // Keyed on sessionToken — the iOS counterpart of the tvOS fix in 0d240c8.
    //
    // RootView swaps the login screen for this view when a token appears. A bare `.task` is
    // not guaranteed to re-fire across that swap if SwiftUI reuses the container's identity,
    // which on tvOS left the home rails permanently empty after pairing — a bug that shipped
    // to a real device. Keying on the token also re-runs the load after a session expiry and
    // re-login, instead of leaving the previous session's (or an empty) rail set on screen.
    .task(id: appState.sessionToken) { await appState.homeLoad() }
    .refreshable { await appState.homeForceRefresh() }
    // TASK-302: announce to VoiceOver once when content rails first appear
    .onChange(of: appState.homeJustAdded) { _, new in
      guard !new.isEmpty, !hasAnnouncedContent else { return }
      hasAnnouncedContent = true
      AccessibilityNotification.ScreenChanged(nil).post()
    }
    .onReceive(NotificationCenter.default.publisher(for: .playerDidDismiss)) { _ in
      loadLog.info("LibraryHomeView: playerDidDismiss — refreshing progress from local store")
      guard !appState.homeAllRailsEmpty || !appState.homeLibraries.isEmpty else { return }
      // Call refreshProgressFromLocal directly instead of routing through homeRefreshProgress()
      // (which is a no-op when homeIsBackgroundRefreshing is true). This ensures Continue
      // Watching updates immediately after playback rather than waiting up to 30s (TASK-435).
      Task { await appState.refreshProgressFromLocal() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .networkDidReconnect)) { _ in
      loadLog.info("LibraryHomeView: networkDidReconnect — triggering homeLoad")
      Task { await appState.homeLoad() }
    }
    // TASK-787: foreground revalidate+refresh is now owned solely by the app-level
    // scenePhase handler (DS_Video_cloneApp → appState.foregroundReconnectAndRefresh()).
    // The duplicate handler that lived here raced the same home-* flags on the same
    // .active event; it has been removed. networkDidReconnect (above) still drives a
    // homeLoad when the coordinator switches address.
    .background(Color.black.ignoresSafeArea())
    // Global search entry point.
    //
    // iPhone dropped the Search TAB to stay at five and avoid the system "More" collapse,
    // which left SearchView — a debounced, server-backed search with recent-search history
    // — instantiated ONLY in the iPad sidebar. On iPhone the sole search was a per-library
    // sheet filtering the already-loaded page in memory, so answering "do I have this film?"
    // required knowing whether it was a movie or a show first. The screen shipped in the
    // binary and could not be opened.
    //
    // A toolbar item is not enough on its own: Cinematic hides the nav bar entirely
    // (see .toolbar above), so the button is ALSO rendered as a floating overlay on that
    // theme. Exactly one of the two is live for any given theme.
    .toolbar {
      if !ThemeHolder.shared.current.usesCinematicChrome {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink { SearchView(isEmbedded: true) } label: {
            Image(systemName: "magnifyingglass")
          }
          .accessibilityLabel("Search")
          .accessibilityHint("Search all movies and TV shows")
        }
      }
    }
    .overlay(alignment: .topTrailing) {
      if ThemeHolder.shared.current.usesCinematicChrome {
        NavigationLink { SearchView(isEmbedded: true) } label: {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Search")
        .accessibilityHint("Search all movies and TV shows")
        .padding(.trailing, 16)
        .padding(.top, 8)
      }
    }

    if isEmbedded {
      content
    } else {
      NavigationStack { content }
    }
  }
}

// MARK: - ContinueWatchingCard (landscape 200×120)

private struct ContinueWatchingCard: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      Group {
        if appState.isDemoMode, let assetName = DemoData.posterAssetNames[item.id] {
          Image(assetName)
            .resizable()
            .scaledToFill()
        } else if let backdropId = item.backdropImageId ?? item.posterImageId {
          // 200x120 card. 500 is the top of the server's ladder before it falls back
          // to serving the full-resolution original — the right cap for a thumbnail
          // this size, and what `width: 400` was already being rounded up to.
          AuthenticatedImage(
            url: appState.api.imageURL(id: backdropId, width: 500),
            token: appState.sessionToken,
            usesTunnelCookie: appState.api.usesTunnelCookie
          )
          .scaledToFill()
        } else {
          Rectangle()
            .fill(Color(white: 0.1))
            .overlay(
              Image(systemName: "play.rectangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityHidden(true)
            )
        }
      }
      .frame(width: 200, height: 120)
      .clipped()

      // Gradient + title overlay
      LinearGradient(
        stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.8), location: 1.0)],
        startPoint: .top, endPoint: .bottom
      )
      .frame(width: 200, height: 120)

      // TASK-883: the title must stay legible at accessibility text sizes.
      //
      // The card is a fixed 200x120 and this title is a ZStack overlay pinned to the bottom.
      // At AX5 two lines of .caption grew far taller than the gradient behind them, so white
      // text landed directly on bare poster art — on a light poster (The Thin Man Goes Home)
      // it was unreadable. That is a contrast failure, not just overflow.
      //
      // Two guards: cap Dynamic Type growth for this label (the card cannot grow with it),
      // and give the text its own opaque backing sized to the text itself, so whatever the
      // final height, the title is always drawn on a dark surface rather than on artwork.
      Text(item.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 200, alignment: .leading)
        .background(Color.black.opacity(0.75))
        .padding(.bottom, 2)

      // Progress bar
      if let progress = item.progress, progress.durationSeconds > 0 {
        let frac = min(1.0, Double(progress.positionSeconds) / Double(progress.durationSeconds))
        if frac < 1.0 {
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Rectangle().fill(Color.dsBorderStrong).frame(height: 3)
              Rectangle().fill(Color.dsAccent).frame(width: geo.size.width * frac, height: 3)
            }
          }
          .frame(height: 3)
          .accessibilityHidden(true)
        }
      }
    }
    .frame(width: 200, height: 120)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    // Ambient elevation on the Cinematic theme; no-op on flat themes.
    .dsCardDepth(cornerRadius: 10)
    // TASK-693/698: redact in app switcher / screen recordings.
    .privacySensitive()
    #if os(iOS)
    .hoverEffect(.highlight)
    #endif
  }
}

// MARK: - HomeRail

private struct HomeRail: View {
  @Environment(AppState.self) private var appState
  let title: String
  let items: [ItemSummary]
  let seeAllLibrary: Library?
  var useLandscapeCards: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Header row
      HStack {
        Text(title)
          .font(.title3.weight(.bold))
          .foregroundStyle(.white)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        if let lib = seeAllLibrary {
          NavigationLink("See All") {
            ItemsGridView(library: lib)
          }
          .font(.subheadline.weight(.medium))
          .foregroundStyle(Color.dsTextSecondary)
          .padding(.vertical, 12)
          .padding(.horizontal, 8)
          .contentShape(Rectangle())
          .accessibilityLabel("See all in \(title)")
        }
      }
      .padding(.horizontal, 16)

      // Horizontal scroll of poster/landscape cards
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 10) {
          ForEach(items) { item in
            // Determine whether this item is a TV episode
            let showId = item.showFolderId ?? item.showName
            let isEpisode = showId != nil && !showId!.isEmpty
            let tvLibrary = appState.homeFirstTVLibrary

            if useLandscapeCards {
              if isEpisode, let showId, let tvLibrary {
                // Continue Watching — TV episode: go to show detail page with the episode's
                // season pre-selected so the user can play the next episode or browse.
                let displayTitle = item.showName ?? showId
                let stub = TVShow(
                  id: showId, title: displayTitle, year: item.year,
                  seasonCount: nil, episodeCount: nil,
                  posterImageId: item.posterImageId,
                  lastWatchedAt: nil, addedAt: nil
                )
                NavigationLink {
                  TVShowDetailView(show: stub, library: tvLibrary,
                                   highlightEpisodeID: item.id,
                                   highlightSeason: item.seasonNumber)
                } label: {
                  ContinueWatchingCard(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((item.showName ?? showId) + (item.year.map { ", \($0)" } ?? ""))
                .accessibilityHint("Opens TV show")
              } else {
                // Continue Watching — movie: go directly to playback
                NavigationLink {
                  ItemDetailView(itemID: item.id, fallbackTitle: item.title, autoPlay: true)
                } label: {
                  ContinueWatchingCard(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title + (item.year.map { ", \($0)" } ?? ""))
                .accessibilityHint("Plays video")
              }
            } else if isEpisode, let showId, let tvLibrary {
              // Recently Watched / Just Added rail — episode: navigate to show page
              let displayTitle = item.showName ?? showId
              let displayItem = ItemSummary(
                id: item.id, type: item.type, title: displayTitle, year: item.year,
                durationSeconds: item.durationSeconds, addedAt: item.addedAt,
                rating: item.rating, posterImageId: item.posterImageId,
                backdropImageId: item.backdropImageId
              )
              let stub = TVShow(
                id: showId, title: displayTitle, year: item.year,
                seasonCount: nil, episodeCount: nil,
                posterImageId: item.posterImageId,
                lastWatchedAt: nil, addedAt: nil
              )
              NavigationLink {
                TVShowDetailView(show: stub, library: tvLibrary)
              } label: {
                ItemPosterCell(item: displayItem)
                  .frame(width: 110)
                  .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              }
              .buttonStyle(.plain)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(displayTitle + (item.year.map { ", \($0)" } ?? ""))
              .accessibilityHint("Opens TV show")
            } else {
              NavigationLink {
                ItemDetailView(itemID: item.id, fallbackTitle: item.title)
              } label: {
                ItemPosterCell(item: item)
                  .frame(width: 110)
                  .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              }
              .buttonStyle(.plain)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(item.title + (item.year.map { ", \($0)" } ?? ""))
              .accessibilityHint("Opens video details")
            }
          }
        }
        .padding(.horizontal, 16)
      }
    }
    // Warm the cache for this rail's posters as soon as the rail exists, so the cards
    // beyond the initial visible two or three are already decoded by the time they
    // scroll in. Keyed on item IDs: re-fires when the rail's contents change (sync
    // landing new items), not on every re-render.
    .task(id: items.map(\.id).joined(separator: ",")) {
      ImagePrefetcher.prefetch(
        urls: items.map { item in
          if useLandscapeCards {
            let backdropId = item.backdropImageId ?? item.posterImageId
            return backdropId.flatMap { appState.api.imageURL(id: $0, width: 500) }
          }
          // Must match ItemPosterCell's request exactly (342 = 110pt @3x on the
          // server's ladder) or the prefetched bytes land under a different cache
          // key and the cell still starts grey.
          return item.posterImageId.flatMap {
            appState.api.imageURL(id: $0, width: 342, version: item.changeSeq)
          }
        },
        token: appState.sessionToken,
        usesTunnelCookie: appState.api.usesTunnelCookie
      )
    }
  }
}
