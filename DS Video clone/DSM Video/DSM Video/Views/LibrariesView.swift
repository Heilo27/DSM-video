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
        ContentUnavailableView("Couldn't load libraries", systemImage: "exclamationmark.triangle", description: Text(error))
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
    .refreshable { await load() }

    if isEmbedded {
      content
    } else {
      NavigationStack { content }
    }
  }

  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      libraries = DemoData.libraries
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
                seeAllLibrary: appState.homeFirstMovieLibrary
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
      loadLog.info("LibraryHomeView: playerDidDismiss — triggering homeRefreshProgress")
      guard !appState.homeAllRailsEmpty || !appState.homeLibraries.isEmpty else { return }
      Task { await appState.homeRefreshProgress() }
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

// MARK: - HomeRail

private struct HomeRail: View {
  @Environment(AppState.self) private var appState
  let title: String
  let items: [ItemSummary]
  let seeAllLibrary: Library?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Header row
      HStack {
        Text(title)
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(.white)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        if let lib = seeAllLibrary {
          NavigationLink("See All") {
            ItemsGridView(library: lib)
          }
          .font(.system(size: 14))
          .foregroundStyle(Color.dsAccent)
          .padding(.vertical, 12)
          .padding(.horizontal, 8)
          .accessibilityLabel("See all in \(title)")
        }
      }
      .padding(.horizontal, 16)

      // Horizontal scroll of poster cards
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 10) {
          ForEach(items) { item in
            if let showName = item.showName, !showName.isEmpty,
               let tvLibrary = appState.homeFirstTVLibrary {
              // Episode → navigate to the show page so the user picks an episode.
              // Use a display item with showName as the title so the poster cell
              // label reads the show name rather than the episode title.
              let displayItem = ItemSummary(
                id: item.id, type: item.type, title: showName, year: item.year,
                durationSeconds: item.durationSeconds, addedAt: item.addedAt,
                rating: item.rating, posterImageId: item.posterImageId,
                backdropImageId: item.backdropImageId
              )
              let stub = TVShow(
                id: showName,
                title: showName,
                year: item.year,
                seasonCount: 0,
                episodeCount: 0,
                posterImageId: item.posterImageId,
                lastWatchedAt: nil
              )
              NavigationLink {
                TVShowDetailView(show: stub, library: tvLibrary)
              } label: {
                ItemPosterCell(item: displayItem)
                  .frame(width: 110)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(showName + (item.year.map { ", \($0)" } ?? ""))
              .accessibilityHint("Opens TV show")
            } else {
              NavigationLink {
                ItemDetailView(itemID: item.id, fallbackTitle: item.title)
              } label: {
                ItemPosterCell(item: item)
                  .frame(width: 110)
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
