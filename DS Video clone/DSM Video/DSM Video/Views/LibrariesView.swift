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
    // Sort newest first, then deduplicate so each show/movie appears once.
    // For TV episodes, group by title prefix up to the episode marker so all
    // episodes of the same show collapse to the most-recently-added one.
    let sorted = allItems.sorted { parseDate($0.addedAt) > parseDate($1.addedAt) }
    return deduplicatedByShow(sorted)
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

  private static let _dateFormatterFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let _dateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  private func parseDate(_ iso: String) -> Date {
    if let d = Self._dateFormatterFractional.date(from: iso) { return d }
    return Self._dateFormatter.date(from: iso) ?? Date.distantPast
  }

  /// Deduplicates by exact title+type — used for Continue Watching and Recently Watched
  /// where items already have show-level titles from the server.
  private func deduplicated(_ items: [ItemSummary]) -> [ItemSummary] {
    var seen = Set<String>()
    return items.filter { item in
      let key = item.title.lowercased() + "|\(item.type)"
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
  }

  /// Deduplicates by show — TV episodes are grouped by `showName` (from server) so
  /// all episodes of the same show collapse to one entry. Movies pass through unchanged.
  private func deduplicatedByShow(_ items: [ItemSummary]) -> [ItemSummary] {
    var seen = Set<String>()
    return items.filter { item in
      let key: String
      if let showName = item.showName, !showName.isEmpty {
        // Use the server-supplied show name — most reliable grouping
        key = "tv|\(showName.lowercased())"
      } else if item.type == "episode" || item.seasonNumber != nil || item.episodeNumber != nil {
        // Fallback: strip season/episode markers from title
        let base = item.title
          .replacingOccurrences(of: #"\s+[Ss]\d+.*$"#, with: "", options: .regularExpression)
          .replacingOccurrences(of: #"\s+[Ee]\d+.*$"#, with: "", options: .regularExpression)
          .lowercased()
        key = "tv|\(base)"
      } else {
        key = item.title.lowercased() + "|\(item.type)"
      }
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
          ProgressView("Loading libraries")
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
    loadLog.info("load: called — isLoading=\(isLoading) allItems=\(allItems.count)")
    guard !isLoading else {
      loadLog.warning("load: already loading, bailing out (guard against double-call)")
      return
    }

    if appState.isDemoMode {
      loadLog.info("load: demo mode — injecting DemoData")
      libraries = DemoData.libraries
      allItems = DemoData.movieItems + DemoData.tvItems
      return
    }

    let serverURL = appState.api.baseURL.absoluteString
    loadLog.info("load: serverURL=\(serverURL)")

    // If items are already in memory (re-entering tab, pull-to-refresh), always
    // run as a background check — never block the UI with a foreground fetch.
    if !allItems.isEmpty {
      loadLog.info("load: items already loaded — running background check only")
      if HomeCache.needsRefresh(serverURL: serverURL) {
        Task { await fetchFromNetwork(serverURL: serverURL, background: true) }
      } else {
        loadLog.info("load: cache fresh — nothing to do")
      }
      return
    }

    // Cold start: try cache first for instant render
    if let cached = HomeCache.load(serverURL: serverURL) {
      loadLog.info("load: cache HIT — rendering \(cached.items.count) items immediately (no spinner)")
      libraries = cached.libraries
      allItems = cached.items
      if HomeCache.needsRefresh(serverURL: serverURL) {
        loadLog.info("load: cache stale — scheduling background refresh")
        Task { await fetchFromNetwork(serverURL: serverURL, background: true) }
      } else {
        loadLog.info("load: cache fresh — done")
      }
      return
    }

    // No cache at all — show spinner and fetch
    loadLog.info("load: no cache — fetching from network")
    await fetchFromNetwork(serverURL: serverURL, background: false)
  }

  private func fetchFromNetwork(serverURL: String, background: Bool) async {
    loadLog.info("fetchFromNetwork: background=\(background)")
    if background {
      guard !isBackgroundRefreshing else {
        loadLog.warning("fetchFromNetwork: background refresh already in flight — skipping")
        return
      }
      isBackgroundRefreshing = true
    } else {
      isLoading = true
      error = nil
    }

    // Snapshot values needed by the detached task — capture before leaving @MainActor
    let api = appState.api
    let cachedItems = allItems
    let cachedLibraries = libraries

    // All network I/O runs on the cooperative thread pool, NOT the main actor.
    // This keeps the main thread free for UI (tab switches, navigation, rendering)
    // even during the 40s+ library fetch the NAS currently takes.
    let result = await Task.detached(priority: .userInitiated) {
      await Self.doFetch(api: api, serverURL: serverURL,
                         cachedItems: cachedItems, cachedLibraries: cachedLibraries)
    }.value

    // Back on @MainActor — apply result to state
    switch result {
    case .noChange(let libs):
      loadLog.info("fetchFromNetwork: no change — updating libs, touching cache")
      HomeCache.touch(serverURL: serverURL)
      libraries = libs

    case .updated(let libs, let merged, let counts, let updatedAt):
      loadLog.info("fetchFromNetwork: update complete — \(merged.count) items")
      libraries = libs
      allItems = merged
      HomeCache.save(serverURL: serverURL, libraries: libs, items: merged,
                     counts: counts, updatedAt: updatedAt)

    case .failure(let err):
      loadLog.error("fetchFromNetwork: ERROR — \(err.localizedDescription)")
      appState.handleConnectionFailure(err)
      if allItems.isEmpty {
        self.error = (err as? APIError)?.userMessage ?? "Unknown error."
      }
    }

    if background { isBackgroundRefreshing = false } else { isLoading = false }
    loadLog.info("fetchFromNetwork: done (background=\(background))")
  }

  // Result type — all value types, safe to return from detached task
  private enum FetchResult: Sendable {
    case noChange([Library])
    case updated([Library], [ItemSummary], [String: Int], [String: String])
    case failure(Error)
  }

  // nonisolated: runs entirely off the main actor on the cooperative thread pool
  private nonisolated static func doFetch(api: APIClient, serverURL: String,
                                          cachedItems: [ItemSummary],
                                          cachedLibraries: [Library]) async -> FetchResult {
    // Local logger — avoids @MainActor isolation issue with file-scope let in a View file
    let log = Logger(subsystem: "com.dsm.dsvideo", category: "LibraryLoad")
    do {
      let cachedEntry = HomeCache.load(serverURL: serverURL)
      let cachedCounts = cachedEntry?.libraryCounts ?? [:]

      var currentCounts: [String: Int] = [:]
      var currentUpdatedAt: [String: String] = [:]
      var libsNeedingRefresh: [Library] = []

      // Step 1: Check for changes via lightweight summary endpoint (fast, ~0.07s).
      // Only fall back to fetching the full library list if summary is unavailable
      // or if we have no cached library list to work from.
      log.info("doFetch: calling /api/v1/libraries/summary for change detection")
      let t1 = Date()
      if let summaries = try? await api.librariesSummary(), !cachedLibraries.isEmpty {
        log.info("doFetch: summary in \(String(format: "%.2f", Date().timeIntervalSince(t1)))s — \(summaries.libraries.count) entries")
        for s in summaries.libraries {
          currentCounts[s.libraryId] = s.count
          currentUpdatedAt[s.libraryId] = s.lastUpdatedAt
          let countChanged = cachedCounts[s.libraryId] != s.count
          let isNew = cachedCounts[s.libraryId] == nil
          log.info("  lib=\(s.libraryId) count=\(s.count) cached=\(cachedCounts[s.libraryId].map(String.init) ?? "nil") countChanged=\(countChanged) isNew=\(isNew)")
          if countChanged || isNew {
            // Use cached library list — avoids the slow /api/v1/libraries call
            if let lib = cachedLibraries.first(where: { $0.id == s.libraryId }) {
              log.info("  → queuing '\(lib.title)' for item fetch")
              libsNeedingRefresh.append(lib)
            }
          }
        }

        // Nothing changed — no network fetch needed
        if libsNeedingRefresh.isEmpty && !cachedItems.isEmpty {
          log.info("doFetch: no changes detected — cache is current, skipping all item fetches")
          return .noChange(cachedLibraries)
        }
      } else {
        // No summary endpoint or no cached libs — must fetch full library list
        log.info("doFetch: no cached libs or summary unavailable — fetching /api/v1/libraries")
        let t0 = Date()
        let loadedLibs = try await api.libraries().libraries
        log.info("doFetch: got \(loadedLibs.count) libs in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        libsNeedingRefresh = loadedLibs
        for lib in loadedLibs { currentCounts[lib.id] = 0 }
      }

      // Step 2: Fetch items only for libraries that changed
      log.info("doFetch: \(libsNeedingRefresh.count) lib(s) need item refresh")
      var freshItems: [ItemSummary] = []
      let t2 = Date()
      try await withThrowingTaskGroup(of: [ItemSummary].self) { group in
        for lib in libsNeedingRefresh {
          group.addTask {
            let log = Logger(subsystem: "com.dsm.dsvideo", category: "LibraryLoad")
            log.info("  itemFetch[\(lib.id)]: starting (expected≈\(currentCounts[lib.id].map(String.init) ?? "?"))")
            var libItems: [ItemSummary] = []
            var offset = 0
            let pageSize = 200
            let total = currentCounts[lib.id] ?? Int.max
            var page = 0
            while true {
              let pageStart = Date()
              let response = try await api.items(libraryId: lib.id, limit: pageSize, offset: offset)
              log.info("  itemFetch[\(lib.id)]: page \(page) got=\(response.items.count) in \(String(format: "%.2f", Date().timeIntervalSince(pageStart)))s")
              libItems.append(contentsOf: response.items)
              page += 1
              if response.items.isEmpty || response.items.count < pageSize || libItems.count >= total || offset >= 5000 { break }
              offset += pageSize
            }
            log.info("  itemFetch[\(lib.id)]: done — \(libItems.count) items")
            return libItems
          }
        }
        for try await libItems in group { freshItems.append(contentsOf: libItems) }
      }
      log.info("doFetch: item fetches done in \(String(format: "%.2f", Date().timeIntervalSince(t2)))s — \(freshItems.count) fresh items")

      // Merge: fresh items replace stale by id; unchanged library items kept from cache
      let freshIDs = Set(freshItems.map(\.id))
      let retained = cachedItems.filter { !freshIDs.contains($0.id) }
      let merged = retained + freshItems
      log.info("doFetch: merge — retained=\(retained.count) fresh=\(freshItems.count) merged=\(merged.count)")

      return .updated(cachedLibraries, merged, currentCounts, currentUpdatedAt)
    } catch {
      return .failure(error)
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
          .padding(.vertical, 12)
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

