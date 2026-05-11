import SwiftUI
import os.log

private let loadLog = Logger(subsystem: "com.dsm.dsvideo", category: "LibraryLoad")

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
        List(libraries) { lib in
          NavigationLink {
            if lib.kind == "tv" {
              TVShowsView(library: lib)
            } else {
              ItemsGridView(library: lib)
            }
          } label: {
            Label(lib.title, systemImage: libraryIcon(lib.kind))
          }
          .accessibilityLabel(lib.title)
        }
      }
    }
    .navigationTitle("Libraries")
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

  private func libraryIcon(_ kind: String) -> String {
    switch kind {
    case "tv": return "tv"
    case "movies", "movie": return "film"
    case "home", "homevideo": return "house"
    default: return "play.rectangle"
    }
  }
}

// MARK: - LibraryHomeView

struct LibraryHomeView: View {
  @Environment(AppState.self) private var appState

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
            if !appState.homeContinueWatching.isEmpty {
              HomeRail(
                title: "Continue Watching",
                items: appState.homeContinueWatching,
                seeAllLibrary: appState.homeFirstMovieLibrary,
                useLandscapeCards: true
              )
            }
            if !appState.homeJustAdded.isEmpty {
              HomeRail(
                title: "Just Added",
                items: appState.homeJustAdded,
                seeAllLibrary: appState.homeFirstMovieLibrary
              )
            }
            if !appState.homeRecentlyWatched.isEmpty {
              HomeRail(
                title: "Recently Watched",
                items: appState.homeRecentlyWatched,
                seeAllLibrary: appState.homeFirstMovieLibrary
              )
            }
          }
          .padding(.vertical, 16)
        }
      }
    }
    .preferredColorScheme(.dark)
    .navigationTitle("Home")
    .task { await appState.homeLoad() }
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
    .background(Color.black.ignoresSafeArea())

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
          AuthenticatedImage(
            url: appState.api.imageURL(id: backdropId, width: 400),
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

      Text(item.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(width: 200, alignment: .leading)

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
              .accessibilityLabel(item.title + (item.year.map { ", \($0)" } ?? ""))
              .accessibilityHint("Opens video details")
            }
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }
}
