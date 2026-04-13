import SwiftUI

struct MainView: View {
  enum Layout {
    case tabs
    case split
  }

  @Environment(AppState.self) private var appState
  let layout: Layout

  var body: some View {
    ZStack(alignment: .top) {
      switch layout {
      case .tabs:
        TabView {
          LibraryHomeView()
            .tabItem { Label("HOME", systemImage: "play.rectangle") }

          LibrariesView()
            .tabItem { Label("LIBRARIES", systemImage: "square.grid.2x2") }

          SearchView()
            .tabItem { Label("SEARCH", systemImage: "magnifyingglass") }

          DownloadsView()
            .tabItem { Label("DOWNLOADS", systemImage: "arrow.down.circle") }

          SettingsView()
            .tabItem { Label("SETTINGS", systemImage: "gearshape") }
        }
        .tint(Color.dsAccent)
      case .split:
        SplitView()
      }

      VStack(spacing: 0) {
        OfflineBanner(isOffline: appState.isOffline, serverUnreachable: appState.serverUnreachable)
          .animation(.easeInOut(duration: 0.3), value: appState.isOffline || appState.serverUnreachable)
        Spacer()
      }
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
    case .library(let lib):
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
            Label("No libraries", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
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
    .navigationTitle("DSM Video")
    .task { await loadLibraries() }
  }

  private func loadLibraries() async {
    guard libraries.isEmpty && !isLoading else { return }
    if appState.isDemoMode {
      libraries = DemoData.libraries
      return
    }
    // Use AppState's already-populated homeLibraries to avoid a duplicate API call (TASK-256).
    if !appState.homeLibraries.isEmpty {
      libraries = appState.homeLibraries
      return
    }
    isLoading = true
    defer { isLoading = false }
    if let response = try? await appState.api.libraries() {
      libraries = response.libraries
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
          ContentUnavailableView("Search Videos", systemImage: "magnifyingglass", description: Text("Enter a title to search your library"))
            .padding(.top, 60)
        } else {
          RecentSearchesView(
            searches: recentSearches,
            onSelect: { query in
              searchText = query
              Task { await search() }
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
            Task { await search() }
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
        ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("No videos match \"\(searchText)\""))
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
            .accessibilityLabel("\(item.title)\(item.year.map { ", \($0)" } ?? ""), \(item.type)")
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
      searchTask?.cancel()
      searchTask = Task { await search() }
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
            searchTask?.cancel()
            searchTask = Task { await search() }
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

  private func search() async {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2 else { return }

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
      saveRecentSearch(query)
      return
    }

    do {
      let response = try await appState.api.search(query: query, limit: 100)
      results = response.items
      searchError = nil
      saveRecentSearch(query)
    } catch {
      appState.handleConnectionFailure(error)
      results = []
      let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
      searchError = msg
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
        url: appState.api.imageURL(id: item.posterImageId ?? item.id, width: 200),
        token: appState.sessionToken
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

  var body: some View {
    let content = Group {
      if downloads.isEmpty && inProgressIDs.isEmpty {
        ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Downloaded videos will appear here for offline viewing"))
      } else {
        ScrollView {
          VStack(spacing: 16) {
            // Storage indicator
            storageSection

            // Active and paused downloads
            if !inProgressIDs.isEmpty {
              activeDownloadsSection
            }

            // Completed downloads grid
            if !downloads.isEmpty {
              LazyVGrid(columns: columns, spacing: 12) {
                ForEach(downloads) { item in
                  Button {
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
    .onChange(of: downloadManager.activeDownloads.count) { _, _ in
      loadDownloads()
      loadStorageInfo()
    }
    .onChange(of: downloadManager.pausedDownloads.count) { _, _ in
      loadDownloads()
      loadStorageInfo()
    }
    .fullScreenCover(isPresented: $showPlayer, onDismiss: { showPlayer = false }) {
      if let item = playerItem {
        GestureVideoPlayer(
          url: URL(fileURLWithPath: item.videoPath),
          title: item.title,
          resumePosition: Double(item.resumePositionSeconds),
          onDismiss: { showPlayer = false },
          onProgressUpdate: { currentTime, _ in
            DownloadManager.shared.updateResumePosition(
              itemId: item.id,
              positionSeconds: Int(currentTime)
            )
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

        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.45),
            .init(color: .black.opacity(0.85), location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )

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
          if frac < 0.95 {
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
  var isEmbedded: Bool = false

  var body: some View {
    @Bindable var appState = appState

    let form = Form {
      Section {
        HStack {
          Text("Default Port")
          Spacer()
          TextField("8090", value: $appState.defaultPort, format: .number)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
        }
      } header: {
        Text("Server")
      } footer: {
        Text("DSVideoServer listens on port 8090 by default. Change this only if you've reconfigured DSVideoServer on your NAS.")
      }

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
        Button("Logout", role: .destructive) { appState.logout() }
      }
    }
    .navigationTitle("Settings")

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
          detail: "On the login screen, type your NAS's local IP address (e.g. 192.168.1.100) or your QuickConnect ID. No need to include a port — the app uses 8090 automatically."
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
          detail: "If you have a static external IP or a domain pointed at your NAS, enter it in the server field. Make sure port 8090 is forwarded through your router to the NAS."
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
          detail: "Swipe left or right anywhere on the video to scrub — a full swipe covers 30 minutes. Swipe up or down to adjust volume. Pinch or double-tap to toggle fill and fit."
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
