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
  @State private var isBackgroundRefreshing: Bool = false
  @State private var backgroundFetchTask: Task<Void, Never>?
  @State private var error: String?

  // Pre-computed rail data — updated off-main-thread whenever allItems changes.
  // Never computed inside body to avoid blocking the main thread with 4500+ item sorts.
  @State private var continueWatchingItems: [ItemSummary] = []
  @State private var justAddedItems: [ItemSummary] = []
  @State private var recentlyWatchedItems: [ItemSummary] = []
  // True only after the first recomputeRails() completes and writes results back.
  // Keeps skeletons visible during the gap between allItems arriving and rails being ready.
  @State private var railsReady: Bool = false

  private var firstMovieLibrary: Library? {
    libraries.first(where: { $0.kind == "movie" || $0.kind == "movies" }) ?? libraries.first
  }

  // MARK: - Rail Computation (off main thread)

  /// Recomputes all three rail arrays from `items` on a background thread, then
  /// applies the results back on @MainActor in a single atomic write.
  /// Always sets railsReady=true — call this only when items+progress are both final.
  private func recomputeRails(from items: [ItemSummary]) {
    Task.detached(priority: .userInitiated) {
      let (cont, added, watched) = Self.computeRails(items)
      await MainActor.run {
        self.continueWatchingItems = cont
        self.justAddedItems = added
        self.recentlyWatchedItems = watched
        self.railsReady = true
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
      if let error, allItems.isEmpty {
        // Only show the full error state when we have nothing to display at all
        VStack(spacing: 16) {
          ContentUnavailableView(
            "Couldn't load content",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
          Button("Retry") { Task { await load() } }
            .buttonStyle(.bordered)
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 28) {
            // All three rails are always in the view tree — no conditional mounting.
            // isLoading=true shows skeleton cards. Once railsReady, real items appear.
            // A section is only hidden (opacity+height collapsed) after the first
            // successful load confirms it has no items — never mid-load.
            HomeRail(
              title: "Continue Watching",
              items: continueWatchingItems,
              seeAllLibrary: firstMovieLibrary,
              isLoading: !railsReady
            )
            .opacity(railsReady && continueWatchingItems.isEmpty ? 0 : 1)
            .frame(height: railsReady && continueWatchingItems.isEmpty ? 0 : nil)
            .clipped()

            HomeRail(
              title: "Just Added",
              items: justAddedItems,
              seeAllLibrary: firstMovieLibrary,
              isLoading: !railsReady
            )
            .opacity(railsReady && justAddedItems.isEmpty ? 0 : 1)
            .frame(height: railsReady && justAddedItems.isEmpty ? 0 : nil)
            .clipped()

            HomeRail(
              title: "Recently Watched",
              items: recentlyWatchedItems,
              seeAllLibrary: firstMovieLibrary,
              isLoading: !railsReady
            )
            .opacity(railsReady && recentlyWatchedItems.isEmpty ? 0 : 1)
            .frame(height: railsReady && recentlyWatchedItems.isEmpty ? 0 : nil)
            .clipped()
          }
          .padding(.vertical, 16)
        }
      }
    }
    .navigationTitle("Home")
    .task { await load() }
    .refreshable { await forceRefresh() }
    .onDisappear {
      backgroundFetchTask?.cancel()
      isBackgroundRefreshing = false
    }
    .onReceive(NotificationCenter.default.publisher(for: .playerDidDismiss)) { _ in
      guard !allItems.isEmpty else { return }
      Task { await refreshProgress() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .networkDidReconnect)) { _ in
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
    guard !allItems.isEmpty, !appState.isDemoMode else { return }
    let ids = allItems.map(\.id)
    // Chunk into batches of 200 to avoid URL length limits on large libraries.
    // A single query with 4000+ IDs (~32KB URL) silently fails on most servers.
    let chunkSize = 200
    let chunks = stride(from: 0, to: ids.count, by: chunkSize).map {
      Array(ids[$0..<min($0 + chunkSize, ids.count)])
    }
    // Capture api reference before leaving @MainActor
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
        for try await batchResult in group {
          if case .success(let batch) = batchResult {
            merged.merge(batch) { _, new in new }
          }
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
      loadLog.info("refreshProgress: merged progress for \(progressMap.count) of \(ids.count) items (\(chunks.count) chunks)")
    } catch {
      loadLog.warning("refreshProgress: failed — \(error.localizedDescription)")
      // Non-fatal: rails will show without progress data
    }
    // Recompute rails now that items+progress are both final.
    // This is the only place recomputeRails is called — items alone (without progress)
    // would give wrong results (empty Continue Watching / Recently Watched).
    recomputeRails(from: allItems)
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

    // Items already in memory — re-entering tab or returning from player.
    if !allItems.isEmpty {
      Task { await refreshProgress() }
      // isStale reads disk — do it off the main actor.
      // Uses loadWithStaleness internally (single decode, P2-1).
      Task {
        let stale = await Task.detached(priority: .utility) {
          HomeCache.isStale(serverURL: serverURL)
        }.value
        if stale {
          loadLog.info("load: in-memory items, cache stale — background content refresh")
          backgroundFetchTask = Task { await fetchFromNetwork(serverURL: serverURL, background: true) }
        }
      }
      return
    }

    // Cold start: read cache off the main actor so we don't block the animation.
    // Rails are NOT computed here — cached items have no progress, so continueWatching
    // and recentlyWatched would be empty. Skeletons stay until refreshProgress()
    // finishes and recomputeRails() fires with items+progress both ready.
    isLoading = true
    typealias CacheResult = (entry: HomeCacheEntry, isStale: Bool)?
    let result: CacheResult = await Task.detached(priority: .userInitiated) {
      HomeCache.loadWithStaleness(serverURL: serverURL)
    }.value

    isLoading = false
    if let result {
      loadLog.info("load: cache HIT — \(result.entry.items.count) items, stale=\(result.isStale)")
      libraries = result.entry.libraries
      allItems = result.entry.items
      // railsReady stays false — skeletons shown until refreshProgress() → recomputeRails()
      Task { await refreshProgress() }
      if result.isStale {
        loadLog.info("load: cache stale — background content refresh")
        backgroundFetchTask = Task { await fetchFromNetwork(serverURL: serverURL, background: true) }
      }
    } else {
      loadLog.info("load: no cache — fetching from network")
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
    railsReady = false
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
  var isLoading: Bool = false

  // Poster card: 120pt wide, 2:3 aspect → 180pt tall
  private let cardWidth: CGFloat = 120
  private let skeletonCount = 5

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Header row — always shown, "See All" hidden while loading
      HStack {
        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        if !isLoading, let lib = seeAllLibrary {
          NavigationLink("See All") {
            ItemsGridView(library: lib)
          }
          .font(.subheadline)
          .foregroundStyle(Color.dsAccent)
          .padding(.vertical, 12)
          .accessibilityLabel("See all in \(title)")
        }
      }
      .padding(.horizontal, 16)

      // Horizontal scroll — real cards or skeleton placeholders
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 10) {
          if isLoading {
            ForEach(0..<skeletonCount, id: \.self) { _ in
              SkeletonPosterCard(width: cardWidth)
            }
          } else {
            ForEach(items) { item in
              NavigationLink {
                ItemDetailView(itemID: item.id, fallbackTitle: item.title)
              } label: {
                ItemPosterCell(item: item)
                  .frame(width: cardWidth)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(item.title + (item.year.map { ", \($0)" } ?? ""))
              .accessibilityHint("Opens video details")
            }
          }
        }
        .padding(.horizontal, 16)
      }
      .accessibilityLabel(isLoading ? "\(title), loading" : title)
    }
  }
}

// MARK: - SkeletonPosterCard

private struct SkeletonPosterCard: View {
  let width: CGFloat
  @State private var shimmerPhase: CGFloat = 0

  private var height: CGFloat { width * 1.5 }

  var body: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(Color.white.opacity(0.08))
      .frame(width: width, height: height)
      .overlay(
        // Shimmer sweep
        GeometryReader { geo in
          LinearGradient(
            gradient: Gradient(colors: [
              .clear,
              Color.white.opacity(0.12),
              .clear,
            ]),
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: geo.size.width * 2)
          .offset(x: shimmerPhase * (geo.size.width * 3) - geo.size.width)
          .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      )
      .accessibilityHidden(true)
      .onAppear {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
          shimmerPhase = 1
        }
      }
  }
}

