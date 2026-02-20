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
        LibrariesView()
      }
    }
  }
}

private struct SidebarView: View {
  var body: some View {
    List {
      Section("Browse") {
        NavigationLink("Libraries") { LibrariesView() }
        NavigationLink("Search") { SearchView() }
        NavigationLink("Downloads") { DownloadsView() }
      }
      Section("Settings") {
        NavigationLink("Settings") { SettingsView() }
      }
    }
    .navigationTitle("DS Reel")
  }
}

private struct SearchView: View {
  @Environment(AppState.self) private var appState
  @State private var searchText: String = ""
  @State private var results: [ItemSummary] = []
  @State private var isSearching: Bool = false
  @State private var hasSearched: Bool = false

  private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

  var body: some View {
    NavigationStack {
      ScrollView {
        if !hasSearched {
          ContentUnavailableView("Search Videos", systemImage: "magnifyingglass", description: Text("Enter a title to search your library"))
            .padding(.top, 60)
        } else if isSearching {
          ProgressView()
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
          .padding(12)
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
          results = []
          hasSearched = false
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
    } catch {
      results = []
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

private struct DownloadsView: View {
  @Environment(AppState.self) private var appState
  @State private var downloads: [DownloadedItem] = []

  private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

  var body: some View {
    NavigationStack {
      Group {
        if downloads.isEmpty {
          ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Downloaded videos will appear here for offline viewing"))
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
              ForEach(downloads) { item in
                DownloadedItemCell(item: item) {
                  deleteDownload(item)
                }
              }
            }
            .padding(12)
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
        Image(uiImage: image)
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

  private func loadLocalImage(from path: String) -> UIImage? {
    UIImage(contentsOfFile: path)
  }

  private func formatFileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

private struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.openURL) private var openURL

  var body: some View {
    @Bindable var appState = appState

    Form {
      Section("Server") {
        Text(appState.baseURL)
        Toggle("HTTPS", isOn: $appState.useHTTPS)
      }

      Section {
        SecureField("API Key", text: $appState.tmdbAPIKey)
          .textContentType(.password)
          .autocorrectionDisabled()
          #if os(iOS)
          .textInputAutocapitalization(.never)
          #endif

        if appState.tmdbAPIKey.isEmpty {
          Label("Movie details and posters require a TMDb API key", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Label("API key configured", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        }
      } header: {
        Text("TMDb Metadata")
      } footer: {
        VStack(alignment: .leading, spacing: 8) {
          Text("Get movie details, posters, and cast information from The Movie Database (TMDb).")

          Text("The TMDb API is free for non-commercial, personal use. To get your API key:")
            .fontWeight(.medium)

          VStack(alignment: .leading, spacing: 4) {
            Text("1. Create an account at themoviedb.org")
            Text("2. Go to Settings > API")
            Text("3. Request an API key (Developer)")
            Text("4. Copy the \"API Read Access Token\"")
          }
          .font(.caption2)

          Button("Open TMDb Website") {
            if let url = URL(string: "https://www.themoviedb.org/settings/api") {
              openURL(url)
            }
          }
          .font(.caption)
          .padding(.top, 4)
        }
      }

      Section {
        Button("Logout", role: .destructive) { appState.logout() }
      }
    }
    .navigationTitle("Settings")
  }
}

