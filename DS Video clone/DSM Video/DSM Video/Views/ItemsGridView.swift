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
    return SortOption(rawValue: raw) ?? .addedNewest
  }()

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
          .padding(.top, 24)
      } else if let error {
        // FIX-18: retry button so users aren't stuck after a transient network error
        VStack(spacing: 12) {
          ContentUnavailableView("Couldn't load items", systemImage: "exclamationmark.triangle", description: Text(error))
          Button("Retry") { Task { await load() } }
            .buttonStyle(.borderedProminent)
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
        if items.isEmpty && !isLoading && error == nil {
          ContentUnavailableView("No Videos", systemImage: "film.stack", description: Text("This library has no videos yet."))
            .foregroundStyle(.white)
        }
        LazyVGrid(columns: columns, spacing: gridSpacing) {
          ForEach(sortedItems) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              ItemPosterCell(item: item)
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(itemAccessibilityLabel(item))
            .accessibilityHint("Opens video details")
          }
        }
        .padding(gridPadding)

        if !sortedItems.isEmpty {
          Text("\(sortedItems.count) item\(sortedItems.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(Color.dsTextTertiary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
            .accessibilityHidden(true)
        }
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(library.title)
    .task { await load() }
    #if !os(tvOS)
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
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Sort", selection: $sortOption) {
            ForEach(SortOption.allCases, id: \.self) { option in
              Text(option.rawValue).tag(option)
            }
          }
        } label: {
          Label("Sort", systemImage: "arrow.up.arrow.down.circle")
        }
      }
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

      while true {
        let response = try await appState.api.items(libraryId: library.id, limit: pageSize, offset: offset)
        allItems.append(contentsOf: response.items)

        if response.items.count < pageSize || allItems.count >= response.total {
          break
        }
        offset += pageSize
      }

      // Deduplicate: prefer items with a poster; break ties by keeping earliest addedAt.
      // The NAS can index the same movie from multiple paths (e.g. extras folder + main),
      // producing entries with different IDs but identical title+year.
      var deduped: [String: ItemSummary] = [:]  // key: "title|year"
      for item in allItems {
        let key = "\(item.title)|\(item.year ?? -1)"
        if let existing = deduped[key] {
          // Prefer the entry that has a poster image
          let keepNew = item.posterImageId != nil && existing.posterImageId == nil
          if keepNew { deduped[key] = item }
        } else {
          deduped[key] = item
        }
      }
      items = allItems.filter {
        let key = "\($0.title)|\($0.year ?? -1)"
        return deduped[key]?.id == $0.id
      }
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

// MARK: - Sort Chip Bar (iOS/macOS only)

#if !os(tvOS)
private struct SortChipBar: View {
  @Binding var selection: SortOption

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(SortOption.allCases, id: \.self) { option in
          Button {
            selection = option
          } label: {
            Text(option.chipLabel)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(selection == option ? Color.white : Color.dsTextSecondary)
              .frame(minHeight: 44)
              .padding(.horizontal, 12)
              .padding(.vertical, 14)
              .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                  .fill(selection == option ? Color.dsAccent : Color.dsSurface)
              )
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Sort by \(option.rawValue)")
          .accessibilityAddTraits(selection == option ? [.isButton, .isSelected] : .isButton)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .background(Color.black.opacity(0.95))
  }
}
#endif

struct ItemPosterCell: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height = width * (3.0 / 2.0)

      ZStack(alignment: .bottom) {
        posterImage(width: width, height: height)
        gradientOverlay
        cellFooter

        // Progress bar — pinned to bottom edge, INSIDE clip boundary
        if let progress = item.progress, progress.durationSeconds > 0 {
          let frac = min(1.0, Double(progress.positionSeconds) / Double(progress.durationSeconds))
          if frac < 1.0 {
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
          if frac >= 0.95 {
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
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  @ViewBuilder
  private func posterImage(width: CGFloat, height: CGFloat) -> some View {
    if appState.isDemoMode, let assetName = DemoData.posterAssetNames[item.id] {
      Image(assetName)
        .resizable()
        .scaledToFill()
        .frame(width: width, height: height)
        .clipped()
    } else if item.posterImageId != nil {
      AuthenticatedImage(
        url: appState.api.imageURL(id: item.posterImageId ?? item.id, width: 400, version: item.changeSeq),
        token: appState.sessionToken,
        usesTunnelCookie: appState.api.usesTunnelCookie
      )
      .scaledToFill()
      .frame(width: width, height: height)
      .clipped()
    } else {
      Rectangle()
        .fill(Color(white: 0.06))
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
