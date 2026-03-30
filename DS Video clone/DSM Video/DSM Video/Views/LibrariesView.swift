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

  /// Pass `true` when this view is embedded inside an existing NavigationStack
  /// (e.g. the iPad split-view detail column) to avoid nesting stacks.
  var isEmbedded: Bool = false

  @State private var allItems: [ItemSummary] = []
  @State private var libraries: [Library] = []
  @State private var isLoading: Bool = false
  @State private var isCacheDecoding: Bool = false   // true while background cache decode is in-flight
  @State private var isBackgroundRefreshing: Bool = false
  @State private var backgroundFetchTask: Task<Void, Never>?
  @State private var error: String?

  // Pre-computed rail data — updated off-main-thread whenever allItems changes.
  // Never computed inside body to avoid blocking the main thread with 4500+ item sorts.
  @State private var continueWatchingItems: [ItemSummary] = []
  @State private var justAddedItems: [ItemSummary] = []
  @State private var recentlyWatchedItems: [ItemSummary] = []
  // TASK-302: tracks whether the first-load VoiceOver announcement has fired this session
  @State private var hasAnnouncedContent: Bool = false

  private var firstMovieLibrary: Library? {
    libraries.first(where: { $0.kind == "movie" || $0.kind == "movies" }) ?? libraries.first
  }

  private var allRailsEmpty: Bool {
    continueWatchingItems.isEmpty && justAddedItems.isEmpty && recentlyWatchedItems.isEmpty
  }

  // MARK: - Rail Computation (off main thread)

  /// Recomputes all three rail arrays from `items` on a background thread, then
  /// applies the results back on @MainActor. Call whenever allItems changes.
  private func recomputeRails(from items: [ItemSummary]) {
    loadLog.debug("recomputeRails: triggered — \(items.count) items")
    let t = Date()
    Task.detached(priority: .userInitiated) {
      let (cont, added, watched) = Self.computeRails(items)
      let elapsed = String(format: "%.3f", Date().timeIntervalSince(t))
      await MainActor.run {
        self.continueWatchingItems = cont
        self.justAddedItems = added
        self.recentlyWatchedItems = watched
        loadLog.info("recomputeRails: done in \(elapsed)s — cont=\(cont.count) added=\(added.count) watched=\(watched.count)")
      }
    }
  }

  private nonisolated static func computeRails(_ allItems: [ItemSummary])
    -> (continueWatching: [ItemSummary], justAdded: [ItemSummary], recentlyWatched: [ItemSummary])
  {
    let formatterFrac: ISO8601DateFormatter = {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return f
    }()
    let formatter: ISO8601DateFormatter = {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime]
      return f
    }()
    func parseDate(_ iso: String) -> Date {
      formatterFrac.date(from: iso) ?? formatter.date(from: iso) ?? .distantPast
    }

    func deduplicated(_ items: [ItemSummary]) -> [ItemSummary] {
      var seen = Set<String>()
      return items.filter { seen.insert($0.title.lowercased() + "|\($0.type)").inserted }
    }

    func deduplicatedByShow(_ items: [ItemSummary]) -> [ItemSummary] {
      var seen = Set<String>()
      return items.filter { item in
        let key: String
        if let showName = item.showName, !showName.isEmpty {
          key = "tv|\(showName.lowercased())"
        } else if item.type == "episode" || item.seasonNumber != nil || item.episodeNumber != nil {
          let base = item.title
            .replacingOccurrences(of: #"\s+[Ss]\d+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+[Ee]\d+.*$"#, with: "", options: .regularExpression)
            .lowercased()
          key = "tv|\(base)"
        } else {
          key = item.title.lowercased() + "|\(item.type)"
        }
        return seen.insert(key).inserted
      }
    }

    let continueWatching = Array(deduplicated(
      allItems
        .filter { item in
          guard let p = item.progress, p.durationSeconds > 0, p.positionSeconds > 0 else { return false }
          let frac = Double(p.positionSeconds) / Double(p.durationSeconds)
          return frac >= 0.05 && frac < 0.95
        }
        .sorted { parseDate($0.progress?.updatedAt ?? $0.addedAt) > parseDate($1.progress?.updatedAt ?? $1.addedAt) }
    ).prefix(10))

    let recentlyWatched = deduplicated(
      allItems
        .filter { item in
          guard let p = item.progress, p.durationSeconds > 0 else { return false }
          return Double(p.positionSeconds) / Double(p.durationSeconds) >= 0.95
        }
        .sorted { parseDate($0.progress?.updatedAt ?? $0.addedAt) > parseDate($1.progress?.updatedAt ?? $1.addedAt) }
    )

    let watchedIDs = Set((continueWatching + recentlyWatched).map(\.id))
    let justAdded = Array(deduplicatedByShow(
      allItems
        .filter { !watchedIDs.contains($0.id) }
        .sorted { parseDate($0.addedAt) > parseDate($1.addedAt) }
    ).prefix(10))

    return (continueWatching, justAdded, recentlyWatched)
  }

  // MARK: - Body

  var body: some View {
    let content = Group {
      // TASK-299: show spinner during both network load and cache decode to avoid black screen
      if (isLoading || isCacheDecoding) && allItems.isEmpty {
        ProgressView("Loading content")
          .tint(Color.dsTextPrimary)
          .accessibilityLabel("Loading content, please wait")
          .accessibilityAddTraits(.updatesFrequently)
      } else if let error {
        VStack(spacing: 16) {
          ContentUnavailableView(
            "Couldn't load content",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
          Button("Retry") { Task { await load() } }
            .buttonStyle(.bordered)
            .accessibilityLabel("Retry loading content")
        }
      } else if allRailsEmpty && !isLoading && !isCacheDecoding && allItems.isEmpty {
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
    .preferredColorScheme(.dark)
    .navigationTitle("Home")
    .onAppear {
      loadLog.info("LibraryHomeView: onAppear — allItems=\(allItems.count) cont=\(continueWatchingItems.count) added=\(justAddedItems.count) watched=\(recentlyWatchedItems.count) isLoading=\(isLoading) isCacheDecoding=\(isCacheDecoding)")
    }
    .onDisappear {
      loadLog.info("LibraryHomeView: onDisappear — allItems=\(allItems.count) backgroundRefreshing=\(isBackgroundRefreshing)")
      backgroundFetchTask?.cancel()
      isBackgroundRefreshing = false
    }
    .task { await load() }
    .refreshable { await forceRefresh() }
    .onChange(of: allItems) { old, new in
      loadLog.debug("allItems changed: \(old.count) → \(new.count) — triggering recomputeRails")
      recomputeRails(from: new)
    }
    // TASK-302: announce to VoiceOver once when content rails first appear
    .onChange(of: justAddedItems) { _, new in
      guard !new.isEmpty, !hasAnnouncedContent else { return }
      hasAnnouncedContent = true
      AccessibilityNotification.ScreenChanged(nil).post()
    }
    .onReceive(NotificationCenter.default.publisher(for: .playerDidDismiss)) { _ in
      loadLog.info("LibraryHomeView: playerDidDismiss — allItems=\(allItems.count), triggering refreshProgress")
      guard !allItems.isEmpty else {
        loadLog.warning("LibraryHomeView: playerDidDismiss — allItems empty, skipping refreshProgress")
        return
      }
      Task { await refreshProgress() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .networkDidReconnect)) { _ in
      loadLog.info("LibraryHomeView: networkDidReconnect — triggering load()")
      Task { await load() }
    }
    .background(Color.black.ignoresSafeArea())

    if isEmbedded {
      content
    } else {
      NavigationStack { content }
    }
  }

  // MARK: - Progress Refresh

  /// Fetches current watch progress for all in-memory items and merges it
  /// into `allItems`. Does NOT write to the cache — the cache is kept
  /// progress-free so stale progress never survives across app restarts.
  private func refreshProgress() async {
    guard !allItems.isEmpty, !appState.isDemoMode else {
      loadLog.debug("refreshProgress: skipped — allItems=\(allItems.count) isDemoMode=\(appState.isDemoMode)")
      return
    }
    let ids = allItems.map(\.id)
    let chunkSize = 200
    let chunks = stride(from: 0, to: ids.count, by: chunkSize).map {
      Array(ids[$0..<min($0 + chunkSize, ids.count)])
    }
    let progressStart = Date()
    loadLog.info("refreshProgress: starting — \(ids.count) items, \(chunks.count) chunks, maxConcurrent=4")
    let api = appState.api
    var progressMap: [String: ItemProgress] = [:]
    do {
      // Throttle to 4 concurrent requests — the NAS serializes beyond that anyway
      // and flooding it causes queue buildup that makes every request slower.
      // Per-batch failures are absorbed (Result wrapping) so a single failed batch
      // does not wipe all progress for the user (P2-2).
      let maxConcurrent = 4
      let results = try await withThrowingTaskGroup(of: Result<[String: ItemProgress], Error>.self) { group in
        var inFlight = 0
        var chunkIterator = chunks.makeIterator()
        // Seed the initial batch
        while inFlight < maxConcurrent, let chunk = chunkIterator.next() {
          group.addTask {
            do { return .success(try await api.progressBatch(ids: chunk).progress) }
            catch { return .failure(error) }
          }
          inFlight += 1
        }
        var merged: [String: ItemProgress] = [:]
        var batchIdx = 0
        for try await batchResult in group {
          switch batchResult {
          case .success(let batch):
            loadLog.debug("refreshProgress: batch \(batchIdx) OK — \(batch.count) progress entries")
            merged.merge(batch) { _, new in new }
          case .failure(let err):
            loadLog.warning("refreshProgress: batch \(batchIdx) FAILED — \(err.localizedDescription)")
          }
          batchIdx += 1
          inFlight -= 1
          // Enqueue next chunk as a slot opens
          if let chunk = chunkIterator.next() {
            group.addTask {
              do { return .success(try await api.progressBatch(ids: chunk).progress) }
              catch { return .failure(error) }
            }
            inFlight += 1
          }
        }
        return merged
      }
      progressMap = results
      allItems = allItems.map { item in
        if let p = progressMap[item.id] {
          return ItemSummary(id: item.id, type: item.type, title: item.title,
                             year: item.year, durationSeconds: item.durationSeconds,
                             addedAt: item.addedAt, rating: item.rating,
                             posterImageId: item.posterImageId,
                             backdropImageId: item.backdropImageId, progress: p,
                             showName: item.showName, seasonNumber: item.seasonNumber,
                             episodeNumber: item.episodeNumber)
        } else {
          return item.withoutProgress
        }
      }
      let elapsed = String(format: "%.3f", Date().timeIntervalSince(progressStart))
      loadLog.info("refreshProgress: done in \(elapsed)s — merged \(progressMap.count) of \(ids.count) items")
    } catch {
      let elapsed = String(format: "%.3f", Date().timeIntervalSince(progressStart))
      loadLog.warning("refreshProgress: FAILED after \(elapsed)s — \(error.localizedDescription)")
    }
  }

  // MARK: - Load

  private func load() async {
    let callID = Int.random(in: 1000...9999)  // unique ID per call so interleaved logs are traceable
    loadLog.info("load[\(callID)]: called — isLoading=\(isLoading) isCacheDecoding=\(isCacheDecoding) allItems=\(allItems.count) cont=\(continueWatchingItems.count) added=\(justAddedItems.count) watched=\(recentlyWatchedItems.count)")
    guard !isLoading, !isCacheDecoding else {
      loadLog.warning("load[\(callID)]: already loading or cache decoding, bailing out (isLoading=\(isLoading) isCacheDecoding=\(isCacheDecoding))")
      return
    }

    if appState.isDemoMode {
      loadLog.info("load[\(callID)]: demo mode — injecting DemoData")
      libraries = DemoData.libraries
      allItems = DemoData.movieItems + DemoData.tvItems
      return
    }

    let serverURL = appState.api.baseURL.absoluteString
    loadLog.info("load[\(callID)]: serverURL=\(serverURL)")

    // Items already in memory — re-entering tab or returning from player.
    if !allItems.isEmpty {
      loadLog.info("load[\(callID)]: PATH=in-memory — \(allItems.count) items already loaded, triggering background refresh")
      Task { await refreshProgress() }
      // isStale reads disk — do it off the main actor.
      Task {
        let stale = await Task.detached(priority: .utility) {
          HomeCache.isStale(serverURL: serverURL)
        }.value
        loadLog.info("load[\(callID)]: in-memory staleness check — stale=\(stale)")
        if stale {
          loadLog.info("load[\(callID)]: cache stale — background content refresh")
          backgroundFetchTask = Task { await fetchFromNetwork(serverURL: serverURL, background: true) }
        }
      }
      return
    }

    // Cold start: read cache off the main actor so we don't block the animation.
    let cacheExists = HomeCache.cacheFileExists()
    loadLog.info("load[\(callID)]: PATH=cold-start — cacheExists=\(cacheExists)")
    isLoading = !cacheExists
    isCacheDecoding = cacheExists   // suppress "Nothing here yet" while decode is in-flight
    loadLog.info("load[\(callID)]: state → isLoading=\(isLoading) isCacheDecoding=\(isCacheDecoding)")

    let decodeStart = Date()
    defer {
      isLoading = false
      isCacheDecoding = false
    }
    typealias CacheResult = (entry: HomeCacheEntry, rails: (continueWatching: [ItemSummary], justAdded: [ItemSummary], recentlyWatched: [ItemSummary]), stale: Bool)?
    let result: CacheResult = await Task.detached(priority: .userInitiated) {
      guard let (entry, stale) = HomeCache.loadWithStaleness(serverURL: serverURL) else { return nil }
      let rails = Self.computeRails(entry.items)
      return (entry, rails, stale)
    }.value

    let decodeElapsed = String(format: "%.3f", Date().timeIntervalSince(decodeStart))
    if let result {
      loadLog.info("load[\(callID)]: cache HIT in \(decodeElapsed)s — \(result.entry.items.count) items, stale=\(result.stale), cont=\(result.rails.continueWatching.count) added=\(result.rails.justAdded.count) watched=\(result.rails.recentlyWatched.count)")
      libraries = result.entry.libraries
      allItems = result.entry.items
      continueWatchingItems = result.rails.continueWatching
      justAddedItems = result.rails.justAdded
      recentlyWatchedItems = result.rails.recentlyWatched
      Task { await refreshProgress() }
      if result.stale {
        loadLog.info("load[\(callID)]: cache stale — launching background content refresh")
        backgroundFetchTask = Task { await fetchFromNetwork(serverURL: serverURL, background: true) }
      }
    } else {
      loadLog.info("load[\(callID)]: cache MISS after \(decodeElapsed)s — fetching from network")
      await fetchFromNetwork(serverURL: serverURL, background: false)
    }
  }

  /// Pull-to-refresh: cancel any in-flight background fetch, wipe the cache, and re-fetch everything.
  private func forceRefresh() async {
    guard !appState.isDemoMode else { return }
    let serverURL = appState.api.baseURL.absoluteString
    loadLog.info("forceRefresh: cancelling background task and invalidating cache")
    backgroundFetchTask?.cancel()
    backgroundFetchTask = nil
    isBackgroundRefreshing = false
    HomeCache.invalidate()
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
      Task.detached(priority: .utility) { HomeCache.touch(serverURL: serverURL) }
      libraries = libs
      appState.clearNetworkError()
      Task { await refreshProgress() }

    case .updated(let libs, let merged, let counts, let updatedAt):
      loadLog.info("fetchFromNetwork: update complete — \(merged.count) items")
      libraries = libs
      allItems = merged
      // Save off main actor — encoding 4563 items is ~2.7MB and blocks the run loop if done here
      Task.detached(priority: .utility) {
        HomeCache.save(serverURL: serverURL, libraries: libs, items: merged,
                       counts: counts, updatedAt: updatedAt)
      }
      appState.clearNetworkError()
      Task { await refreshProgress() }

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
      let cacheIsStale = HomeCache.isStale(serverURL: serverURL)

      var currentCounts: [String: Int] = [:]
      var currentUpdatedAt: [String: String] = [:]
      var libsNeedingRefresh: [Library] = []
      var resolvedLibraries: [Library] = cachedLibraries  // will be updated if we fetch the lib list

      // Step 1: Check for changes via lightweight summary endpoint (fast, ~0.07s).
      // Only fall back to fetching the full library list if summary is unavailable
      // or if we have no cached library list to work from.
      log.info("doFetch: calling /api/v1/libraries/summary for change detection (cacheStale=\(cacheIsStale))")
      let t1 = Date()
      if let summaries = try? await api.librariesSummary(), !cachedLibraries.isEmpty {
        let cachedUpdatedAt = cachedEntry?.libraryUpdatedAt ?? [:]
        log.info("doFetch: summary in \(String(format: "%.2f", Date().timeIntervalSince(t1)))s — \(summaries.libraries.count) entries")
        for s in summaries.libraries {
          currentCounts[s.libraryId] = s.count
          currentUpdatedAt[s.libraryId] = s.lastUpdatedAt
          let countChanged = cachedCounts[s.libraryId] != s.count
          let updatedAtChanged = cachedUpdatedAt[s.libraryId] != s.lastUpdatedAt
          let isNew = cachedCounts[s.libraryId] == nil
          log.info("  lib=\(s.libraryId) count=\(s.count) cached=\(cachedCounts[s.libraryId].map(String.init) ?? "nil") countChanged=\(countChanged) updatedAtChanged=\(updatedAtChanged) isNew=\(isNew)")
          if cacheIsStale || countChanged || updatedAtChanged || isNew {
            if let lib = cachedLibraries.first(where: { $0.id == s.libraryId }) {
              let reason = cacheIsStale ? "stale" : "count=\(countChanged) updatedAt=\(updatedAtChanged) new=\(isNew)"
              log.info("  → queuing '\(lib.title)' for item fetch (\(reason))")
              libsNeedingRefresh.append(lib)
            }
          }
        }

        // Nothing changed and cache is fresh — no network fetch needed
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
        resolvedLibraries = loadedLibs
        // currentCounts left empty — total unknown, pagination runs until server returns < pageSize
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
            let pageSize = 10_000
            var page = 0
            while true {
              let pageStart = Date()
              let response = try await api.items(libraryId: lib.id, limit: pageSize, offset: offset)
              log.info("  itemFetch[\(lib.id)]: page \(page) got=\(response.items.count) in \(String(format: "%.2f", Date().timeIntervalSince(pageStart)))s")
              libItems.append(contentsOf: response.items)
              page += 1
              if response.items.isEmpty || response.items.count < pageSize { break }
              if libItems.count >= response.total { break }
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

      return .updated(resolvedLibraries, merged, currentCounts, currentUpdatedAt)
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
        .padding(.horizontal, 16)
      }
    }
  }
}
