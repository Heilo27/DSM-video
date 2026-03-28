import SwiftUI

enum SortOption: String, CaseIterable {
  case addedNewest  = "Recently Added"
  case addedOldest  = "Oldest Added"
  case nameAsc      = "Name A–Z"
  case nameDesc     = "Name Z–A"
  case releaseNewest = "Release Year ↓"
  case releaseOldest = "Release Year ↑"

  var chipLabel: String {
    switch self {
    case .addedNewest:  return "Added ↓"
    case .addedOldest:  return "Added ↑"
    case .nameAsc:      return "A → Z"
    case .nameDesc:     return "Z → A"
    case .releaseNewest: return "Year ↓"
    case .releaseOldest: return "Year ↑"
    }
  }
}

struct ItemsGridView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let library: Library

  @State private var items: [ItemSummary] = []
  @State private var isLoading: Bool = false
  @State private var error: String?
  @State private var sortOption: SortOption = {
    let raw = UserDefaults.standard.string(forKey: "dsReel.sortOption") ?? ""
    return SortOption(rawValue: raw) ?? .addedNewest
  }()

  private var sortedItems: [ItemSummary] {
    switch sortOption {
    case .addedNewest:  return items.sorted { $0.addedAt > $1.addedAt }
    case .addedOldest:  return items.sorted { $0.addedAt < $1.addedAt }
    case .nameAsc:      return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .nameDesc:     return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
    case .releaseNewest: return items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    case .releaseOldest: return items.sorted { ($0.year ?? Int.max) < ($1.year ?? Int.max) }
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
        ContentUnavailableView("Couldn't load items", systemImage: "exclamationmark.triangle", description: Text(error))
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
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(library.title)
    .task { await load() }
    #if !os(tvOS)
    .refreshable { await load() }
    .safeAreaInset(edge: .top, spacing: 0) {
      SortChipBar(selection: $sortOption)
    }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.sortOption")
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
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.sortOption")
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

      items = allItems
      error = nil
    } catch {
      let errorMsg = (error as? WebAPIError)?.userMessage ?? (error as? APIError)?.userMessage ?? "Unknown error."
      if items.isEmpty {
        self.error = errorMsg
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
              .padding(.horizontal, 12)
              .padding(.vertical, 12)
              .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                  .fill(selection == option ? Color.dsAccent : Color.dsSurface)
              )
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Sort by \(option.chipLabel)")
          .accessibilityAddTraits(selection == option ? .isSelected : [])
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
                  .fill(Color(white: 0.3))
                  .frame(height: 3)
                Rectangle()
                  .fill(DSReelBrandColor.background)
                  .frame(width: barGeo.size.width * frac, height: 3)
              }
            }
            .frame(height: 3)
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
          }
        }
      }
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
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
        url: appState.api.imageURL(id: item.posterImageId ?? item.id, width: 400),
        token: appState.sessionToken
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
            .accessibilityLabel("No poster available")
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
          .foregroundStyle(.white.opacity(0.65))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
  }
}
