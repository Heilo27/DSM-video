import SwiftUI

struct MainView: View {
  enum Layout {
    case tabs
    case split
  }

  @Environment(AppState.self) private var appState
  let layout: Layout

  var body: some View {
    switch layout {
    case .tabs:
      TabView {
        LibraryHomeView()
          .tabItem { Label("Home", systemImage: "play.rectangle") }

        LibrariesView()
          .tabItem { Label("Libraries", systemImage: "square.grid.2x2") }

        SearchView()
          .tabItem { Label("Search", systemImage: "magnifyingglass") }

        DownloadsView()
          .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

        SettingsView()
          .tabItem { Label("Settings", systemImage: "gearshape") }
      }
    case .split:
      NavigationSplitView {
        SidebarView()
      } detail: {
        DefaultLibraryDetailView()
      }
    }
  }
}

private struct SidebarView: View {
  @Environment(AppState.self) private var appState
  @State private var libraries: [Library] = []
  @State private var isLoading = false

  private var movieLibraries: [Library] {
    libraries.filter { ["movie", "movies", "home", "homevideo"].contains($0.kind) }
  }
  private var tvLibraries: [Library] {
    libraries.filter { $0.kind == "tv" }
  }

  var body: some View {
    List {
      Section {
        NavigationLink { LibraryHomeView() } label: {
          Label("Home", systemImage: "play.rectangle")
        }
        NavigationLink { SearchView() } label: {
          Label("Search", systemImage: "magnifyingglass")
        }
        NavigationLink { DownloadsView() } label: {
          Label("Downloads", systemImage: "arrow.down.circle")
        }
      } header: {
        SidebarSectionHeader("Browse")
      }

      Section {
        if isLoading && libraries.isEmpty {
          Label("Loading…", systemImage: "hourglass")
            .foregroundStyle(.secondary)
        } else {
          ForEach(movieLibraries) { lib in
            NavigationLink {
              ItemsGridView(library: lib)
                .onAppear { UserDefaults.standard.set(lib.id, forKey: "dsReel.lastLibraryID") }
            } label: {
              Label(lib.title, systemImage: "film")
            }
          }
          ForEach(tvLibraries) { lib in
            NavigationLink {
              TVShowsView(library: lib)
                .onAppear { UserDefaults.standard.set(lib.id, forKey: "dsReel.lastLibraryID") }
            } label: {
              Label(lib.title, systemImage: "tv")
            }
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
        NavigationLink { SettingsView() } label: {
          Label("Settings", systemImage: "gearshape")
        }
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
      .font(.system(size: 18, weight: .bold, design: .rounded))
      .foregroundStyle(.primary)
      .textCase(nil)
      .padding(.top, 6)
  }
}

// MARK: - Default Detail (iPad split view)

private struct DefaultLibraryDetailView: View {
  @Environment(AppState.self) private var appState
  @State private var library: Library?
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black.ignoresSafeArea())
      } else if let lib = library {
        if lib.kind == "tv" {
          TVShowsView(library: lib)
        } else {
          ItemsGridView(library: lib)
        }
      } else {
        ContentUnavailableView(
          "Select a Library",
          systemImage: "sidebar.left",
          description: Text("Choose Movies or TV Shows from the sidebar")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
      }
    }
    .task { await loadDefault() }
  }

  private func loadDefault() async {
    if appState.isDemoMode {
      let libs = DemoData.libraries
      let savedID = UserDefaults.standard.string(forKey: "dsReel.lastLibraryID")
      library = libs.first(where: { $0.id == savedID }) ?? libs.first
      return
    }
    isLoading = true
    defer { isLoading = false }
    guard let response = try? await appState.api.libraries() else { return }
    let libs = response.libraries
    let savedID = UserDefaults.standard.string(forKey: "dsReel.lastLibraryID")
    library = libs.first(where: { $0.id == savedID }) ?? libs.first
  }
}

private struct SearchView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var searchText: String = ""
  @State private var results: [ItemSummary] = []
  @State private var isSearching: Bool = false
  @State private var hasSearched: Bool = false
  @State private var searchError: String?
  @State private var debounceTask: Task<Void, Never>?

  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        if !hasSearched {
          ContentUnavailableView("Search Videos", systemImage: "magnifyingglass", description: Text("Enter a title to search your library"))
            .padding(.top, 60)
        } else if isSearching {
          ProgressView()
            .padding(.top, 60)
        } else if let searchError {
          ContentUnavailableView("Search Failed", systemImage: "wifi.slash", description: Text(searchError))
            .padding(.top, 60)
        } else if results.isEmpty {
          ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("No videos match \"\(searchText)\""))
            .padding(.top, 60)
        } else {
          LazyVGrid(columns: columns, spacing: 12) {
            ForEach(results) { item in
              NavigationLink {
                ItemDetailView(itemID: item.id, fallbackTitle: item.title)
              } label: {
                SearchResultCell(item: item)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(horizontalSizeClass == .regular ? 20 : 12)
        }
      }
      .background(Color.black.ignoresSafeArea())
      .navigationTitle("Search")
      .searchable(text: $searchText, prompt: "Search videos")
      .onSubmit(of: .search) {
        Task { await search() }
      }
      .onChange(of: searchText) { _, newValue in
        if newValue.isEmpty {
          debounceTask?.cancel()
          results = []
          hasSearched = false
          searchError = nil
        } else if newValue.count >= 2 {
          debounceTask?.cancel()
          debounceTask = Task {
            if (try? await Task.sleep(for: .milliseconds(400))) != nil {
              await search()
            }
          }
        }
      }
    }
  }

  private func search() async {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }

    isSearching = true
    hasSearched = true
    defer { isSearching = false }

    do {
      let response = try await appState.api.search(query: query, limit: 100)
      results = response.items
      searchError = nil
    } catch {
      results = []
      let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
      searchError = msg
    }
  }
}

private struct SearchResultCell: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

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
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
  }

  @ViewBuilder
  private func posterImage(width: CGFloat, height: CGFloat) -> some View {
    if item.posterImageId != nil {
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
}

struct DownloadsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var downloads: [DownloadedItem] = []

  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
  }

  var body: some View {
    NavigationStack {
      Group {
        if downloads.isEmpty {
          ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Downloaded videos will appear here for offline viewing"))
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
              ForEach(downloads) { item in
                NavigationLink {
                  GestureVideoPlayer(
                    url: URL(fileURLWithPath: item.videoPath),
                    title: item.title,
                    resumePosition: Double(item.resumePositionSeconds),
                    onProgressUpdate: { currentTime, _ in
                      DownloadManager.shared.updateResumePosition(
                        itemId: item.id,
                        positionSeconds: Int(currentTime)
                      )
                    }
                  )
                  .navigationBarHidden(true)
                } label: {
                  DownloadedItemCell(item: item) {
                    deleteDownload(item)
                  }
                }
                .buttonStyle(.plain)
              }
            }
            .padding(horizontalSizeClass == .regular ? 20 : 12)
          }
        }
      }
      .background(Color.black.ignoresSafeArea())
      .navigationTitle("Downloads")
      .onAppear { loadDownloads() }
    }
  }

  private func loadDownloads() {
    downloads = DownloadManager.shared.getDownloadedItems()
  }

  private func deleteDownload(_ item: DownloadedItem) {
    DownloadManager.shared.deleteDownload(itemId: item.id)
    loadDownloads()
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
            .foregroundStyle(.white.opacity(0.65))
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
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
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

  var body: some View {
    @Bindable var appState = appState

    Form {
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
          title: "Install on Your Synology NAS",
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
          detail: "You'll need your NAS's local IP address (e.g. 192.168.1.100) or your Synology QuickConnect ID. Both are found in DSM → Control Panel → Network or QuickConnect."
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
          detail: "On the login screen, type your NAS's local IP address (e.g. 192.168.1.100) or your Synology QuickConnect ID. No need to include a port — the app uses 8090 automatically."
        )
        HowToStep(
          number: "2",
          title: "Or Use the QuickConnect Lookup",
          detail: "Tap the arrow button next to the server field to look up your QuickConnect ID. The app will find your NAS on your home network or remotely."
        )
        HowToStep(
          number: "3",
          title: "Enter Your DSM Credentials",
          detail: "Use the same username and password you use to log in to your Synology DSM. These are your NAS account credentials."
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
          detail: "Log in with your QuickConnect ID and DSM Video can reach your NAS from anywhere — no static IP or port forwarding needed. Synology handles the routing."
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
