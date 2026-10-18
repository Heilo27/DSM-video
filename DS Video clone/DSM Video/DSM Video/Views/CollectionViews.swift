import SwiftUI

// Kids' collections (FRD-002 §9, TASK-918).
//
// Everything rendered here is what GET /collections returned for the active profile. The
// server decides which collections a profile gets, their titles and their order (FR-271,
// FR-274); these views never filter, reorder or hardcode them. Presentation is decided once,
// in CollectionsBrowse.decide, and read through AppState.collectionsBrowse.

/// Focus targets on the collections rail that are not per-tile (tiles bind by collection id).
enum CollectionControl: Hashable {
  case retry, gridRetry
}

// MARK: - Tile

/// Art-forward tile: the collection's poster art full-bleed, its title over a scrim.
struct CollectionTile: View {
  @Environment(AppState.self) private var appState
  @Environment(\.displayScale) private var displayScale
  let collection: MediaCollection
  let width: CGFloat

  private var height: CGFloat { width * 1.5 }

  var body: some View {
    PosterCard { _, _ in
      art
    } footer: {
      VStack(alignment: .leading, spacing: 2) {
        Text(collection.title)
          .font(titleFont)
          .foregroundStyle(.white)
          .lineLimit(2)
        Text(countLabel)
          .font(countFont)
          .foregroundStyle(.white.opacity(0.75))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(padding)
    }
    .frame(width: width, height: height)
  }

  @ViewBuilder private var art: some View {
    if let posterID = collection.posterImageId {
      AuthenticatedImage(
        url: appState.api.imageURL(
          id: posterID,
          width: APIClient.ladderWidth(forPointWidth: width, scale: max(displayScale, 2))),
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
          Image(systemName: "rectangle.stack.fill")
            .font(.system(size: width * 0.22))
            .foregroundStyle(Color.dsTextMuted)
            .accessibilityHidden(true))
    }
  }

  private var countLabel: String {
    "\(collection.itemCount) title\(collection.itemCount == 1 ? "" : "s")"
  }

  #if os(tvOS)
  private var titleFont: Font { .dsTVSectionTitle }
  private var countFont: Font { .dsTVBody }
  private var padding: CGFloat { 18 }
  #else
  private var titleFont: Font { .headline.weight(.bold) }
  private var countFont: Font { .caption }
  private var padding: CGFloat { 10 }
  #endif
}

// MARK: - Home rail

/// The "Collections" row on the home screen. Kids get it as their browse (with an explicit
/// "none yet" or "couldn't load" state, FR-276); Teens and Adult get it as an extra row that
/// simply is not there when there is nothing to show.
struct CollectionsRail: View {
  @Environment(AppState.self) private var appState
  #if os(tvOS)
  @FocusState private var focusedTile: String?
  @FocusState private var focusedControl: CollectionControl?
  #endif

  var body: some View {
    switch appState.collectionsBrowse {
    case .hidden:
      EmptyView()
    case .collections(let list):
      VStack(alignment: .leading, spacing: headerSpacing) {
        header
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(alignment: .top, spacing: tileSpacing) {
            ForEach(list) { collection in
              tile(collection)
            }
          }
          #if os(tvOS)
          .padding(.vertical, 28)
          .padding(.leading, 28)
          .focusSection()
          #else
          .padding(.horizontal, 16)
          #endif
        }
        #if os(tvOS)
        .padding(.leading, 32)
        .padding(.trailing, 60)
        #endif
      }
    case .noneYet:
      VStack(alignment: .leading, spacing: headerSpacing) {
        header
        message(
          "No collections yet",
          detail: "Collections like Pixar or Holiday appear here once your NAS has movie details. Your libraries are below.")
      }
      .accessibilityIdentifier("collections.noneYet")
    case .failed:
      VStack(alignment: .leading, spacing: headerSpacing) {
        header
        message("Couldn't load collections", detail: "Check your connection to the NAS, then try again.")
        retryButton
      }
      .accessibilityIdentifier("collections.failed")
    }
  }

  private var header: some View {
    Text("Collections")
      #if os(tvOS)
      .font(.dsTVSectionTitle)
      .padding(.horizontal, 60)
      #else
      .font(.title3.weight(.bold))
      .padding(.horizontal, 16)
      #endif
      .foregroundStyle(.white)
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder private func tile(_ collection: MediaCollection) -> some View {
    NavigationLink {
      CollectionGridView(collection: collection)
    } label: {
      CollectionTile(collection: collection, width: tileWidth)
    }
    #if os(tvOS)
    .buttonStyle(.card)
    .focused($focusedTile, equals: collection.id)
    #else
    .buttonStyle(.plain)
    #endif
    .accessibilityLabel("\(collection.title), \(collection.itemCount) titles")
    .accessibilityHint("Opens collection")
    .accessibilityIdentifier("collection.\(collection.id)")
  }

  private func message(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        #if os(tvOS)
        .font(.dsTVSectionTitle)
        #else
        .font(.headline)
        #endif
        .foregroundStyle(.white)
      Text(detail)
        #if os(tvOS)
        .font(.dsTVBodyLarge)
        #else
        .font(.subheadline)
        #endif
        .foregroundStyle(Color.dsTextMuted)
    }
    .padding(.horizontal, horizontalInset)
  }

  private var retryButton: some View {
    Button {
      Task { await appState.loadCollections() }
    } label: {
      Label("Retry", systemImage: "arrow.clockwise")
    }
    #if os(tvOS)
    .buttonStyle(.borderedProminent)
    .tint(Color.dsAccent)
    .focused($focusedControl, equals: .retry)
    #else
    .buttonStyle(.bordered)
    #endif
    .padding(.horizontal, horizontalInset)
  }

  #if os(tvOS)
  private var tileWidth: CGFloat { 240 }
  private var tileSpacing: CGFloat { 28 }
  private var headerSpacing: CGFloat { 24 }
  private var horizontalInset: CGFloat { 60 }
  #else
  private var tileWidth: CGFloat { 130 }
  private var tileSpacing: CGFloat { 10 }
  private var headerSpacing: CGFloat { 10 }
  private var horizontalInset: CGFloat { 16 }
  #endif
}

// MARK: - Library browse bar (kids)

/// Shown above a library grid in place of the genre filter for a kids' profile (FR-270).
/// Each chip opens that collection's grid.
struct CollectionChipBar: View {
  @Environment(AppState.self) private var appState
  @State private var opened: MediaCollection?

  var body: some View {
    if case .collections(let list) = appState.collectionsBrowse {
      SortChipScroller {
        ForEach(list) { collection in
          SortChip(
            label: collection.title,
            isActive: false,
            accessibilityLabel: "\(collection.title), \(collection.itemCount) titles. Opens collection."
          ) { opened = collection }
        }
      }
      .navigationDestination(item: $opened) { collection in
        CollectionGridView(collection: collection)
      }
    }
  }
}

// MARK: - Collection grid

/// One collection's titles, paged from GET /collections/{id}/items.
struct CollectionGridView: View {
  @Environment(AppState.self) private var appState
  let collection: MediaCollection

  @State private var items: [ItemSummary] = []
  @State private var total: Int?
  @State private var isLoading = false
  @State private var error: String?
  #if os(tvOS)
  @FocusState private var focusedCell: Int?
  @FocusState private var focusedControl: CollectionControl?
  #endif

  private static let pageSize = 60

  private var hasMore: Bool { total.map { items.count < $0 } ?? false }

  var body: some View {
    ScrollView {
      if let error, items.isEmpty {
        VStack(spacing: 24) {
          DSContentUnavailable(title: "Couldn't Load", systemImage: "exclamationmark.triangle",
                               description: error)
          Button("Retry") { Task { await loadFirstPage() } }
            .buttonStyle(.borderedProminent)
            .tint(Color.dsAccent)
            #if os(tvOS)
            .focused($focusedControl, equals: .gridRetry)
            #endif
        }
        .padding(.top, 60)
      } else if total == 0 {
        // The server answers total 0 for an offered collection with nothing visible right now
        // (FR-275). On a restricted profile that is the ceiling at work (FR-265).
        if let profile = appState.activeProfile, profile.isRestricted {
          RestrictedEmptyState(profile: profile, place: collection.title)
            .padding(.top, 60)
        } else {
          DSContentUnavailable(title: "Nothing Here Yet", systemImage: "rectangle.stack",
                               description: "\(collection.title) has no titles right now.")
            .padding(.top, 60)
        }
      } else {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
          ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
            cell(item)
              #if os(tvOS)
              .focused($focusedCell, equals: idx)
              #endif
              .onAppear {
                if idx == items.count - 1, hasMore { Task { await loadNextPage() } }
              }
          }
        }
        .padding(gridPadding)
        if isLoading && !items.isEmpty {
          ProgressView().padding(.bottom, 24)
        }
      }
    }
    .overlay {
      if isLoading && items.isEmpty { ProgressView() }
    }
    .background(Color.dsBackground.ignoresSafeArea())
    .navigationTitle(collection.title)
    #if !os(tvOS)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .refreshable { await loadFirstPage() }
    #endif
    .task(id: collection.id) { await loadFirstPage() }
  }

  @ViewBuilder private func cell(_ item: ItemSummary) -> some View {
    // A show is one entry: an episode row whose showName names the show. It opens the show,
    // the same way the Just Added rail opens one.
    if item.type == "episode", let showName = item.showName, !showName.isEmpty,
       let tvLibrary = appState.homeLibraries.first(where: { $0.id == item.libraryId })
        ?? appState.homeFirstTVLibrary {
      NavigationLink {
        TVShowDetailView(
          show: TVShow(id: item.showFolderId ?? showName, title: showName, year: item.year,
                       seasonCount: nil, episodeCount: nil, posterImageId: item.posterImageId,
                       lastWatchedAt: nil, addedAt: nil),
          library: tvLibrary)
      } label: {
        ItemPosterCell(item: item)
      }
      .cellStyle()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(showName + (item.year.map { ", \($0)" } ?? ""))
      .accessibilityHint("Opens TV show")
    } else {
      NavigationLink {
        ItemDetailView(itemID: item.id, fallbackTitle: item.title)
      } label: {
        ItemPosterCell(item: item)
      }
      .cellStyle()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(item.title + (item.year.map { ", \($0)" } ?? ""))
      .accessibilityHint("Opens video details")
    }
  }

  private func loadFirstPage() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let resp = try await appState.api.collectionItems(
        id: collection.id, limit: Self.pageSize, offset: 0)
      items = resp.items
      total = resp.effectiveTotal
      error = nil
    } catch is CancellationError {
      return
    } catch {
      self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
    }
  }

  private func loadNextPage() async {
    guard !isLoading, hasMore else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let resp = try await appState.api.collectionItems(
        id: collection.id, limit: Self.pageSize, offset: items.count)
      items += resp.items
      total = resp.effectiveTotal
      // A short page means the server has no more, whatever total said.
      if resp.items.isEmpty { total = items.count }
    } catch {
      // Paging failure leaves what is already shown; scrolling to the end retries.
      let message = (error as? APIError)?.userMessage ?? error.localizedDescription
      dlog.warn(.home, "collection \(collection.id) page at \(items.count) failed: \(message)")
    }
  }

  #if os(tvOS)
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 220), spacing: 48)] }
  private var gridSpacing: CGFloat { 48 }
  private var gridPadding: CGFloat { 48 }
  #else
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 110), spacing: 12)] }
  private var gridSpacing: CGFloat { 12 }
  private var gridPadding: CGFloat { 12 }
  #endif
}

private extension View {
  /// The grid cell style each platform's library grid already uses.
  @ViewBuilder func cellStyle() -> some View {
    #if os(tvOS)
    self.buttonStyle(.card)
    #else
    self.dsPressable()
    #endif
  }
}
