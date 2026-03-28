import SwiftUI

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
        ProgressView()
      } else if let error {
        ContentUnavailableView("Couldn't load libraries", systemImage: "exclamationmark.triangle", description: Text(error))
      } else if libraries.isEmpty {
        ContentUnavailableView("No Libraries", systemImage: "square.grid.2x2", description: Text("No video libraries found on your Synology NAS."))
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
      let errorMsg = (error as? WebAPIError)?.userMessage ?? (error as? APIError)?.userMessage ?? "Unknown error."
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

// MARK: - Home Cache

/// Persists home screen data (libraries + items) to disk so the UI renders
/// instantly on next launch without waiting for network fetches.
/// Keyed by server URL — automatically stale when the user switches servers.
// nonisolated + Sendable: all members are value types, safe to use across actor boundaries.
private struct HomeCacheEntry: Codable, Sendable {
  let serverURL: String
  let libraries: [Library]
  let items: [ItemSummary]
  let savedAt: Date
  /// Per-library item counts at time of last full fetch — used to detect additions/removals
  /// without re-downloading every item on every background refresh.
  let libraryCounts: [String: Int]   // [libraryId: total]
}

private enum HomeCache {
  // nonisolated so these constants are accessible from detached Tasks without main-actor hop
  nonisolated(unsafe) private static let key = "dsReel.homeCache"
  nonisolated(unsafe) private static let backgroundRefreshAgeSeconds: TimeInterval = 5 * 60
  nonisolated(unsafe) private static let maxAgeSeconds: TimeInterval = 7 * 24 * 3600

  static func load(serverURL: String) -> HomeCacheEntry? {
    // Decoded off the main thread by callers using Task.detached — read is fast (memory-mapped)
    guard let data = UserDefaults.standard.data(forKey: key),
          let entry = try? JSONDecoder().decode(HomeCacheEntry.self, from: data),
          entry.serverURL == serverURL,
          Date().timeIntervalSince(entry.savedAt) < maxAgeSeconds
    else { return nil }
    return entry
  }

  /// Returns true if the cache exists but is stale enough to warrant a background refresh.
  static func needsRefresh(serverURL: String) -> Bool {
    guard let data = UserDefaults.standard.data(forKey: key),
          let entry = try? JSONDecoder().decode(HomeCacheEntry.self, from: data),
          entry.serverURL == serverURL
    else { return true }
    return Date().timeIntervalSince(entry.savedAt) > backgroundRefreshAgeSeconds
  }

  @MainActor
  static func saveAsync(serverURL: String, libraries: [Library], items: [ItemSummary], counts: [String: Int]) {
    let entry = HomeCacheEntry(serverURL: serverURL, libraries: libraries, items: items, savedAt: Date(), libraryCounts: counts)
    guard let data = try? JSONEncoder().encode(entry) else { return }
    Task.detached(priority: .utility) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  /// Bumps savedAt without re-encoding items — used when a refresh check finds nothing changed.
  @MainActor
  static func touch(serverURL: String) {
    guard let existing = load(serverURL: serverURL) else { return }
    let updated = HomeCacheEntry(serverURL: existing.serverURL, libraries: existing.libraries,
                                 items: existing.items, savedAt: Date(), libraryCounts: existing.libraryCounts)
    guard let data = try? JSONEncoder().encode(updated) else { return }
    Task.detached(priority: .utility) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  static func invalidate() {
    UserDefaults.standard.removeObject(forKey: key)
  }
}

// MARK: - LibraryHomeView

struct LibraryHomeView: View {
  @Environment(AppState.self) private var appState
  @State private var allItems: [ItemSummary] = []
  @State private var libraries: [Library] = []
  @State private var isLoading: Bool = false
  @State private var isBackgroundRefreshing: Bool = false
  @State private var error: String?

  // MARK: - Rail Filters

  private var continueWatchingItems: [ItemSummary] {
    // Items the user has actually started (positionSeconds > 0) and not yet finished.
    let sorted = allItems
      .filter { item in
        guard let p = item.progress,
              p.durationSeconds > 0,
              p.positionSeconds > 0 else { return false }
        let frac = Double(p.positionSeconds) / Double(p.durationSeconds)
        return frac >= 0.05 && frac < 0.95
      }
      .sorted { a, b in
        parseDate(a.progress?.updatedAt ?? a.addedAt) > parseDate(b.progress?.updatedAt ?? b.addedAt)
      }
    return Array(deduplicated(sorted).prefix(10))
  }

  private var justAddedItems: [ItemSummary] {
    let sorted = allItems.sorted { parseDate($0.addedAt) > parseDate($1.addedAt) }
    return deduplicated(sorted)
  }

  private var recentlyWatchedItems: [ItemSummary] {
    let sorted = allItems
      .filter { item in
        guard let p = item.progress, p.durationSeconds > 0 else { return false }
        let frac = Double(p.positionSeconds) / Double(p.durationSeconds)
        return frac >= 0.95
      }
      .sorted { a, b in
        parseDate(a.progress?.updatedAt ?? a.addedAt) > parseDate(b.progress?.updatedAt ?? b.addedAt)
      }
    return deduplicated(sorted)
  }

  private func parseDate(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso) ?? Date.distantPast
  }

  /// Removes duplicate entries for the same title, keeping the first (highest-priority) occurrence.
  /// This ensures a TV show with many episodes only appears once per rail.
  private func deduplicated(_ items: [ItemSummary]) -> [ItemSummary] {
    var seen = Set<String>()
    return items.filter { item in
      let key = item.title.lowercased() + "|\(item.type)"
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
  }

  private var firstMovieLibrary: Library? {
    libraries.first(where: { $0.kind == "movie" || $0.kind == "movies" }) ?? libraries.first
  }

  private var allRailsEmpty: Bool {
    continueWatchingItems.isEmpty && justAddedItems.isEmpty && recentlyWatchedItems.isEmpty
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      Group {
        if isLoading && allItems.isEmpty {
          ProgressView()
        } else if let error {
          VStack(spacing: 16) {
            ContentUnavailableView(
              "Couldn't load content",
              systemImage: "exclamationmark.triangle",
              description: Text(error)
            )
            Button("Retry") { Task { await load() } }
              .buttonStyle(.bordered)
          }
        } else if allRailsEmpty && !isLoading {
          ContentUnavailableView(
            "Nothing here yet",
            systemImage: "play.rectangle",
            description: Text("Add videos to your NAS to get started.")
          )
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 28) {
              if !continueWatchingItems.isEmpty {
                HomeRail(
                  title: "Continue Watching",
                  items: continueWatchingItems,
                  seeAllLibrary: firstMovieLibrary
                )
              }
              if !justAddedItems.isEmpty {
                HomeRail(
                  title: "Just Added",
                  items: justAddedItems,
                  seeAllLibrary: firstMovieLibrary
                )
              }
              if !recentlyWatchedItems.isEmpty {
                HomeRail(
                  title: "Recently Watched",
                  items: recentlyWatchedItems,
                  seeAllLibrary: firstMovieLibrary
                )
              }
            }
            .padding(.vertical, 16)
          }
        }
      }
      .navigationTitle("Home")
      .task { await load() }
      .refreshable { await load() }
      .background(Color.black.ignoresSafeArea())
    }
  }

  // MARK: - Load

  private func load() async {
    guard !isLoading else { return }

    if appState.isDemoMode {
      libraries = DemoData.libraries
      allItems = DemoData.movieItems + DemoData.tvItems
      return
    }

    let serverURL = appState.api.baseURL.absoluteString

    // Show cached data instantly — user sees content with no wait
    if allItems.isEmpty, let cached = HomeCache.load(serverURL: serverURL) {
      libraries = cached.libraries
      allItems = cached.items
      // Only background-refresh if cache is older than 5 minutes.
      // Previously refreshed on every launch, which hammered the NAS and
      // competed for the URLSession pool with item detail / image requests.
      if HomeCache.needsRefresh(serverURL: serverURL) {
        await fetchFromNetwork(serverURL: serverURL, background: true)
      }
      return
    }

    // No cache — show spinner and load
    await fetchFromNetwork(serverURL: serverURL, background: false)
  }

  private func fetchFromNetwork(serverURL: String, background: Bool) async {
    if background {
      guard !isBackgroundRefreshing else { return }
      isBackgroundRefreshing = true
    } else {
      isLoading = true
      error = nil
    }
    defer {
      if background { isBackgroundRefreshing = false }
      else { isLoading = false }
    }

    do {
      let loadedLibs = try await appState.api.libraries().libraries

      // Incremental refresh: for each library, fetch limit=1 to get the current total.
      // Only re-download the full item list for libraries where the count has changed.
      // This avoids re-fetching hundreds of items when nothing has been added or removed.
      let cachedCounts = HomeCache.load(serverURL: serverURL)?.libraryCounts ?? [:]
      var currentCounts: [String: Int] = [:]
      var libsNeedingRefresh: [Library] = []

      try await withThrowingTaskGroup(of: (String, Int).self) { group in
        for lib in loadedLibs {
          group.addTask {
            let probe = try await appState.api.items(libraryId: lib.id, limit: 1, offset: 0)
            return (lib.id, probe.total)
          }
        }
        for try await (libId, total) in group {
          currentCounts[libId] = total
          let cached = cachedCounts[libId]
          if cached == nil || cached != total {
            // Count changed or not cached — mark for full re-fetch
            if let lib = loadedLibs.first(where: { $0.id == libId }) {
              libsNeedingRefresh.append(lib)
            }
          }
        }
      }

      if libsNeedingRefresh.isEmpty && !allItems.isEmpty {
        // Nothing changed — bump the cache timestamp so the 5-min timer resets
        HomeCache.touch(serverURL: serverURL)
        libraries = loadedLibs
        return
      }

      // Fetch fresh items for changed libraries, then merge with cached items.
      // Fresh results win (overwrite) — deduplicate by item id so unchanged libraries
      // don't get double-counted.
      var freshItems: [ItemSummary] = []
      try await withThrowingTaskGroup(of: [ItemSummary].self) { group in
        for lib in libsNeedingRefresh {
          group.addTask {
            var libItems: [ItemSummary] = []
            var offset = 0
            let pageSize = 200
            let total = currentCounts[lib.id] ?? Int.max
            while true {
              let response = try await appState.api.items(
                libraryId: lib.id, limit: pageSize, offset: offset
              )
              libItems.append(contentsOf: response.items)
              if response.items.isEmpty || response.items.count < pageSize || libItems.count >= total || offset >= 5000 { break }
              offset += pageSize
            }
            return libItems
          }
        }
        for try await libItems in group {
          freshItems.append(contentsOf: libItems)
        }
      }

      // Merge: fresh items replace stale ones; unchanged cached items are kept.
      let freshIDs = Set(freshItems.map(\.id))
      let retained = allItems.filter { !freshIDs.contains($0.id) }
      let merged = retained + freshItems

      libraries = loadedLibs
      allItems = merged
      HomeCache.saveAsync(serverURL: serverURL, libraries: loadedLibs, items: merged, counts: currentCounts)
    } catch {
      appState.handleConnectionFailure(error)
      // Only show error if we have nothing to display
      if allItems.isEmpty {
        self.error = (error as? APIError)?.userMessage ?? "Unknown error."
      }
      // Silently ignore background refresh failures — stale cache is fine
    }
  }
}

// MARK: - HomeRail

private struct HomeRail: View {
  let title: String
  let items: [ItemSummary]
  let seeAllLibrary: Library?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Header row
      HStack {
        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
        Spacer()
        if let lib = seeAllLibrary {
          NavigationLink("See All") {
            ItemsGridView(library: lib)
          }
          .font(.subheadline)
          .foregroundStyle(DSReelBrandColor.background)
        }
      }
      .padding(.horizontal, 16)

      // Horizontal scroll of poster cards
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 10) {
          ForEach(items) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              ItemPosterCell(item: item)
                .frame(width: 120)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }
}

