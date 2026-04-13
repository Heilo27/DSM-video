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
    case .addedNewest:  return .addedOldest
    case .addedOldest:  return .addedNewest
    case .nameAsc:      return .nameDesc
    case .nameDesc:     return .nameAsc
    default:            return nil
    }
  }

  /// The canonical "primary" of a toggle pair — used to decide which chip to show.
  var primaryOfPair: TVShowSortOption {
    switch self {
    case .addedOldest: return .addedNewest
    case .nameDesc:    return .nameAsc
    default:           return self
    }
  }

  /// Chips to display (de-duplicated: show primary of each pair, hide the secondary).
  static var displayedChips: [TVShowSortOption] {
    [.recentlyWatched, .addedNewest, .nameAsc]
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

  #if os(tvOS)
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 28)] }
  #else
  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
  }
  #endif

  private var sortedShows: [TVShow] {
    switch sortOption {
    case .recentlyWatched:
      shows.sorted { a, b in
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
      shows.sorted { ($0.addedAt ?? "") > ($1.addedAt ?? "") }
    case .addedOldest:
      shows.sorted { ($0.addedAt ?? "") < ($1.addedAt ?? "") }
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
        ContentUnavailableView(
          "Couldn't load shows",
          systemImage: "exclamationmark.triangle",
          description: Text(error)
        )
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
        LazyVGrid(columns: columns, spacing: 44) {
          ForEach(sortedShows) { show in
            NavigationLink {
              TVShowDetailView(show: show, library: library)
            } label: {
              TVShowPosterCell(show: show)
            }
            .buttonStyle(.card)
            .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? ""), \(show.seasonCount) season\(show.seasonCount == 1 ? "" : "s")")
            .accessibilityHint("Opens show details")
          }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 48)
        #else
        LazyVGrid(columns: columns, spacing: 12) {
          ForEach(sortedShows) { show in
            NavigationLink {
              TVShowDetailView(show: show, library: library)
            } label: {
              TVShowPosterCell(show: show)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens show details")
          }
        }
        .padding(horizontalSizeClass == .regular ? 20 : 12)
        #endif
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(library.title)
    .task {
      await load()
    }
    #if !os(tvOS)
    .refreshable {
      await load()
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      TVShowSortChipBar(selection: $sortOption)
    }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.tvSortOption")
    }
    #else
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Sort", selection: $sortOption) {
            ForEach(TVShowSortOption.allCases, id: \.self) { option in
              Text(option.rawValue).tag(option)
            }
          }
        } label: {
          Label("Sort", systemImage: "arrow.up.arrow.down.circle")
        }
      }
    }
    .onChange(of: sortOption) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "dsReel.tvSortOption")
    }
    #endif
  }

  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      shows = DemoData.tvShows
      return
    }
    tvLog.info("TVShowsView.load: libraryId=\(library.id) baseURL=\(appState.api.baseURL.absoluteString)")
    isLoading = true
    defer { isLoading = false }
    do {
      let response = try await appState.api.tvShows(libraryId: library.id)
      tvLog.info("TVShowsView.load: success — \(response.shows.count) shows")
      shows = response.shows
      error = nil
    } catch {
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
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(TVShowSortOption.displayedChips, id: \.self) { chip in
          let isActive = selection.primaryOfPair == chip
          let label = isActive ? selection.chipLabel : chip.chipLabel
          Button {
            if isActive, let next = selection.toggled {
              selection = next
            } else {
              selection = chip
            }
          } label: {
            Text(label)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(isActive ? Color.white : Color.dsTextSecondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .fill(isActive ? Color.dsAccent : Color.dsSurface)
              )
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Sort by \(selection.rawValue)")
          .accessibilityAddTraits(isActive ? .isSelected : [])
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .background(Color.black.opacity(0.95))
  }
}
#endif

// MARK: - Poster Cell

private struct TVShowPosterCell: View {
  @Environment(AppState.self) private var appState
  let show: TVShow

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height = width * (3.0 / 2.0)  // 2:3 portrait

      ZStack(alignment: .bottom) {
        // Poster image
        if appState.isDemoMode, let assetName = DemoData.posterAssetNames[show.id] {
          Image(assetName)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipped()
        } else if let id = show.posterImageId {
          AuthenticatedImage(
            url: appState.api.imageURL(id: id, width: 400),
            token: appState.sessionToken
          )
          .scaledToFill()
          .frame(width: width, height: height)
          .clipped()
        } else {
          Color(white: 0.08)
            .frame(width: width, height: height)
            .overlay(
              Image(systemName: "tv.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.25))
                .accessibilityLabel("No poster available")
            )
        }

        // Bottom gradient
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.45),
            .init(color: .black.opacity(0.88), location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(width: width, height: height)

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
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
  }

  private func seasonLabel(_ show: TVShow) -> String {
    if show.seasonCount == 1 {
      return "\(show.episodeCount) episode\(show.episodeCount == 1 ? "" : "s")"
    }
    return "\(show.seasonCount) season\(show.seasonCount == 1 ? "" : "s")"
  }
}
