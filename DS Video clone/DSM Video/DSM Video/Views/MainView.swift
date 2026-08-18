import SwiftUI

struct MainView: View {
  enum Layout {
    case tabs
    case split
  }

  @Environment(AppState.self) private var appState
  let layout: Layout

  var body: some View {
    // TASK-884: the offline banner is an OVERLAY on the content, not a ZStack sibling.
    //
    // It used to be a second child of a ZStack — a VStack whose trailing Spacer() expanded to
    // full height. That made the banner layer as tall as the screen, so the ZStack sized to it
    // and SWALLOWED the tab bar's safe-area inset before the TabView's content could ever see
    // it. Net effect: every safeAreaInset / padding / spacer added inside LibraryHomeView was
    // discarded, which is why three separate attempts down there produced an IDENTICAL pixel
    // signature and the "Recently Watched" header kept rendering behind the glass bar.
    //
    // As an .overlay the banner is measured against the content rather than participating in
    // its layout, so the inset propagates normally and the child's own clearance takes effect.
    Group {
      switch layout {
      case .tabs:
        // TASK-858: tab titles are Title Case, not ALL CAPS.
        //
        // The selection pill and tab slot widths are drawn by the system tab bar, not by
        // this app — we cannot reposition the pill. What we control is label width, and
        // all-caps labels are materially wider than the system lays out for: the HOME
        // pill's trailing edge clipped the leading "L" of "LIBRARIES", which rendered as
        // "IBRARIES". This reproduced at DEFAULT Dynamic Type, so it is a plain sizing
        // overflow rather than an accessibility-scaling artifact. Title Case fits, and
        // matches the platform convention for tab items besides.
        TabView {
          LibraryHomeView()
            .tabItem { Label("Home", systemImage: "play.rectangle") }

          LibrariesView()
            .tabItem { Label("Libraries", systemImage: "square.grid.2x2") }

          // Search is no longer a dedicated tab — it lives as a magnifying-glass
          // toolbar button inside each library view (Movies / TV Shows). Dropping
          // it to 5 tabs keeps Watchlist + Settings at surface level instead of
          // being collapsed into the system "More" tab.
          DownloadsView()
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

          WatchlistView()
            .tabItem { Label("Watchlist", systemImage: "bookmark") }

          SettingsView()
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color.dsAccent)
      case .split:
        SplitView()
      }
    }
    .overlay(alignment: .top) {
      OfflineBanner(isOffline: appState.isOffline, serverUnreachable: appState.serverUnreachable)
        .animation(.easeInOut(duration: 0.3), value: appState.isOffline || appState.serverUnreachable)
    }
  }
}

// MARK: - iPad Split View

private enum SidebarSelection: Hashable {
  case home
  case search
  case downloads
  case settings
  case library(Library)
}

private struct SplitView: View {
  @State private var selection: SidebarSelection? = .home
  @State private var libraries: [Library] = []

  private var isHomeSelected: Bool {
    switch selection {
    case .home, .none: return true
    default: return false
    }
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selection, libraries: $libraries)
        // Constrain the sidebar so it doesn't overflow or get truncated at narrow
        // Split View / Stage Manager widths on iPad.
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
    } detail: {
      // One NavigationStack owns all detail navigation. LibraryHomeView stays permanently
      // in the tree (opacity trick) so its @State (allItems, rails, etc.) survives navigation.
      // Without this, switching to a library and back recreates LibraryHomeView from scratch,
      // discarding all loaded data and forcing a full reload every time.
      NavigationStack {
        ZStack {
          LibraryHomeView(isEmbedded: true)
            .opacity(isHomeSelected ? 1 : 0)
            .allowsHitTesting(isHomeSelected)
            .accessibilityHidden(!isHomeSelected)

          if !isHomeSelected {
            detailContent
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // Tint the whole split view so the sidebar selection highlight and row icons
    // use the theme accent (red for Classic / amber for Nitrate) instead of system blue.
    .tint(Color.dsAccent)
  }

  @ViewBuilder
  private var detailContent: some View {
    switch selection {
    case .home, .none:
      EmptyView()
    case .search:
      SearchView(isEmbedded: true)
    case .downloads:
      DownloadsView(isEmbedded: true)
    case .settings:
      SettingsView(isEmbedded: true)
    case .library(let selectedLib):
      // Re-resolve from libraries binding by ID so an update to the libraries list
      // (e.g. from a delta sync populating homeLibraries) doesn't create a new Library
      // value and tear down TVShowsView mid-load, cancelling its .task.
      let lib = libraries.first(where: { $0.id == selectedLib.id }) ?? selectedLib
      if lib.kind == "tv" {
        TVShowsView(library: lib)
      } else {
        ItemsGridView(library: lib)
      }
    }
  }
}

private struct SidebarView: View {
  @Environment(AppState.self) private var appState
  @Binding var selection: SidebarSelection?
  /// Libraries provided by the parent SplitView; this view populates them on first load
  /// so the parent can share the same list without a duplicate API call.
  @Binding var libraries: [Library]
  @State private var isLoading = false
  // TASK-793: distinguish a genuinely-empty server from a load failure.
  @State private var loadError: String?

  private var movieLibraries: [Library] {
    libraries.filter { ["movie", "movies", "home", "homevideo"].contains($0.kind) }
  }
  private var tvLibraries: [Library] {
    libraries.filter { $0.kind == "tv" }
  }

  var body: some View {
    List(selection: $selection) {
      Section {
        Label("Home", systemImage: "play.rectangle")
          .tag(SidebarSelection.home)
        Label("Search", systemImage: "magnifyingglass")
          .tag(SidebarSelection.search)
        Label("Downloads", systemImage: "arrow.down.circle")
          .tag(SidebarSelection.downloads)
      } header: {
        SidebarSectionHeader("Browse")
      }

      Section {
        if isLoading && libraries.isEmpty {
          Label("Loading…", systemImage: "hourglass")
            .foregroundStyle(.secondary)
        } else {
          ForEach(movieLibraries) { lib in
            Label(lib.title, systemImage: "film")
              .tag(SidebarSelection.library(lib))
          }
          ForEach(tvLibraries) { lib in
            Label(lib.title, systemImage: "tv")
              .tag(SidebarSelection.library(lib))
          }
          if !isLoading && movieLibraries.isEmpty && tvLibraries.isEmpty {
            if let loadError {
              // TASK-793: a load failure is not an empty library — show the error + retry.
              VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't load libraries", systemImage: "exclamationmark.triangle")
                  .foregroundStyle(Color.dsError)
                Text(loadError)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Button("Retry") {
                  Task { await loadLibraries(force: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
            } else {
              Label("No libraries", systemImage: "tray")
                .foregroundStyle(.secondary)
            }
          }
        }
      } header: {
        SidebarSectionHeader("Library")
      }

      Section {
        Label("Settings", systemImage: "gearshape")
          .tag(SidebarSelection.settings)
      } header: {
        SidebarSectionHeader("Settings")
      }
    }
    .navigationTitle(AppInfo.displayName)
    .task { await loadLibraries() }
  }

  private func loadLibraries(force: Bool = false) async {
    guard (force || libraries.isEmpty) && !isLoading else { return }
    if appState.isDemoMode {
      libraries = DemoData.libraries
      return
    }
    // Use AppState's already-populated homeLibraries to avoid a duplicate API call (TASK-256).
    if !force && !appState.homeLibraries.isEmpty {
      libraries = appState.homeLibraries
      return
    }
    isLoading = true
    loadError = nil
    defer { isLoading = false }
    // TASK-793: capture the failure so the sidebar can show an error+retry instead of
    // masquerading a network failure as an empty library.
    do {
      let response = try await appState.api.libraries()
      libraries = response.libraries
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }
}

private struct SidebarSectionHeader: View {
  let title: String
  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title)
      .font(.system(.title3, design: .rounded, weight: .semibold))
      .foregroundStyle(.primary)
      .textCase(nil)
      .lineLimit(2)
      .padding(.top, 6)
  }
}


private struct SearchView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  var isEmbedded: Bool = false
  @State private var searchText: String = ""
  @State private var results: [ItemSummary] = []
  @State private var isSearching: Bool = false
  @State private var hasSearched: Bool = false
  @State private var searchError: String?
  @State private var debounceTask: Task<Void, Never>?
  @State private var searchTask: Task<Void, Never>?
  @AppStorage("dsReel.recentSearches") private var recentSearchesRaw: String = ""

  private var recentSearches: [String] {
    recentSearchesRaw.isEmpty ? [] : recentSearchesRaw.components(separatedBy: "\u{001F}").filter { !$0.isEmpty }
  }

  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
  }

  var body: some View {
    let content = ScrollView {
      if searchText.isEmpty && !hasSearched {
        if recentSearches.isEmpty {
          DSContentUnavailable(title: "Search Videos", systemImage: "magnifyingglass", description: "Enter a title to search your library")
            .padding(.top, 60)
        } else {
          RecentSearchesView(
            searches: recentSearches,
            onSelect: { query in
              searchText = query
              Task { await search(commit: true) }
            },
            onRemove: { query in removeRecentSearch(query) },
            onClearAll: { recentSearchesRaw = "" }
          )
          .padding(.top, 16)
        }
      } else if isSearching {
        ProgressView("Searching for videos")
          .padding(.top, 60)
      } else if let searchError {
        VStack(spacing: 16) {
          Image(systemName: "wifi.slash")
            .font(.system(size: 44))
            .foregroundStyle(Color.dsError)
            .accessibilityHidden(true)
          Text("Search Failed")
            .font(.headline)
            .foregroundStyle(Color.dsError)
          Text(searchError)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
          Button {
            Task { await search(commit: true) }
          } label: {
            Text("Retry")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 24)
              .padding(.vertical, 10)
              .background(Color.dsError)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)
        }
        .padding(.top, 60)
      } else if hasSearched && results.isEmpty {
        DSContentUnavailable(title: "No Results", systemImage: "magnifyingglass", description: "No videos match \"\(searchText)\"")
          .padding(.top, 60)
      } else if !results.isEmpty {
        LazyVStack(spacing: 0) {
          ForEach(results) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              SearchResultCell(item: item)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title)\(item.year.map { ", \($0)" } ?? ""), \(readableType(item.type))")
            .accessibilityHint("Opens video details")

            Divider()
              .background(Color(white: 0.18))
              .padding(.leading, 12 + 60 + 12)
          }
        }
        .padding(.vertical, 8)
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle("Search")
    .searchable(text: $searchText, prompt: "Search videos")
    .onSubmit(of: .search) {
      // Explicit submit — this is the only path that records a recent search.
      searchTask?.cancel()
      searchTask = Task { await search(commit: true) }
    }
    .onChange(of: searchText) { _, newValue in
      if newValue.isEmpty {
        debounceTask?.cancel()
        searchTask?.cancel()
        results = []
        hasSearched = false
        searchError = nil
      } else if newValue.count >= 2 {
        debounceTask?.cancel()
        debounceTask = Task {
          if (try? await Task.sleep(for: .milliseconds(400))) != nil {
            // Live/debounced search as you type — show results but do NOT save the
            // partial query to recent searches (only an explicit submit does).
            searchTask?.cancel()
            searchTask = Task { await search(commit: false) }
          }
        }
      }
    }
    .onAppear {
      // Seed demo recent searches once if list is empty
      if appState.isDemoMode && recentSearchesRaw.isEmpty {
        recentSearchesRaw = ["Action movies", "The Signal", "2024"].joined(separator: "\u{001F}")
      }
    }
    .onChange(of: results) { _, newResults in
      guard hasSearched && !isSearching else { return }
      let message = newResults.isEmpty
        ? "No results found"
        : "\(newResults.count) result\(newResults.count == 1 ? "" : "s") found"
      AccessibilityNotification.Announcement(message).post()
    }

    if isEmbedded {
      content
    } else {
      NavigationStack { content }
    }
  }

  /// commit == true only on explicit submit (return key / tapping a recent search),
  /// which is the only case that records the query into recent searches. Live
  /// debounced searches pass false so partial phrases aren't saved.
  private func search(commit: Bool) async {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2 else { return }
    // TASK-795: re-entrancy guard — rapid recent-search taps were spawning concurrent
    // search() calls racing the same result state. Bail if one is already in flight.
    guard !isSearching else { return }

    isSearching = true
    hasSearched = true
    defer { isSearching = false }

    // In demo mode, filter local demo items instead of hitting the network.
    guard !appState.isDemoMode else {
      let allDemoItems = DemoData.movieItems + DemoData.tvItems
      results = allDemoItems.filter {
        $0.title.localizedCaseInsensitiveContains(query)
      }
      searchError = nil
      if commit { saveRecentSearch(query) }
      return
    }

    do {
      let response = try await appState.api.search(query: query, limit: 100)
      results = response.items
      searchError = nil
      if commit { saveRecentSearch(query) }
    } catch {
      appState.handleConnectionFailure(error)
      results = []
      let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
      searchError = msg
    }
  }

  private func readableType(_ type: String) -> String {
    switch type {
    case "movie": return "Movie"
    case "tvshow": return "TV Show"
    case "episode": return "Episode"
    case "homeVideo": return "Home Video"
    case "video": return "Video"
    default: return type.capitalized
    }
  }

  private func saveRecentSearch(_ query: String) {
    var current = recentSearches
    current.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
    current.insert(query, at: 0)
    if current.count > 10 { current = Array(current.prefix(10)) }
    recentSearchesRaw = current.joined(separator: "\u{001F}")
  }

  private func removeRecentSearch(_ query: String) {
    var current = recentSearches
    current.removeAll { $0 == query }
    recentSearchesRaw = current.joined(separator: "\u{001F}")
  }
}

// MARK: - Recent Searches View

private struct RecentSearchesView: View {
  let searches: [String]
  let onSelect: (String) -> Void
  let onRemove: (String) -> Void
  let onClearAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Recent Searches")
          .font(.headline)
          .foregroundStyle(Color.dsTextPrimary)
        Spacer()
        Button("Clear All", action: onClearAll)
          .font(.subheadline)
          .foregroundStyle(Color.dsAccent)
      }
      .padding(.horizontal, 16)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(searches, id: \.self) { query in
            HStack(spacing: 4) {
              Button {
                onSelect(query)
              } label: {
                Text(query)
                  .font(.subheadline)
                  .foregroundStyle(Color.dsTextPrimary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Search for \(query)")

              Button {
                onRemove(query)
              } label: {
                Image(systemName: "xmark")
                  .font(.caption2)
                  .foregroundStyle(Color.dsTextSecondary)
                  .frame(minWidth: 44, minHeight: 44)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Remove \(query) from recent searches")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.dsSurface)
            )
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }
}

private struct SearchResultCell: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

  private var typeLabel: String {
    switch item.type {
    case "movie": return "Movie"
    case "episode": return "Episode"
    case "tvshow": return "TV Show"
    case "homeVideo": return "Home Video"
    case "video": return "Video"
    default: return item.type.capitalized
    }
  }

  private var metaSubtitle: String {
    var parts: [String] = []
    if let year = item.year { parts.append(String(year)) }
    if let secs = item.durationSeconds, secs > 0 {
      let h = secs / 3600
      let m = (secs % 3600) / 60
      parts.append(h > 0 ? "\(h)h \(m)m" : "\(m)m")
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(spacing: 12) {
      // Thumbnail: 60x90pt
      posterThumbnail
        .frame(width: 60, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)

      // Metadata
      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color.dsTextPrimary)
          .lineLimit(2)

        if !metaSubtitle.isEmpty {
          Text(metaSubtitle)
            .font(.system(size: 12))
            .foregroundStyle(Color.dsTextMuted)
        }

        Text(typeLabel)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color.dsAccent)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Color.dsAccent.opacity(0.15))
          .clipShape(Capsule())
      }

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(minHeight: 100)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var posterThumbnail: some View {
    if appState.isDemoMode, let assetName = DemoData.posterAssetNames[item.id] {
      Image(assetName)
        .resizable()
        .scaledToFill()
    } else if item.posterImageId != nil {
      AuthenticatedImage(
        url: appState.api.imageURL(id: item.posterImageId ?? item.id, width: 200, version: item.changeSeq),
        token: appState.sessionToken,
        usesTunnelCookie: appState.api.usesTunnelCookie
      )
      .scaledToFill()
    } else {
      Rectangle()
        .fill(Color(white: 0.10))
        .overlay(
          Image(systemName: "film.fill")
            .font(.system(size: 20))
            .foregroundStyle(.white.opacity(0.25))
        )
    }
  }
}

// MARK: - Watchlist View

struct WatchlistView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
  }

  var body: some View {
    NavigationStack {
      Group {
        // TASK-851: a load FAILURE must not render as "you have nothing saved". Check the
        // error flag BEFORE the empty state, or a network blip silently tells the user
        // their watchlist is empty — indistinguishable from having actually lost it.
        if appState.watchlistLoadFailed && appState.watchlistItems.isEmpty {
          ErrorRetryView(
            title: "Couldn't load your watchlist",
            message: "Check your connection to the server and try again."
          ) {
            Task { await appState.loadWatchlist() }
          }
        } else if appState.watchlistItems.isEmpty {
          DSContentUnavailable(
            title: "No Watchlist Items",
            systemImage: "bookmark",
            description: "Tap the bookmark button on any video to save it here."
          )
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
              ForEach(appState.watchlistItems) { item in
                NavigationLink {
                  ItemDetailView(itemID: item.id, fallbackTitle: item.title)
                } label: {
                  ItemPosterCell(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title)\(item.year.map { ", \($0)" } ?? "")")
                .accessibilityHint("Opens video details")
              }
            }
            .padding(12)
          }
        }
      }
      .background(Color.black.ignoresSafeArea())
      .navigationTitle("Watchlist")
      .task { await appState.loadWatchlist() }
      // FIX-15: refresh watchlist when network reconnects after being offline
      .onReceive(NotificationCenter.default.publisher(for: .networkDidReconnect)) { _ in
        Task { await appState.loadWatchlist() }
      }
    }
  }
}

struct DownloadsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  var isEmbedded: Bool = false
  @State private var downloads: [DownloadedItem] = []
  @State private var totalBytes: Int64 = 0
  @State private var availableBytes: Int64 = 0
  @State private var usedByAppBytes: Int64 = 0
  @State private var showPlayer = false
  @State private var playerItem: DownloadedItem?

  private let downloadManager = DownloadManager.shared

  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
  }

  private var activeDownloadIDs: [String] {
    Array(downloadManager.activeDownloads.keys).sorted()
  }

  private var pausedDownloadIDs: [String] {
    Array(downloadManager.pausedDownloads.keys).sorted()
  }

  private var inProgressIDs: [String] {
    // Combined: active (downloading) + paused — both shown in the "Downloading" section
    let all = Set(activeDownloadIDs).union(Set(pausedDownloadIDs))
    return all.sorted()
  }

  // TASK-782: genuinely-failed downloads, shown in their own "Failed" section with retry.
  private var failedDownloadIDs: [String] {
    Array(downloadManager.failedDownloads.keys).sorted()
  }

  var body: some View {
    let content = Group {
      if downloads.isEmpty && inProgressIDs.isEmpty && failedDownloadIDs.isEmpty {
        DSContentUnavailable(title: "No Downloads", systemImage: "arrow.down.circle", description: "Downloaded videos will appear here for offline viewing")
      } else {
        ScrollView {
          VStack(spacing: 16) {
            // Storage indicator
            storageSection

            // Failed downloads (TASK-782) — surfaced so a failure isn't silent.
            if !failedDownloadIDs.isEmpty {
              failedDownloadsSection
            }

            // Active and paused downloads
            if !inProgressIDs.isEmpty {
              activeDownloadsSection
            }

            // Completed downloads grid
            if !downloads.isEmpty {
              LazyVGrid(columns: columns, spacing: 12) {
                ForEach(downloads) { item in
                  Button {
                    // TASK-796: guard against a double-tap setting playerItem twice
                    // before the cover presents.
                    guard !showPlayer else { return }
                    playerItem = item
                    showPlayer = true
                  } label: {
                    DownloadedItemCell(item: item) {
                      deleteDownload(item)
                    }
                  }
                  .buttonStyle(.plain)
                  .accessibilityHint("Double-tap to play")
                }
              }
              .padding(.horizontal, horizontalSizeClass == .regular ? 20 : 12)
              .padding(.bottom, horizontalSizeClass == .regular ? 20 : 12)
            }
          }
        }
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle("Downloads")
    .onAppear {
      loadDownloads()
      loadStorageInfo()
    }
    // FIX-15: refresh downloads list when network reconnects — picks up any
    // active downloads that were interrupted and may have resumed on the server.
    .onReceive(NotificationCenter.default.publisher(for: .networkDidReconnect)) { _ in
      loadDownloads()
      loadStorageInfo()
    }
    .onChange(of: downloadManager.activeDownloads.count) { _, _ in
      loadDownloads()
      loadStorageInfo()
    }
    .onChange(of: downloadManager.pausedDownloads.count) { _, _ in
      loadDownloads()
      loadStorageInfo()
    }
    .onChange(of: downloadManager.failedDownloads.count) { _, _ in
      loadStorageInfo()
    }
    .fullScreenCover(isPresented: $showPlayer, onDismiss: { showPlayer = false }) {
      if let item = playerItem {
        GestureVideoPlayer(
          url: URL(fileURLWithPath: item.videoPath),
          title: item.title,
          resumePosition: Double(item.resumePositionSeconds),
          onDismiss: { showPlayer = false },
          onProgressUpdate: { currentTime, duration in
            let pos = Int(currentTime)
            DownloadManager.shared.updateResumePosition(
              itemId: item.id,
              positionSeconds: pos
            )
            // TASK-730: also record through AppState so LocalStore (Continue Watching)
            // and the server are updated. The offline asset's reported duration can be
            // 0 early, so fall back to the item's stored duration. recordProgress's
            // server write reconciles automatically once the device is back online.
            let dur = duration > 0 ? Int(duration) : item.durationSeconds
            if dur > 0 {
              Task { await appState.recordProgress(itemId: item.id, positionSeconds: pos, durationSeconds: dur) }
            }
          }
        )
        #if !os(tvOS)
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
      }
    }

    if isEmbedded {
      content
    } else {
      NavigationStack { content }
    }
  }

  // MARK: - Storage Section

  @ViewBuilder
  private var storageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Storage")
          .font(.headline)
          .foregroundStyle(Color.dsTextPrimary)
        Spacer()
        Text("\(formatBytes(usedByAppBytes)) used")
          .font(.caption)
          .foregroundStyle(Color.dsTextSecondary)
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.dsSurface)
            .frame(height: 10)
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.dsAccent)
            .frame(
              width: totalBytes > 0
                ? geo.size.width * CGFloat(Double(usedByAppBytes) / Double(totalBytes))
                : 0,
              height: 10
            )
        }
      }
      .frame(height: 10)
      Text("\(formatBytes(availableBytes)) of \(formatBytes(totalBytes)) available")
        .font(.caption)
        .foregroundStyle(Color.dsTextSecondary)
    }
    .padding()
    .background(Color.dsSurface.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal)
    .padding(.top, 8)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Storage: \(formatBytes(usedByAppBytes)) used by downloads, \(formatBytes(availableBytes)) of \(formatBytes(totalBytes)) available")
  }

  // MARK: - Active Downloads Section

  @ViewBuilder
  // TASK-782: renders each failed download with its reason and a Retry (transient) or
  // dismiss (permanent) affordance, so a failure is never silent.
  private var failedDownloadsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Failed")
        .font(.headline)
        .foregroundStyle(Color.dsTextPrimary)
        .padding(.horizontal)

      VStack(spacing: 0) {
        ForEach(failedDownloadIDs, id: \.self) { itemID in
          if let failure = downloadManager.failedDownloads[itemID] {
            HStack(spacing: 12) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(Color.dsTextPrimary)
                  .lineLimit(1)
                Text(failure.message)
                  .font(.caption)
                  .foregroundStyle(Color.dsTextSecondary)
                  .lineLimit(2)
              }
              Spacer()
              if failure.isPermanent {
                Button {
                  downloadManager.dismissFailedDownload(itemId: itemID)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.dsTextSecondary)
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss failed download \(failure.title)")
              } else {
                Button {
                  downloadManager.retryFailedDownload(itemId: itemID)
                } label: {
                  Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dsAccent)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry download \(failure.title)")
              }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if itemID != failedDownloadIDs.last {
              Divider()
                .background(Color.dsSurface)
                .padding(.horizontal)
            }
          }
        }
      }
      .background(Color.dsSurface.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal)
    }
  }

  private var activeDownloadsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Downloading")
        .font(.headline)
        .foregroundStyle(Color.dsTextPrimary)
        .padding(.horizontal)

      VStack(spacing: 0) {
        ForEach(inProgressIDs, id: \.self) { itemID in
          let isActive = downloadManager.isDownloading(itemId: itemID)
          let isPaused = downloadManager.isPaused(itemId: itemID)
          // Resolve title: active downloads have an ActiveDownload entry; paused ones
          // keep their info in pendingDownloadInfo (private) — we surface the title via
          // the activeDownloads entry while active, or fall back to a generic label.
          let download = downloadManager.activeDownloads[itemID]
          let progress = downloadManager.downloadProgress[itemID] ?? 0
          // Active downloads carry a title in ActiveDownload; paused ones expose it via
          // pausedDownloadTitle(itemId:) which reads from pendingDownloadInfo.
          let displayTitle: String = download?.title
            ?? downloadManager.pausedDownloadTitle(itemId: itemID)
            ?? "Downloading\u{2026}"

          ActiveDownloadCell(
            title: displayTitle,
            progress: progress,
            isActive: isActive,
            isPaused: isPaused,
            onPause: { Task { await downloadManager.pauseDownload(itemId: itemID) } },
            onResume: { downloadManager.resumeDownload(itemId: itemID) },
            onCancel: { downloadManager.cancelDownload(itemId: itemID) }
          )
          .padding(.horizontal)
          .padding(.vertical, 8)

          if itemID != inProgressIDs.last {
            Divider()
              .background(Color.dsSurface)
              .padding(.horizontal)
          }
        }
      }
      .background(Color.dsSurface.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal)
    }
  }

  // MARK: - Helpers

  private func loadDownloads() {
    downloads = DownloadManager.shared.getDownloadedItems()
  }

  private func deleteDownload(_ item: DownloadedItem) {
    DownloadManager.shared.deleteDownload(itemId: item.id)
    loadDownloads()
    loadStorageInfo()
  }

  private func loadStorageInfo() {
    let currentDownloads = downloads
    Task {
      let (total, available, used) = await computeStorageInfo(downloads: currentDownloads)
      totalBytes = total
      availableBytes = available
      usedByAppBytes = used
    }
  }

  private nonisolated func computeStorageInfo(downloads: [DownloadedItem]) async -> (Int64, Int64, Int64) {
    guard let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return (0, 0, 0)
    }
    let total: Int64
    let available: Int64
    #if !os(tvOS)
    let values = try? docURL.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeTotalCapacityKey
    ])
    total = Int64(values?.volumeTotalCapacity ?? 0)
    available = values?.volumeAvailableCapacityForImportantUsage ?? 0
    #else
    let values = try? docURL.resourceValues(forKeys: [.volumeTotalCapacityKey])
    total = Int64(values?.volumeTotalCapacity ?? 0)
    available = 0
    #endif

    let used = downloads.reduce(Int64(0)) { sum, item in
      let size = Int64((try? URL(fileURLWithPath: item.videoPath)
        .resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
      return sum + size
    }
    return (total, available, used)
  }

  private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

// MARK: - Active Download Cell

private struct ActiveDownloadCell: View {
  let title: String
  let progress: Double
  let isActive: Bool
  let isPaused: Bool
  let onPause: () -> Void
  let onResume: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text(title)
            .font(.subheadline)
            .foregroundStyle(Color.dsTextPrimary)
            .lineLimit(1)
          if isPaused {
            Text("Paused")
              .font(.caption2)
              .foregroundStyle(Color.dsTextSecondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.dsSurface)
              .clipShape(RoundedRectangle(cornerRadius: 4))
          }
        }
        ProgressView(value: progress)
          .tint(isPaused ? Color.dsTextSecondary : Color.dsAccent)
        Text("\(Int(progress * 100))%")
          .font(.caption)
          .foregroundStyle(Color.dsTextSecondary)
          .monospacedDigit()
      }

      Spacer()

      // Pause / Resume button — 44 pt tap target
      if isActive {
        Button(action: onPause) {
          Image(systemName: "pause.circle.fill")
            .font(.title3)
            .foregroundStyle(Color.dsAccent)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityLabel("Pause download")
      } else if isPaused {
        Button(action: onResume) {
          Image(systemName: "play.circle.fill")
            .font(.title3)
            .foregroundStyle(Color.dsAccent)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityLabel("Resume download")
      }

      // Cancel button — always present
      Button(action: onCancel) {
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .foregroundStyle(Color.dsTextSecondary)
      }
      .buttonStyle(.plain)
      .frame(width: 44, height: 44)
      .accessibilityLabel("Cancel download")
    }
    .accessibilityLabel(isPaused
      ? "\(title), paused at \(Int(progress * 100)) percent"
      : "\(title), downloading, \(Int(progress * 100)) percent complete"
    )
    .accessibilityAction(named: "Cancel download") { onCancel() }
  }
}

private struct DownloadedItemCell: View {
  let item: DownloadedItem
  let onDelete: () -> Void

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height = width * (3.0 / 2.0)

      ZStack(alignment: .bottom) {
        posterImage(width: width, height: height)

        // Visible delete button in top-right corner
        Button {
          onDelete()
        } label: {
          Image(systemName: "trash")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(6)
            .background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: height, alignment: .topTrailing)
        .padding(.top, 6)
        .padding(.trailing, 6)
        .accessibilityLabel("Delete \(item.title)")

        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.45),
            .init(color: .black.opacity(0.85), location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .allowsHitTesting(false)

        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

          Text(formatFileSize(item.fileSize))
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)

        // Resume progress bar — only shown when there is a meaningful resume position
        if item.resumePositionSeconds > 0 && item.durationSeconds > 0 {
          let frac = min(1.0, Double(item.resumePositionSeconds) / Double(item.durationSeconds))
          if frac < PlaybackProgress.watchedThreshold {
            VStack(spacing: 0) {
              Spacer()
              GeometryReader { barGeo in
                ZStack(alignment: .leading) {
                  Color.white.opacity(0.25)
                    .frame(height: 3)
                  Color.dsAccent
                    .frame(width: barGeo.size.width * frac, height: 3)
                }
              }
              .frame(height: 3)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
          }
        }
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .contextMenu {
        Button(role: .destructive) {
          onDelete()
        } label: {
          Label("Delete Download", systemImage: "trash")
        }
      }
      .accessibilityAction(named: "Delete") { onDelete() }
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
    .accessibilityLabel("\(item.title), downloaded")
  }

  private func posterImage(width: CGFloat, height: CGFloat) -> some View {
    Group {
      if let posterPath = item.posterPath, let image = loadLocalImage(from: posterPath) {
        image
          .resizable()
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
  }

  private func loadLocalImage(from path: String) -> Image? {
    #if canImport(UIKit)
    guard let uiImage = UIImage(contentsOfFile: path) else { return nil }
    return Image(uiImage: uiImage)
    #else
    guard let nsImage = NSImage(contentsOfFile: path) else { return nil }
    return Image(nsImage: nsImage)
    #endif
  }

  private func formatFileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.openURL) private var openURL
  // TASK-738: defaults to true via DownloadManager's registerDefaults.
  @AppStorage("dsReel.downloadsWifiOnly") private var downloadsWifiOnly: Bool = true
  // TASK-739: subtitle appearance (defaults registered in SubtitleStyle).
  @AppStorage("dsReel.subtitleScale") private var subtitleScale: Double = 1.0
  @AppStorage("dsReel.subtitleTextColor") private var subtitleTextColor: String = "#FFFFFF"
  @AppStorage("dsReel.subtitleBackgroundOpacity") private var subtitleBackgroundOpacity: Double = 0.0
  // Theme selection (Classic / Nitrate). Shared key with the app entry.
  @AppStorage("dsReel.theme") private var themeIDRaw: String = ThemeID.classic.rawValue
  var isEmbedded: Bool = false

  // A15: confirm destructive logout. A14: confirm Change Server (returns to onboarding).
  @State private var showLogoutConfirm = false
  @State private var showChangeServerConfirm = false

  var body: some View {
    @Bindable var appState = appState

    let form = Form {
      Section {
        // A14: read-only connected-server display + Change Server (mirrors tvOS).
        // TASK-809: long QuickConnect/DDNS URLs must truncate rather than overflow the row.
        LabeledContent("Connected To") {
          Text(appState.baseURL.isEmpty ? "Unknown" : appState.baseURL)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if !appState.username.isEmpty {
          LabeledContent("Signed in as", value: appState.username)
        }
        Button {
          showChangeServerConfirm = true
        } label: {
          Label("Change Server", systemImage: "arrow.triangle.2.circlepath")
        }
        HStack {
          Text("Default Port")
          Spacer()
          TextField("5000", value: $appState.defaultPort, format: .number)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 70, maxWidth: 120)
        }
        Toggle("Stay Signed In", isOn: $appState.rememberMe)
      } header: {
        Text("Server")
      } footer: {
        Text("DSVideoServer listens on port 5000 by default. Change this only if you've reconfigured DSVideoServer on your NAS.")
      }

      // Dual addressing. This used to sit on the first-run setup screen as "Remote address
      // (optional)", where a brand-new user had no way to know whether they needed it —
      // it is a power-user concept that only makes sense once you already have a working
      // connection to compare against. It belongs here.
      Section {
        HStack {
          Text("Home")
          Spacer()
          TextField("192.168.1.50", text: $appState.lanAddress)
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
        }
        HStack {
          Text("Away")
          Spacer()
          TextField("mynas.synology.me", text: $appState.wanAddress)
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
        }
      } header: {
        Text("Addresses")
      } footer: {
        Text("Optional. Set both and the app picks whichever works from where you are — your local address at home, your remote one everywhere else. Leave these alone if one address already works.")
      }

      // Pair Apple TV — the GENERATE half of the pairing flow.
      //
      // /auth/pairing/generate requires a bearer token; /auth/pairing/exchange does not. So a
      // signed-in phone mints the code and a signed-out Apple TV redeems it. That asymmetry
      // fixes the direction of the whole flow — it can only ever run phone → TV, never the
      // reverse, because a first-time TV has no token to generate with.
      //
      // This section is where the code comes from. TVPairingView's code field is where it
      // goes. (A PairingCodeView existed for the opposite direction — phone redeeming a
      // TV-generated code — which the token requirement makes impossible; it was unreachable
      // dead code and has been removed.)
      #if os(iOS)
      if appState.sessionToken != nil {
        Section {
          if let code = appState.pairingCode {
            VStack(alignment: .leading, spacing: 8) {
              Text(code)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .tracking(6)
                .frame(maxWidth: .infinity, alignment: .center)
                .speechSpellsOutCharacters(true)
                .privacySensitive()
                .accessibilityLabel("Pairing code: \(code.map { String($0) }.joined(separator: " "))")
              Text("Enter this code on your Apple TV.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.vertical, 4)
          }
          Button {
            Task { await appState.generatePairingCode() }
          } label: {
            if appState.isGeneratingPairingCode {
              HStack { ProgressView(); Text("Generating…") }
            } else {
              Label(appState.pairingCode == nil ? "Pair Apple TV" : "New Code",
                    systemImage: "appletv")
            }
          }
          .disabled(appState.isGeneratingPairingCode)
          if let err = appState.pairingError {
            Text(err).font(.footnote).foregroundStyle(.red)
          }
        } header: {
          Text("Apple TV")
        } footer: {
          Text("Open DSM Video on your Apple TV, then enter this code to sign it in. The code expires after a few minutes.")
        }
      }
      #endif

      Section {
        Picker("Video Quality", selection: $appState.qualityCap) {
          Text("Auto").tag("auto")
          Text("1080p").tag("1080p")
          Text("720p").tag("720p")
          Text("480p").tag("480p")
        }
      } header: {
        Text("Playback")
      } footer: {
        Text("Caps transcoded video resolution. Useful on slower connections. Direct-play streams are not affected.")
      }

      Section {
        Toggle("Download over Wi-Fi Only", isOn: $downloadsWifiOnly)
      } header: {
        Text("Downloads")
      } footer: {
        Text("When on, downloads pause on cellular and resume once you're back on Wi-Fi. Recommended to avoid large data charges.")
      }

      Section("Appearance") {
        Picker("Theme", selection: $themeIDRaw) {
          ForEach(ThemeID.allCases) { id in
            Text(id.displayName).tag(id.rawValue)
          }
        }
      }

      #if !os(tvOS)
      Section {
        VStack(alignment: .leading, spacing: 4) {
          Text("Text Size")
          Slider(value: $subtitleScale, in: 0.7...2.0, step: 0.1)
          Text(String(format: "%.0f%%", subtitleScale * 100))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Picker("Text Color", selection: $subtitleTextColor) {
          ForEach(SubtitleStyle.textColorPresets, id: \.hex) { preset in
            Text(preset.name).tag(preset.hex)
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Background")
          Slider(value: $subtitleBackgroundOpacity, in: 0...1, step: 0.1)
          Text(subtitleBackgroundOpacity < 0.05 ? "None"
               : String(format: "%.0f%% black box", subtitleBackgroundOpacity * 100))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Subtitles")
      } footer: {
        Text("Applies to the next video you play.")
      }
      #endif

      Section("Help") {
        NavigationLink {
          HowToView()
        } label: {
          Label("How To Use DSM Video", systemImage: "book")
        }
        .accessibilityLabel("How To Use DSM Video")
      }

      Section("Support") {
        Button {
          if let url = URL(string: "mailto:heiloprojects@icloud.com") {
            openURL(url)
          }
        } label: {
          Label("Contact Support", systemImage: "envelope")
        }

        // Deliberately a NavigationLink inside the Form, NOT a toolbar item: tvOS does not
        // render ToolbarItem(placement: .topBar*) at all, which is how the library search
        // control shipped invisible on the TV. A Form row is focusable and visible on both
        // platforms, and this screen exists precisely for the device that is hardest to
        // debug — it has to actually be reachable there.
        NavigationLink {
          DiagnosticLogView()
        } label: {
          Label("Diagnostic Log", systemImage: "stethoscope")
        }
        .accessibilityLabel("Diagnostic Log")
        .accessibilityHint("Recent activity, for troubleshooting sign-in and loading problems")
      }

      Section {
        HStack {
          Text("Version")
          Spacer()
          Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("About")
      }

      Section {
        Button("Logout", role: .destructive) { showLogoutConfirm = true }
      }
    }
    .navigationTitle("Settings")
    // A15: confirm before signing out.
    .confirmationDialog("Log out of \(AppInfo.displayName)?",
                        isPresented: $showLogoutConfirm, titleVisibility: .visible) {
      Button("Log Out", role: .destructive) { appState.logout() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("You'll need to sign in again to access your library.")
    }
    // A14: Change Server returns to onboarding (logout clears the saved server).
    .confirmationDialog("Change Server?",
                        isPresented: $showChangeServerConfirm, titleVisibility: .visible) {
      Button("Change Server", role: .destructive) { appState.logout() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This signs you out and returns to setup so you can connect to a different server.")
    }

    if isEmbedded {
      form
    } else {
      NavigationStack { form }
    }
  }
}

// MARK: - How To View

struct HowToView: View {
  var body: some View {
    List {

      // MARK: Server Setup
      Section {
        HowToStep(
          number: "1",
          title: "Download DSVideoServer",
          detail: "Download the latest DSVideoServer .spk package from github.com/Heilo27/DS-Reel/releases onto your Mac or PC."
        )
        HowToStep(
          number: "2",
          title: "Install on Your NAS",
          detail: "Open DSM in a browser. Go to Package Center → Manual Install, select the .spk file, and follow the prompts. You may need to allow third-party packages in Package Center settings."
        )
        HowToStep(
          number: "3",
          title: "Configure Your Video Folders",
          detail: "After installation, open DSVideoServer from the DSM desktop. Enter the paths to your Movies and TV Shows folders on the NAS, then click Save."
        )
        HowToStep(
          number: "4",
          title: "Note Your NAS Address",
          detail: "You'll need your NAS's local IP address (e.g. 192.168.1.100) or your QuickConnect ID. Both are found in DSM → Control Panel → Network or QuickConnect."
        )
      } header: {
        Label("Server Setup", systemImage: "server.rack")
          .textCase(nil)
          .font(.headline)
      }

      // MARK: Logging In
      Section {
        HowToStep(
          number: "1",
          title: "Enter Your Server Address",
          detail: "On the login screen, type your NAS's local IP address (e.g. 192.168.1.100) or your QuickConnect ID. No need to include a port — the app uses 5000 automatically."
        )
        HowToStep(
          number: "2",
          title: "Or Use the QuickConnect Lookup",
          detail: "Tap the arrow button next to the server field to look up your QuickConnect ID. The app will find your NAS on your home network or remotely."
        )
        HowToStep(
          number: "3",
          title: "Enter Your DSM Credentials",
          detail: "Use the same username and password you use to log in to your DSM. These are your NAS account credentials."
        )
        HowToStep(
          number: "4",
          title: "Tap Login",
          detail: "The app connects to DSVideoServer and loads your library. Your session is saved so you won't need to log in again unless you log out manually."
        )
      } header: {
        Label("Logging In", systemImage: "person.badge.key")
          .textCase(nil)
          .font(.headline)
      }

      // MARK: Remote Access
      Section {
        HowToStep(
          number: nil,
          title: "QuickConnect ID (Recommended)",
          detail: "Log in with your QuickConnect ID and DSM Video can reach your NAS from anywhere — no static IP or port forwarding needed."
        )
        HowToStep(
          number: nil,
          title: "Static IP or Domain",
          detail: "If you have a static external IP or a domain pointed at your NAS, enter it in the server field. Make sure port 5000 is forwarded through your router to the NAS."
        )
      } header: {
        Label("Remote Access", systemImage: "network")
          .textCase(nil)
          .font(.headline)
      }

      // MARK: Using the App
      Section {
        HowToStep(
          number: nil,
          title: "Gesture Controls",
          detail: "Tap the center of the video to play or pause; tap the left or right edge to skip back or forward 15 seconds. Swipe left or right to scrub — a full swipe covers 30 minutes. Swipe up or down to adjust volume. Double-tap to show or hide the playback controls, and use the fill/fit button in the top bar to switch between filling the screen and showing the whole frame."
        )
        HowToStep(
          number: nil,
          title: "Offline Downloads",
          detail: "Tap the download button on any video's detail page to save it for offline playback. Downloads are stored on your device and work without a connection."
        )
        HowToStep(
          number: nil,
          title: "Changing the Default Port",
          detail: "If you've reconfigured DSVideoServer to run on a different port, go to Settings → Default Port and update it. The new port applies to all future connections."
        )
      } header: {
        Label("Using the App", systemImage: "play.rectangle")
          .textCase(nil)
          .font(.headline)
      }
    }
    .navigationTitle("How To")
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
  }
}

private struct HowToStep: View {
  let number: String?
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if let number {
          Text(number + ".")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.dsAccent)
            .monospacedDigit()
        }
        Text(title)
          .font(.subheadline.weight(.semibold))
      }
      Text(detail)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
  }
}
