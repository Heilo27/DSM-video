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

  @State private var items: [ItemSummary] = []
  @State private var sortedItems: [ItemSummary] = []
  @State private var isLoading: Bool = false
  @State private var error: String?
  @State private var sortOption: SortOption = {
    let raw = UserDefaults.standard.string(forKey: "dsReel.sortOption") ?? ""
    let stored = SortOption(rawValue: raw) ?? .addedNewest
    // .all no longer has a chip (removed for simplicity) — coerce any stale stored
    // value to the default so the chip bar always shows an active selection.
    return stored == .all ? .addedNewest : stored
  }()
  @State private var searchText: String = ""
  @State private var showSearchSheet: Bool = false

  private var displayedItems: [ItemSummary] {
    guard !searchText.isEmpty else { return sortedItems }
    return sortedItems.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
  }

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
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 280), spacing: 24)] }
  #else
  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
  }
  #endif

  var body: some View {
    ScrollView {
      if isLoading && items.isEmpty {
        ProgressView("Loading videos")
          #if os(tvOS)
          .padding(.top, 60)
          #else
          .padding(.top, 24)
          #endif
      } else if let error {
        // FIX-18 / TASK-649: shared error+retry component.
        ErrorRetryView(title: "Couldn't load items", message: error) {
          Task { await load() }
        }
        .padding(.top, 24)
      } else {
        #if os(tvOS)
        let gridSpacing: CGFloat = 24
        let gridPadding: CGFloat = 48
        #else
        let gridSpacing: CGFloat = 12
        let gridPadding: CGFloat = horizontalSizeClass == .regular ? 20 : 12
        #endif
        // TASK-803: pick ONE empty state — an active search shows "No Results",
        // otherwise a genuinely empty library shows "No Videos". Previously both
        // could render stacked above an empty grid.
        if displayedItems.isEmpty && !searchText.isEmpty {
          ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No videos match \"\(searchText)\"")
          )
          .foregroundStyle(.white)
          .padding(.top, 60)
        } else if items.isEmpty && !isLoading && error == nil {
          DSContentUnavailable(title: "No Videos", systemImage: "film.stack", description: "This library has no videos yet.")
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
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(itemAccessibilityLabel(item))
            .accessibilityHint("Opens video details")
          }
          #endif
        }
        .padding(gridPadding)

        if !displayedItems.isEmpty {
          Text("\(displayedItems.count) item\(displayedItems.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(Color.dsTextTertiary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
            .accessibilityHidden(true)
        }
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
    .navigationTitle(library.title)
    #if !os(tvOS)
    // Force white nav-bar content (the large title was rendering dim grey on black).
    .toolbarColorScheme(.dark, for: .navigationBar)
    #endif
    .task { await load() }
    #if !os(tvOS)
    // Search is a magnifying-glass button in the nav bar that presents a search
    // sheet, now that the dedicated Search tab is gone.
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { showSearchSheet = true } label: {
          Image(systemName: "magnifyingglass")
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
          HStack(spacing: 12) {
            ItemPosterCell(item: item).frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
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
        if !items.isEmpty && (appState.isOffline || appState.serverUnreachable) {
          Text("Showing cached content")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.black)
        }
      }
    }
    .onChange(of: items) { _, new in sortedItems = sorted(new, by: sortOption) }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.sortOption")
      sortedItems = sorted(items, by: new)
    }
    #else
    // tvOS: render the SAME SortChipBar the iOS branch uses, as a focusable row above the
    // grid. This branch previously put two sort buttons in
    // ToolbarItem(placement: .topBarTrailing) and called .searchable() — neither of which
    // tvOS renders. The controls existed in code and were invisible on screen, which is
    // why the TV had no way to change sort order. Same defect class as the player's
    // top-bar/transport overscan bug: written for iOS, compiled for tvOS, never displayed.
    .safeAreaInset(edge: .top, spacing: 0) {
      SortChipBar(selection: $sortOption)
    }
    .onChange(of: items) { _, new in sortedItems = sorted(new, by: sortOption) }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.sortOption")
      sortedItems = sorted(items, by: new)
    }
    #endif
  }

  private func itemAccessibilityLabel(_ item: ItemSummary) -> String {
    var label = item.title
    if let year = item.year {
      label += ", \(year)"
    }
    if let progress = item.progress, progress.durationSeconds > 0 {
      let percent = Int((Double(progress.positionSeconds) / Double(progress.durationSeconds)) * 100)
      label += ", \(percent) percent watched"
    }
    return label
  }

  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      items = DemoData.items(for: library)
      sortedItems = sorted(items, by: sortOption)
      return
    }
    isLoading = true
    defer { isLoading = false }

    do {
      // Fetch all items by paginating through the API (server limits to 200 per request)
      var allItems: [ItemSummary] = []
      var offset = 0
      let pageSize = 200
      // TASK-790: app-side safety valves so a misbehaving/regressed server (total that
      // never converges, or overlapping pages that never satisfy the total break) can't
      // paginate forever. 50 pages × 200 = 10k items is well past any real library.
      let maxPages = 50
      var seenIDs = Set<String>()

      for _ in 0..<maxPages {
        let response = try await appState.api.items(libraryId: library.id, limit: pageSize, offset: offset)
        allItems.append(contentsOf: response.items)

        // Break if the page returned no NEW ids — guards against a server that keeps
        // returning full but overlapping pages (which would never trip the total check).
        let newIDs = response.items.filter { seenIDs.insert($0.id).inserted }
        if newIDs.isEmpty { break }

        if response.items.count < pageSize || allItems.count >= response.total {
          break
        }
        offset += pageSize
      }

      // Deduplicate: prefer items with a poster; break ties by keeping earliest addedAt.
      // The NAS can index the same movie from multiple paths (e.g. extras folder + main),
      // producing entries with different IDs but identical title+year.
      //
      // Duration is part of the key so this only collapses what is really the same
      // film. Keying on title+year alone silently hid distinct entries — a remake
      // released the same year, a theatrical vs extended cut, or a director's cut —
      // and the user would never learn the item existed. Runtime is bucketed to the
      // nearest minute so a one-second probe difference between two encodes of the
      // SAME file still dedups (the case this logic exists for), while genuinely
      // different cuts stay visible. Items with no duration fall back to title+year.
      func dedupKey(_ item: ItemSummary) -> String {
        let minutes = item.durationSeconds.map { String(Int(($0 + 30) / 60)) } ?? "?"
        return "\(item.title)|\(item.year ?? -1)|\(minutes)"
      }
      var deduped: [String: ItemSummary] = [:]
      for item in allItems {
        let key = dedupKey(item)
        if let existing = deduped[key] {
          // Prefer the entry that has a poster image
          let keepNew = item.posterImageId != nil && existing.posterImageId == nil
          if keepNew { deduped[key] = item }
        } else {
          deduped[key] = item
        }
      }
      items = allItems.filter { deduped[dedupKey($0)]?.id == $0.id }
      sortedItems = sorted(items, by: sortOption)
      error = nil
    } catch {
      let errorMsg = (error as? APIError)?.userMessage ?? "Unknown error."
      if items.isEmpty {
        // Network failed — try LocalStore as offline fallback before showing error.
        let cached = await LocalStore.shared.fetchItems(forLibraryId: library.id, limit: 5000)
        if !cached.isEmpty {
          items = cached
          sortedItems = sorted(cached, by: sortOption)
          // Don't set error — the offline banner (via appState.isOffline / serverUnreachable)
          // already communicates to the user that they're on cached content.
        } else {
          self.error = errorMsg
        }
      }
    }
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
    GeometryReader { geo in
      let width = geo.size.width
      let height = width * (3.0 / 2.0)

      ZStack(alignment: .bottom) {
        posterImage(width: width, height: height)
        gradientOverlay
        cellFooter

        // Progress bar — pinned to bottom edge, INSIDE clip boundary.
        // Only render meaningful progress: below ~2% it's a glitchy sliver, and at
        // ≥98% the watched badge already conveys "done" (avoids a near-full bar that
        // reads as a rendering bug).
        if let progress = item.progress, progress.durationSeconds > 0 {
          let frac = min(1.0, Double(progress.positionSeconds) / Double(progress.durationSeconds))
          if frac >= 0.02 && frac < 0.98 {
            GeometryReader { barGeo in
              ZStack(alignment: .leading) {
                Rectangle()
                  .fill(Color.dsBorderStrong)
                  .frame(height: 3)
                Rectangle()
                  .fill(Color.dsAccent)
                  .frame(width: barGeo.size.width * frac, height: 3)
              }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
          }
        }
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      // Watched badge — overlaid on top-right corner, outside clip so badge isn't clipped
      .overlay(alignment: .topTrailing) {
        if let progress = item.progress, progress.durationSeconds > 0 {
          let frac = min(1.0, Double(progress.positionSeconds) / Double(progress.durationSeconds))
          if frac >= PlaybackProgress.watchedThreshold {
            Circle()
              .fill(Color.dsSuccess)
              .frame(width: 22, height: 22)
              .overlay(
                Image(systemName: "checkmark")
                  .font(.system(size: 11, weight: .bold))
                  .foregroundStyle(.black)
              )
              .padding(6)
              .accessibilityHidden(true)
          }
        }
      }
      // Ambient elevation on the Cinematic theme; no-op on flat themes.
      .dsCardDepth(cornerRadius: 10)
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    // TASK-693/698: redact poster + title in the app switcher / screen recordings.
    .privacySensitive()
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
  private var gradientOverlay: some View {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0.45),
        .init(color: .black.opacity(0.85), location: 1.0)
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  @ViewBuilder
  private var cellFooter: some View {
    VStack(alignment: .leading, spacing: 2) {
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
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .accessibilityHidden(true)
  }
}
