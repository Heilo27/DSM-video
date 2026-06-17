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

struct TVShowsView: View {
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
  @State private var searchText: String = ""
  @State private var showSearchSheet: Bool = false

  private var displayedShows: [TVShow] {
    guard !searchText.isEmpty else { return sortedShows }
    return sortedShows.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
  }

  #if os(tvOS)
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 28)] }
  #else
  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
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
          .padding(.top, 60)
          #else
          .padding(.top, 24)
          #endif
      } else if let error {
        VStack(spacing: 24) {
          ContentUnavailableView(
            "Couldn't load shows",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
          Button("Retry") {
            Task { await load() }
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.dsAccent)
        }
        #if os(tvOS)
        .padding(.top, 60)
        #else
        .padding(.top, 24)
        #endif
      } else if shows.isEmpty {
        ContentUnavailableView(
          "No TV Shows",
          systemImage: "tv",
          description: Text("No TV shows found in this library.")
        )
        #if os(tvOS)
        .padding(.top, 80)
        #else
        .padding(.top, 60)
        #endif
      } else {
        #if os(tvOS)
        if displayedShows.isEmpty && !searchText.isEmpty {
          ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No shows match \"\(searchText)\"")
          )
          .foregroundStyle(.white)
          .padding(.top, 60)
        } else {
          LazyVGrid(columns: columns, spacing: 44) {
            // Key on gridID (id + title), NOT id: two distinct shows can share one
            // folder and therefore an `id` (e.g. both Daredevils under Daredevil/),
            // which would collapse the duplicate cells and blank one. Matches the iOS
            // branch; detail navigation still uses show.id for the API lookup.
            ForEach(displayedShows, id: \.gridID) { show in
              NavigationLink {
                TVShowDetailView(show: show, library: library)
              } label: {
                TVShowPosterCell(show: show)
              }
              .buttonStyle(.card)
              .id(show.gridID)
              .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")\(show.seasonCount.map { ", \($0) season\($0 == 1 ? "" : "s")" } ?? "")")
              .accessibilityHint("Opens show details")
            }
          }
          .privacySensitive()
          .padding(.horizontal, 60)
          .padding(.vertical, 48)
        }
        #else
        if displayedShows.isEmpty && !searchText.isEmpty {
          ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No shows match \"\(searchText)\"")
          )
          .foregroundStyle(.white)
          .padding(.top, 60)
        } else {
          LazyVGrid(columns: columns, spacing: 12) {
            // Key on gridID (id + title), NOT id: two distinct shows can share a
            // folder and therefore an `id` (e.g. both Daredevils under Daredevil/).
            // A grid keyed on the duplicate id collapses those cells and one renders
            // black depending on scroll position — the "Daredevil blanks when too much
            // in view" bug. gridID makes each show a distinct cell; detail navigation
            // still uses show.id for the seasons/episodes API lookup.
            ForEach(displayedShows, id: \.gridID) { show in
              NavigationLink {
                TVShowDetailView(show: show, library: library)
              } label: {
                TVShowPosterCell(show: show)
              }
              .buttonStyle(.plain)
              .id(show.gridID)
              .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")")
              .accessibilityHint("Opens show details")
            }
          }
          .padding(horizontalSizeClass == .regular ? 20 : 12)
        }
        #endif
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(library.title)
    #if !os(tvOS)
    // Force white nav-bar content (the large title was rendering dim grey on black).
    .toolbarColorScheme(.dark, for: .navigationBar)
    #endif
    .task {
      await load()
    }
    #if !os(tvOS)
    // Search is a magnifying-glass button in the nav bar that presents a search
    // sheet, now that the dedicated Search tab is gone.
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { showSearchSheet = true } label: {
          Image(systemName: "magnifyingglass")
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
          HStack(spacing: 12) {
            TVShowPosterCell(show: show).frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
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
    .searchable(text: $searchText, prompt: "Search TV shows")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        HStack(spacing: 12) {
          // Recently Watched
          Button {
            sortOption = .recentlyWatched
            UserDefaults.standard.set(sortOption.rawValue, forKey: "dsReel.tvSortOption")
            sortedShows = computeSortedShows()
          } label: {
            Label("Watched", systemImage: "play.circle")
          }
          .tint(sortOption == .recentlyWatched ? Color.dsAccent : .white)
          .accessibilityLabel("Sort by recently watched")

          // A→Z toggle
          Button {
            sortOption = (sortOption == .nameAsc) ? .nameDesc : .nameAsc
            UserDefaults.standard.set(sortOption.rawValue, forKey: "dsReel.tvSortOption")
            sortedShows = computeSortedShows()
          } label: {
            Label(
              sortOption == .nameAsc ? "Z→A" : "A→Z",
              systemImage: sortOption == .nameAsc ? "textformat.abc.dottedunderline" : "textformat.abc"
            )
          }
          .tint(sortOption == .nameAsc || sortOption == .nameDesc ? Color.dsAccent : .white)
          .accessibilityLabel(sortOption == .nameAsc ? "Sort Z to A" : "Sort A to Z")

          // Recently Added toggle
          Button {
            sortOption = (sortOption == .addedNewest) ? .addedOldest : .addedNewest
            UserDefaults.standard.set(sortOption.rawValue, forKey: "dsReel.tvSortOption")
            sortedShows = computeSortedShows()
          } label: {
            Label(
              sortOption == .addedOldest ? "Oldest First" : "Recently Added",
              systemImage: sortOption == .addedOldest ? "clock" : "clock.badge.checkmark"
            )
          }
          .tint(sortOption == .addedNewest || sortOption == .addedOldest ? Color.dsAccent : .white)
          .accessibilityLabel(sortOption == .addedOldest ? "Sort oldest first" : "Sort recently added first")

          // Release Year toggle
          Button {
            sortOption = (sortOption == .releaseNewest) ? .releaseOldest : .releaseNewest
            UserDefaults.standard.set(sortOption.rawValue, forKey: "dsReel.tvSortOption")
            sortedShows = computeSortedShows()
          } label: {
            Label(
              sortOption == .releaseOldest ? "Year ↑" : "Year ↓",
              systemImage: "calendar"
            )
          }
          .tint(sortOption == .releaseNewest || sortOption == .releaseOldest ? Color.dsAccent : .white)
          .accessibilityLabel(sortOption == .releaseOldest ? "Sort by oldest release year" : "Sort by newest release year")
        }
      }
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

#if !os(tvOS)
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
#endif

// MARK: - Poster Cell

private struct TVShowPosterCell: View {
  @Environment(AppState.self) private var appState
  let show: TVShow

  var body: some View {
    ZStack(alignment: .bottom) {
      // Size anchor: a content-independent 2:3 spacer defines the cell's frame so the
      // ZStack's height NEVER depends on the poster or title. Without this, the ZStack
      // took its size from its content — an unloaded AuthenticatedImage collapsed the
      // cell to the title height (the "blank spot"), and when the image loaded mid-
      // scroll the cell grew and shoved everything below it down (the "Daredevil
      // glitches and slides into the blank spot" reflow). The spacer makes every cell
      // identical and stable regardless of load state, so the grid can't reflow.
      Color.clear
        .aspectRatio(2.0 / 3.0, contentMode: .fit)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()

      // Bottom gradient
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.45),
          .init(color: .black.opacity(0.88), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
      )

      // Title + season label
      VStack(alignment: .leading, spacing: 4) {
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
    // The Color.clear spacer (first ZStack layer) fixes the 2:3 size; the ZStack
    // just fills the column width the grid hands it.
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func seasonLabel(_ show: TVShow) -> String {
    guard let sc = show.seasonCount else { return "" }
    if sc == 1, let ec = show.episodeCount {
      return "\(ec) episode\(ec == 1 ? "" : "s")"
    }
    return "\(sc) season\(sc == 1 ? "" : "s")"
  }
}
