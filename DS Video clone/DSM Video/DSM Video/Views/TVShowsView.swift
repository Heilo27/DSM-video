import SwiftUI
import os.log

private let tvLog = Logger(subsystem: "com.dsm.dsvideo", category: "TVShows")

// MARK: - Sort Option

enum TVShowSortOption: String, CaseIterable {
  case recentlyWatched = "Recently Watched"
  case addedNewest     = "Recently Added"
  case addedOldest     = "Oldest Added"
  case nameAsc         = "Name A–Z"
  case nameDesc        = "Name Z–A"
  case releaseNewest   = "Release Year ↓"
  case releaseOldest   = "Release Year ↑"

  var chipLabel: String {
    switch self {
    case .recentlyWatched: return "Watched"
    case .addedNewest:     return "Added ↓"
    case .addedOldest:     return "Added ↑"
    case .nameAsc:         return "A → Z"
    case .nameDesc:        return "Z → A"
    case .releaseNewest:   return "Year ↓"
    case .releaseOldest:   return "Year ↑"
    }
  }

  /// The option to toggle to when this option is tapped while already selected.
  var toggled: TVShowSortOption? {
    switch self {
    case .addedNewest:    return .addedOldest
    case .addedOldest:    return .addedNewest
    case .nameAsc:        return .nameDesc
    case .nameDesc:       return .nameAsc
    case .releaseNewest:  return .releaseOldest
    case .releaseOldest:  return .releaseNewest
    default:              return nil
    }
  }

  /// The canonical "primary" of a toggle pair — used to decide which chip to show.
  var primaryOfPair: TVShowSortOption {
    switch self {
    case .addedOldest:   return .addedNewest
    case .nameDesc:      return .nameAsc
    case .releaseOldest: return .releaseNewest
    default:             return self
    }
  }

  /// Chips to display (de-duplicated: show primary of each pair, hide the secondary).
  static var displayedChips: [TVShowSortOption] {
    [.recentlyWatched, .addedNewest, .nameAsc, .releaseNewest]
  }
}

// MARK: - TVShowsView

/// Focus targets for the `dsPrimaryButton`s on the shows screen's error and empty states.
enum ShowsControl: Hashable {
  case retry, refresh
}

struct TVShowsView: View {
  @FocusState private var control: ShowsControl?
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let library: Library

  @State private var shows: [TVShow] = []
  @State private var isLoading = false
  @State private var error: String?
  @State private var sortOption: TVShowSortOption = {
    let raw = UserDefaults.standard.string(forKey: "dsReel.tvSortOption") ?? ""
    return TVShowSortOption(rawValue: raw) ?? .recentlyWatched
  }()
  @State private var sortedShows: [TVShow] = []
  @State private var showSearchSheet: Bool = false

  // A `searchText` filter lived here but nothing ever assigned it — per-library search
  // is a sheet that owns its own state and navigates directly, so this never filtered
  // and the "No Results" branches over it were unreachable.
  private var displayedShows: [TVShow] { sortedShows }

  #if os(tvOS)
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 28)] }
  #else
  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: .dsSpaceMD)]
  }
  #endif

  private func computeSortedShows() -> [TVShow] {
    switch sortOption {
    case .recentlyWatched:
      shows.sorted { a, b in
        // ISO8601 strings (yyyy-MM-ddTHH:mm:ssZ) sort correctly with lexicographic >.
        // Nil/empty sorts to the bottom (unwatched shows appear last).
        let aDate = a.lastWatchedAt ?? ""
        let bDate = b.lastWatchedAt ?? ""
        if aDate.isEmpty && bDate.isEmpty {
          return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        if aDate.isEmpty { return false }
        if bDate.isEmpty { return true }
        return aDate > bDate
      }
    case .addedNewest:
      // ISO8601 strings sort correctly with lexicographic >. Nil sorts to the bottom.
      shows.sorted { ($0.addedAt ?? "") > ($1.addedAt ?? "") }
    case .addedOldest:
      // ISO8601 strings sort correctly with lexicographic <. Nil/empty sorts to the BOTTOM.
      shows.sorted {
        let a = $0.addedAt ?? ""
        let b = $1.addedAt ?? ""
        if a.isEmpty && b.isEmpty { return false }
        if a.isEmpty { return false }  // nil sorts last
        if b.isEmpty { return true }
        return a < b
      }
    case .nameAsc:
      shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .nameDesc:
      shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
    case .releaseNewest:
      shows.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    case .releaseOldest:
      shows.sorted { ($0.year ?? Int.max) < ($1.year ?? Int.max) }
    }
  }

  var body: some View {
    ScrollView {
      if isLoading && shows.isEmpty {
        ProgressView("Loading TV shows")
          #if os(tvOS)
          .padding(.top, .dsSpaceTitleSafe)
          #else
          .padding(.top, .dsSpaceXXL)
          #endif
      } else if let error {
        VStack(spacing: .dsSpaceXXL) {
          DSContentUnavailable(
            title: "Couldn't load shows",
            systemImage: "exclamationmark.triangle",
            description: error
          )
          Button("Retry") {
            Task { await load() }
          }
          .dsPrimaryButton(.card, minWidth: 240)
          .focused($control, equals: .retry)
        }
        #if os(tvOS)
        .padding(.top, .dsSpaceTitleSafe)
        #else
        .padding(.top, .dsSpaceXXL)
        #endif
      } else if shows.isEmpty {
        VStack(spacing: .dsSpaceXXL) {
          if let profile = appState.activeProfile, profile.isRestricted {
            // FR-265: the list is filtered by the profile's level.
            RestrictedEmptyState(profile: profile, place: library.title)
          } else {
            DSContentUnavailable(
              title: "No TV Shows",
              systemImage: "tv",
              description: "No TV shows found in this library."
            )
          }
          // TASK-799: give the empty state a focusable action so tvOS focus has a home.
          Button("Refresh") {
            Task { await load() }
          }
          .dsPrimaryButton(.card, minWidth: 240)
          .focused($control, equals: .refresh)
        }
        #if os(tvOS)
        .padding(.top, .dsSpaceColossal)
        #else
        .padding(.top, .dsSpaceTitleSafe)
        #endif
      } else {
        #if os(tvOS)
        // (an unreachable "No Results" branch wrapped this grid — see displayedShows)
        LazyVGrid(columns: columns, spacing: 44) {
          // Keyed on POSITION, never on server content. gridID (id + title) was the
          // previous answer and it collided too: a part-matched folder emits two
          // entries agreeing on both fields, and the grid then dropped shows — four
          // duplicated and Star Trek: The Next Generation gone outright on a real
          // Apple TV. Any content-derived key can collide; an offset cannot, so the
          // grid now renders exactly as many cells as it was sent. Detail navigation
          // still uses show.id for the API lookup.
          ForEach(displayedShows.identified) { item in
            let show = item.value
            NavigationLink {
              TVShowDetailView(show: show, library: library)
            } label: {
              TVShowPosterCell(show: show)
            }
            .buttonStyle(.card)
            .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")\(show.seasonCount.map { ", \($0) season\($0 == 1 ? "" : "s")" } ?? "")")
            .accessibilityHint("Opens show details")
          }
        }
        .privacySensitive()
        .padding(.horizontal, .dsSpaceTitleSafe)
        .padding(.vertical, .dsSpaceHuge)
        #else
        // (an unreachable "No Results" branch wrapped this grid — see displayedShows)
        LazyVGrid(columns: columns, spacing: .dsSpaceMD) {
          // Keyed on POSITION — see the tvOS branch above. gridID collided whenever
          // two rows agreed on id AND title, which silently removed shows from the
          // grid. An offset cannot collide, so every show the server sends renders.
          ForEach(displayedShows.identified) { item in
            let show = item.value
            NavigationLink {
              TVShowDetailView(show: show, library: library)
            } label: {
              TVShowPosterCell(show: show)
            }
            // dsPressable() draws its own pressed state: press-scale on Cinematic, an
            // opacity dim on flat themes (the dim .plain gave), and a dimmed disabled look.
            .dsPressable()
            .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens show details")
          }
        }
        .padding(horizontalSizeClass == .regular ? 20 : 12)
        #endif
      }
    }
    .background(Color.dsBackground.ignoresSafeArea())
    .navigationTitle(library.title)
    #if !os(tvOS)
    // Force white nav-bar content (the large title was rendering dim grey on black).
    .toolbarColorScheme(.dark, for: .navigationBar)
    #endif
    // Keyed on the library id, NOT a bare .task.
    //
    // On iPad/macOS the sidebar swaps libraries inside SplitView.detailContent
    // (MainView.swift:110-132) without changing the view TYPE or its position, so SwiftUI
    // reuses this view in place. A bare `.task` does not re-fire on that swap: selecting
    // Movies after TV Shows left the previous library's items on screen.
    //
    // Same defect class as TVMainView's homeLoad (0d240c8), which shipped to a real Apple TV
    // and left the home rails permanently empty, and PlayerSheet (TASK-838).
    .task(id: library.id) { await load() }
    #if !os(tvOS)
    // Search is a magnifying-glass button in the nav bar that presents a search
    // sheet, now that the dedicated Search tab is gone.
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { showSearchSheet = true } label: {
          Image(systemName: "magnifyingglass")
              .dsToolbarIcon()
        }
        .accessibilityLabel("Search TV shows")
      }
    }
    .sheet(isPresented: $showSearchSheet) {
      LibrarySearchSheet(
        title: "Search TV shows",
        items: sortedShows,
        filter: { show, q in show.title.localizedCaseInsensitiveContains(q) }
      ) { show in
        TVShowDetailView(show: show, library: library)
      } rowLabel: { show in
        AnyView(
          HStack(spacing: .dsSpaceMD) {
            TVShowPosterCell(show: show).frame(width: 46)
            VStack(alignment: .leading, spacing: .dsSpaceXXS) {
              Text(show.title).foregroundStyle(.white).lineLimit(1)
              if let y = show.year {
                Text(String(y)).font(.caption).foregroundStyle(Color.dsTextSecondary)
              }
            }
            Spacer()
          }
        )
      }
    }
    .refreshable {
      await load()
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      TVShowSortChipBar(selection: $sortOption)
    }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.tvSortOption")
      sortedShows = computeSortedShows()
    }
    .onChange(of: shows) { _, _ in
      sortedShows = computeSortedShows()
    }
    .onAppear {
      sortedShows = computeSortedShows()
      if shows.isEmpty && !isLoading {
        Task { await load() }
      }
    }
    #else
    // tvOS: same fix as the Movies grid — render the real TVShowSortChipBar as a focusable
    // row instead of four Buttons inside ToolbarItem(placement: .topBarTrailing), a
    // placement tvOS does not render. Those buttons compiled fine and were never visible,
    // leaving the TV Shows grid permanently stuck on its default sort with no way to change it.
    .safeAreaInset(edge: .top, spacing: 0) {
      TVShowSortChipBar(selection: $sortOption)
    }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.tvSortOption")
      sortedShows = computeSortedShows()
    }
    .onChange(of: shows) { _, _ in
      sortedShows = computeSortedShows()
    }
    .onAppear {
      sortedShows = computeSortedShows()
      if shows.isEmpty && !isLoading {
        Task { await load() }
      }
    }
    #endif
  }

  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      shows = DemoData.tvShows
      return
    }
    tvLog.info("TVShowsView.load: libraryId=\(library.id) baseURL=[server]")
    isLoading = true
    defer { isLoading = false }
    do {
      let response = try await appState.api.tvShows(libraryId: library.id)
      tvLog.info("TVShowsView.load: success — \(response.shows.count) shows")
      shows = response.shows
      error = nil
    } catch is CancellationError {
      // View disappeared before load completed — not an error, task will retry on re-appear.
      tvLog.debug("TVShowsView.load: cancelled (view disappeared)")
    } catch {
      // Also swallow URLSession cancellation (-999) which fires when SwiftUI cancels a .task
      let nsErr = error as NSError
      if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
        tvLog.debug("TVShowsView.load: URLSession cancelled (view disappeared)")
        return
      }
      tvLog.error("TVShowsView.load: FAILED — \(String(describing: error))")
      let msg = (error as? APIError)?.userMessage ?? "Unknown error."
      if shows.isEmpty { self.error = msg }
    }
  }
}

// MARK: - Sort Chip Bar (iOS/macOS only)

// Available on tvOS too: this was #if !os(tvOS), which is why the TV Shows grid had no
// sort control at all — the tvOS branch above referenced a type that did not exist for it.
private struct TVShowSortChipBar: View {
  @Binding var selection: TVShowSortOption

  var body: some View {
    // A20: shared SortChip component — same pill radius + styling as the Movies grid.
    SortChipScroller {
      ForEach(TVShowSortOption.displayedChips, id: \.self) { chip in
        let isActive = selection.primaryOfPair == chip
        SortChip(
          label: isActive ? selection.chipLabel : chip.chipLabel,
          isActive: isActive,
          accessibilityLabel: "Sort by \(chip.rawValue)"
        ) {
          if isActive, let next = selection.toggled {
            selection = next
          } else {
            selection = chip
          }
        }
      }
    }
  }
}

// MARK: - Poster Cell

private struct TVShowPosterCell: View {
  @Environment(AppState.self) private var appState
  let show: TVShow

  var body: some View {
    // PosterCard fixes the 2:3 size from the column width alone, so the cell never depends
    // on the poster or the title. That is what stops a late-loading image from collapsing
    // the cell to the title height (the "blank spot") or growing it mid-scroll and shoving
    // everything below it down (the "Daredevil glitches and slides into the blank spot"
    // reflow).
    PosterCard { width, height in
      // Poster image — fills the anchored frame and clips. Filling a fixed frame
      // (not .scaledToFill() on an unconstrained image) also stops wide/landscape
      // posters from overflowing and covering neighbouring cells.
      Color.dsSurface
        .overlay {
          if appState.isDemoMode, let assetName = DemoData.posterAssetNames[show.id] {
            Image(assetName)
              .resizable()
              .scaledToFill()
          } else if let id = show.posterImageId {
            AuthenticatedImage(
              url: appState.api.imageURL(id: id, width: 400, version: show.metadataVersion),
              token: appState.sessionToken,
              usesTunnelCookie: appState.api.usesTunnelCookie
            )
            .scaledToFill()
          } else {
            Image(systemName: "tv.fill")
              .font(.system(size: 36))
              .foregroundStyle(.white.opacity(0.25))
              .accessibilityHidden(true)
          }
        }
        .frame(width: width, height: height)
        .clipped()
    } footer: {
      // Title + season label
      VStack(alignment: .leading, spacing: .dsSpaceXS) {
        Text(show.title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.white)
          .lineLimit(2)
          .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

        Text(seasonLabel(show))
          .font(.footnote)
          .foregroundStyle(Color.dsTextSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
    }
  }

  private func seasonLabel(_ show: TVShow) -> String {
    guard let sc = show.seasonCount else { return "" }
    if sc == 1, let ec = show.episodeCount {
      return "\(ec) episode\(ec == 1 ? "" : "s")"
    }
    return "\(sc) season\(sc == 1 ? "" : "s")"
  }
}
