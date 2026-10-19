import SwiftUI

enum SortOption: String, CaseIterable {
  case all          = "All"
  case addedNewest  = "Recently Added"
  case addedOldest  = "Oldest Added"
  case nameAsc      = "Name A–Z"
  case nameDesc     = "Name Z–A"
  case releaseNewest = "Release Year ↓"
  case releaseOldest = "Release Year ↑"
  case rating       = "Rating"

  var chipLabel: String {
    switch self {
    case .all:          return "All"
    case .addedNewest:  return "Added ↓"
    case .addedOldest:  return "Added ↑"
    case .nameAsc:      return "A → Z"
    case .nameDesc:     return "Z → A"
    case .releaseNewest: return "Year ↓"
    case .releaseOldest: return "Year ↑"
    case .rating:       return "Rating"
    }
  }
}

struct ItemsGridView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let library: Library

  /// Items, the library and filter they answer, and the last load failure (FR-098, TASK-975).
  @State private var content = LibraryGridContent()
  @State private var sortedItems: [ItemSummary] = []
  @State private var isLoading: Bool = false
  @State private var reloadRequested = false
  private var items: [ItemSummary] { content.items }
  private var error: String? { content.blockingError }
  @State private var sortOption: SortOption = {
    let raw = UserDefaults.standard.string(forKey: "dsReel.sortOption") ?? ""
    let stored = SortOption(rawValue: raw) ?? .addedNewest
    // .all no longer has a chip (removed for simplicity) — coerce any stale stored
    // value to the default so the chip bar always shows an active selection.
    return stored == .all ? .addedNewest : stored
  }()
  @State private var showSearchSheet: Bool = false
  // Genre filtering. Applied SERVER-side: filtering locally would only cover pages already
  // loaded, so on a 500-item library the filter would look right while missing most results.
  @State private var availableGenres: [GenreCount] = []
  @State private var selectedGenres: Set<String> = []
  @State private var genreMode: APIClient.GenreMode = .any

  // `searchText` state lived here with a filter over it, but nothing ever assigned it —
  // per-library search is a separate sheet that owns its own state and navigates
  // directly. The filter was a pass-through and its "No results" branch unreachable.
  private var displayedItems: [ItemSummary] { sortedItems }

  private func sorted(_ list: [ItemSummary], by option: SortOption) -> [ItemSummary] {
    switch option {
    case .all:           return list
    case .addedNewest:   return list.sorted { $0.addedAt > $1.addedAt }
    case .addedOldest:   return list.sorted { $0.addedAt < $1.addedAt }
    case .nameAsc:       return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .nameDesc:      return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
    case .releaseNewest: return list.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    case .releaseOldest: return list.sorted { ($0.year ?? Int.max) < ($1.year ?? Int.max) }
    case .rating:        return list.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
    }
  }

  #if os(tvOS)
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 280), spacing: .dsSpaceXXL)] }
  #else
  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: .dsSpaceMD)]
  }
  #endif

  var body: some View {
    ScrollView {
      if isLoading && items.isEmpty {
        ProgressView("Loading videos")
          #if os(tvOS)
          .padding(.top, .dsSpaceTitleSafe)
          #else
          .padding(.top, .dsSpaceXXL)
          #endif
      } else if let error {
        // FIX-18 / TASK-649: shared error+retry component.
        ErrorRetryView(title: "Couldn't load items", message: error) {
          Task { await load() }
        }
        .padding(.top, .dsSpaceXXL)
      } else {
        #if os(tvOS)
        let gridSpacing: CGFloat = 24
        let gridPadding: CGFloat = 48
        #else
        let gridSpacing: CGFloat = 12
        let gridPadding: CGFloat = horizontalSizeClass == .regular ? 20 : 12
        #endif
        // TASK-803 also had a "No Results" branch for an in-grid search filter here.
        // That filter never existed (see displayedItems) so the branch was unreachable;
        // search is a sheet that navigates rather than filtering this grid.
        if items.isEmpty && !isLoading && error == nil {
          // An active genre filter makes "This library has no videos yet" a false statement
          // about the LIBRARY — the filter bar above is still showing the chips that caused
          // the empty result, so the screen contradicted itself and blamed the wrong thing
          // (TASK-897 #3). Filtering is server-side, so `items` is empty in both cases and
          // only the filter state can tell them apart.
          if selectedGenres.isEmpty, let profile = appState.activeProfile, profile.isRestricted {
            // FR-265: on an age-limited profile the grid is filtered by the server, so an
            // empty one is about the profile's level, not the library.
            RestrictedEmptyState(profile: profile, place: library.title)
          } else if selectedGenres.isEmpty {
            DSContentUnavailable(
              title: "No Videos",
              systemImage: "film.stack",
              description: "This library has no videos yet."
            )
          } else {
            DSContentUnavailable(
              title: "No Matches",
              systemImage: "line.3.horizontal.decrease.circle",
              description: selectedGenres.count == 1
                ? "Nothing in this library matches \(selectedGenres.first ?? ""). Try a different genre."
                : (genreMode == .all
                   ? "Nothing matches all \(selectedGenres.count) genres at once. Try switching to Any, or removing one."
                   : "Nothing in this library matches those genres.")
            )
          }
        }
        LazyVGrid(columns: columns, spacing: gridSpacing) {
          #if os(tvOS)
          ForEach(displayedItems) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              ItemPosterCell(item: item)
            }
            .buttonStyle(.card)
            // TASK-745: collapse the cell's internal text/art into one element so the
            // explicit label (title, year, watched %) is what VoiceOver speaks.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(itemAccessibilityLabel(item))
            .accessibilityHint("Opens video details")
          }
          #else
          ForEach(displayedItems) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              ItemPosterCell(item: item)
            }
            // dsPressable() draws its own pressed state: press-scale on Cinematic, an
            // opacity dim on flat themes (the dim .plain gave), and a dimmed disabled look.
            .dsPressable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(itemAccessibilityLabel(item))
            .accessibilityHint("Opens video details")
          }
          #endif
        }
        .padding(gridPadding)

        #if !os(tvOS)
        // tvOS shows the count in TVLibraryHeading: after a LazyVGrid it overlapped row 2.
        if !displayedItems.isEmpty {
          Text("\(displayedItems.count) item\(displayedItems.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(Color.dsTextTertiary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, .dsSpaceLG)
            .accessibilityHidden(true)
        }
        #endif
      }
    }
    .background(alignment: .top) {
      // Themed ground + cinematic atmosphere streaks (no-op on flat themes, where
      // dsBackground is pure black and AtmosphereBackground renders nothing).
      ZStack(alignment: .top) {
        Color.dsBackground
        AtmosphereBackground().frame(height: 400)
      }
      .ignoresSafeArea()
    }
    #if !os(tvOS)
    .navigationTitle(library.title)
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
    .task(id: library.id) {
      await load()
      // Genres load after the grid so the content appears first; the filter bar populating
      // a moment later is fine, an empty grid waiting on a secondary request is not.
      if showsGenres { await loadGenres() }
    }
    // FR-262, AC-002-43: the active profile's age ceiling moved while this grid stayed open
    // (the picker does not show for a same-profile edit, so the view is not rebuilt). What it
    // holds was fetched under the old ceiling, so it goes at once and the server is asked again.
    // An unstructured Task on purpose: `.task(id:)` would cancel a load already in flight and the
    // cancelled loop could not run the reload; `load()` remembers the request (reloadRequested)
    // and the running loop repeats under the new profile header.
    .onChange(of: appState.profileContentVersion) {
      content = LibraryGridContent()
      sortedItems = []
      availableGenres = []
      Task {
        await load()
        if showsGenres { await loadGenres() }
      }
    }
    #if !os(tvOS)
    // Search is a magnifying-glass button in the nav bar that presents a search
    // sheet, now that the dedicated Search tab is gone.
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { showSearchSheet = true } label: {
          Image(systemName: "magnifyingglass")
              .dsToolbarIcon()
        }
        .accessibilityLabel("Search \(library.title)")
      }
    }
    .sheet(isPresented: $showSearchSheet) {
      LibrarySearchSheet(
        title: "Search \(library.title)",
        items: sortedItems,
        filter: { item, q in item.title.localizedCaseInsensitiveContains(q) }
      ) { item in
        ItemDetailView(itemID: item.id, fallbackTitle: item.title)
      } rowLabel: { item in
        AnyView(
          HStack(spacing: .dsSpaceMD) {
            ItemPosterCell(item: item).frame(width: 46)
            VStack(alignment: .leading, spacing: .dsSpaceXXS) {
              Text(item.title).foregroundStyle(.white).lineLimit(1)
              if let y = item.year {
                Text(String(y)).font(.caption).foregroundStyle(Color.dsTextSecondary)
              }
            }
            Spacer()
          }
        )
      }
    }
    .refreshable { await load() }
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        SortChipBar(selection: $sortOption)
        browseFilterBar
        refreshNoticeBar
        if !items.isEmpty && appState.isServerUnavailable {
          Text("Showing cached content")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, .dsSpaceXS)
            .background(Color.dsBackground)
        }
      }
    }
    .onChange(of: items) { _, new in sortedItems = sorted(new, by: sortOption) }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.sortOption")
      sortedItems = sorted(items, by: new)
    }
    .onChange(of: selectedGenres) { _, _ in Task { await load() } }
    .onChange(of: genreMode) { _, _ in
      // Only re-query when the mode can actually change the result set.
      if selectedGenres.count >= 2 { Task { await load() } }
    }
    #else
    // tvOS: render the SAME SortChipBar the iOS branch uses, as a focusable row above the
    // grid. This branch previously put two sort buttons in
    // ToolbarItem(placement: .topBarTrailing) and called .searchable() — neither of which
    // tvOS renders. The controls existed in code and were invisible on screen, which is
    // why the TV had no way to change sort order. Same defect class as the player's
    // top-bar/transport overscan bug: written for iOS, compiled for tvOS, never displayed.
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        TVLibraryHeading(title: library.title, count: displayedItems.isEmpty ? nil : displayedItems.count)
        SortChipBar(selection: $sortOption)
        browseFilterBar
        refreshNoticeBar
      }
    }
    .onChange(of: items) { _, new in sortedItems = sorted(new, by: sortOption) }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.sortOption")
      sortedItems = sorted(items, by: new)
    }
    .onChange(of: selectedGenres) { _, _ in Task { await load() } }
    .onChange(of: genreMode) { _, _ in
      if selectedGenres.count >= 2 { Task { await load() } }
    }
    #endif
  }

  /// Kids' profiles browse by collections in place of the genre list (FRD-002 FR-270).
  /// Who is a kid is the server's answer (`Profile.kids`), never a level compared here.
  private var showsGenres: Bool {
    CollectionsBrowse.showsGenres(isKids: appState.activeProfile?.kids ?? false)
  }

  /// FR-098: a failed refresh with the grid still loaded. iOS and tvOS share it.
  @ViewBuilder private var refreshNoticeBar: some View {
    if let notice = content.noticeMessage {
      RefreshFailedNotice(message: notice) {
        Task { await load() }
      }
    }
  }

  @ViewBuilder private var browseFilterBar: some View {
    if showsGenres {
      GenreFilterBar(available: availableGenres, selected: $selectedGenres, mode: $genreMode)
    } else {
      CollectionChipBar()
    }
  }

  private func itemAccessibilityLabel(_ item: ItemSummary) -> String {
    var label = item.title
    if let year = item.year {
      label += ", \(year)"
    }
    // Same decision as the card's bar and badge (TASK-978): nothing is said at zero progress.
    switch PlaybackProgress.cardIndicator(for: item.progress) {
    case .none: break
    case .watchedBadge: label += ", watched"
    case .bar(let fraction): label += ", \(Int(fraction * 100)) percent watched"
    }
    return label
  }

  /// Loads the genre list for the picker.
  ///
  /// Separate from load() and deliberately failure-tolerant: genres are an enhancement, and
  /// a server too old to have /genres (or one whose library has no TMDb data yet) must still
  /// show a working grid. On failure the bar simply renders nothing.
  private func loadGenres() async {
    guard !appState.isDemoMode else { return }
    guard availableGenres.isEmpty else { return }
    if let resp = try? await appState.api.genres(libraryId: library.id) {
      availableGenres = resp.genres
    }
  }

  private var currentSelection: GenreSelection {
    GenreSelection(genres: selectedGenres, mode: genreMode)
  }

  private func load() async {
    // A request that arrives while one is running (a genre chip tapped mid-load) used to be
    // dropped, leaving the previous filter's grid under the new chips. Remember it and run again.
    if isLoading { reloadRequested = true; return }
    isLoading = true
    defer { isLoading = false }
    repeat {
      reloadRequested = false
      await loadOnce()
    } while reloadRequested
  }

  private func loadOnce() async {
    let libraryID = library.id
    if appState.isDemoMode {
      content.adopt(DemoData.items(for: library), libraryID: libraryID, requested: currentSelection)
      sortedItems = sorted(items, by: sortOption)
      return
    }

    let requested = currentSelection
    let result: Result<[ItemSummary], any Error>
    do {
      // Every id the server sends, once each (FR-082, TASK-976). No client-side title dedup.
      result = .success(try await LibraryPaging.loadAll { limit, offset in
        try await appState.api.items(
          libraryId: libraryID, limit: limit, offset: offset,
          genres: Array(requested.genres), genreMode: requested.mode)
      })
    } catch {
      // Classify the failure so session/offline state stays accurate (see ItemDetailView.load).
      appState.handleConnectionFailure(error)
      result = .failure(error)
    }
    content.finish(libraryID: libraryID, requested: requested, result: result)

    // Nothing usable on screen after a failure: try the on-device catalog before the error screen.
    if content.blockingError != nil, LibraryGridContent.cacheMayAnswer(requested) {
      let cached = await LocalStore.shared.fetchItems(forLibraryId: libraryID, limit: 5000)
      if !cached.isEmpty {
        // The offline banner (appState.isOffline / serverUnreachable) already says this is cached.
        content.adopt(cached, libraryID: libraryID, requested: requested)
      }
    }
    sortedItems = sorted(items, by: sortOption)
  }
}

// MARK: - Sort Chip Bar

/// A sort dimension that toggles direction when its chip is re-tapped. Some
/// dimensions (All, Rating) have no direction — a single tap selects them.
private struct SortDimension {
  let name: String              // base label, e.g. "Added"
  let ascending: SortOption?    // case for ascending / first-tap-reverse; nil = no direction
  let descending: SortOption    // case for descending / default first tap

  /// All cases this dimension owns (used to test whether it's the active group).
  var cases: [SortOption] { ascending.map { [descending, $0] } ?? [descending] }
}

private let movieSortDimensions: [SortDimension] = [
  SortDimension(name: "Added", ascending: .addedOldest,   descending: .addedNewest),
  SortDimension(name: "Name",  ascending: .nameDesc,      descending: .nameAsc),
  SortDimension(name: "Year",  ascending: .releaseOldest, descending: .releaseNewest),
  SortDimension(name: "Rating", ascending: nil,           descending: .rating),
]

private struct SortChipBar: View {
  @Binding var selection: SortOption

  var body: some View {
    // A20: render through the shared SortChip component (consistent pill radius + style).
    SortChipScroller {
      ForEach(movieSortDimensions, id: \.name) { dim in
        SortDimensionChip(dimension: dim, selection: $selection)
      }
    }
  }
}

/// One chip per sort dimension. First tap selects (descending). If already
/// selected and the dimension has a direction, the next tap flips ascending↔descending.
private struct SortDimensionChip: View {
  let dimension: SortDimension
  @Binding var selection: SortOption

  private var isActive: Bool { dimension.cases.contains(selection) }
  private var isAscending: Bool { dimension.ascending == selection }

  private var label: String {
    guard dimension.ascending != nil else { return dimension.name }      // no-direction chip
    guard isActive else { return dimension.name }                        // inactive: bare name
    return "\(dimension.name) \(isAscending ? "↑" : "↓")"
  }

  var body: some View {
    SortChip(
      label: label,
      isActive: isActive,
      accessibilityLabel: isActive && dimension.ascending != nil
        ? "Sorted by \(dimension.name), \(isAscending ? "ascending" : "descending"). Tap to reverse."
        : "Sort by \(dimension.name)"
    ) {
      if isActive, let asc = dimension.ascending {
        // Re-tap on the active directional chip flips direction.
        selection = isAscending ? dimension.descending : asc
      } else {
        // First tap selects the default (descending) direction.
        selection = dimension.descending
      }
    }
  }
}

struct ItemPosterCell: View {
  @Environment(AppState.self) private var appState
  // Native scale of the screen this cell is on, so the requested width covers the
  // pixels actually drawn. Stable for the life of the view on a given display, so it
  // does not churn the image URL (which is also the cache key and the load identity).
  @Environment(\.displayScale) private var displayScale
  let item: ItemSummary

  // Clamped: displayScale is 1 in some previews/offscreen renders, which would
  // request a 92px poster for a full-size cell. Never go below 2.
  private var posterScale: CGFloat { max(displayScale, 2) }

  var body: some View {
    PosterCard(indicator: PlaybackProgress.cardIndicator(for: item.progress)) { width, height in
      posterImage(width: width, height: height)
    } footer: {
      cellFooter
    }
    #if !os(tvOS)
    .downloadStatus(itemID: item.id)   // TASK-983 · FR-041/FR-133
    #endif
    #if os(iOS)
    // iPad trackpad/pointer affordance — lifts the poster on hover.
    .hoverEffect(.highlight)
    #endif
  }

  @ViewBuilder
  private func posterImage(width: CGFloat, height: CGFloat) -> some View {
    if appState.isDemoMode, let assetName = DemoData.posterAssetNames[item.id] {
      Image(assetName)
        .resizable()
        .scaledToFill()
        .frame(width: width, height: height, alignment: .top)
        .clipped()
    } else if item.posterImageId != nil {
      // Size the request to the cell that draws it. This view is used from 46pt
      // (search results) up to full grid cells, so a fixed literal either starves the
      // big ones or — as `width: 400` did — pulls a 500px poster for a 110pt rail
      // card. Over-fetching lengthens each request, which is what widens the window
      // where a mid-flight cancellation can strand the cell grey.
      AuthenticatedImage(
        url: appState.api.imageURL(
          id: item.posterImageId ?? item.id,
          width: APIClient.ladderWidth(forPointWidth: width, scale: posterScale),
          version: item.changeSeq
        ),
        token: appState.sessionToken,
        usesTunnelCookie: appState.api.usesTunnelCookie
      )
      .scaledToFill()
      .frame(width: width, height: height, alignment: .top)
      .clipped()
    } else {
      Rectangle()
        .fill(Color.dsSurface)
        .frame(width: width, height: height)
        .overlay(
          Image(systemName: "film.fill")
            .font(.system(size: 36))
            .foregroundStyle(.white.opacity(0.25))
            .accessibilityHidden(true)
        )
    }
  }

  @ViewBuilder
  private var cellFooter: some View {
    VStack(alignment: .leading, spacing: .dsSpaceXXS) {
      Text(item.title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

      if let year = item.year {
        Text(String(year))
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.75))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, .dsSpaceSM)
    .padding(.bottom, .dsSpaceSM)
    // TASK-857: cap scaling at .accessibility1. The card frame is a fixed 2:3 aspect ratio
    // that does not grow with the text, so past this point the footer stops gaining
    // legibility and only eats poster area — at AX5 it climbed over the artwork entirely
    // ("Meri dia…" drawn across the NORTHERN PASSAGE poster). Capped + scrimmed, the title
    // stays readable at every size; the accessibility label carries the untruncated string.
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    .accessibilityHidden(true)
  }
}
