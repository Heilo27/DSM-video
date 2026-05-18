import SwiftUI

#if os(tvOS)

// MARK: - Root

struct TVMainView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    Group {
      if appState.sessionToken == nil {
        TVPairingView()
      } else {
        TVHomeView()
      }
    }
  }
}

// MARK: - Login

struct TVLoginView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  // Local state avoids @Bindable-in-body instability on tvOS focus engine
  @State private var server: String = ""
  @State private var username: String = ""
  @State private var password: String = ""
  @State private var useHTTPS: Bool = false

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        RadialGradient(
          colors: [Color(white: 0.08), Color.black],
          center: .center,
          startRadius: 100,
          endRadius: 900
        )
        .ignoresSafeArea()

        HStack(spacing: 0) {
          // Left: Brand panel
          VStack(alignment: .leading, spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.dsAccent)
                .frame(width: 72, height: 72)
                .overlay(
                  Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 3)
                )
              Text("DSM Video")
                .font(.system(size: 72, weight: .bold))
                .foregroundStyle(.white)
                .tracking(-1)
              Text("Your home video library.\nOn your TV.")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.dsTextSecondary)
                .lineSpacing(4)
            }
            Spacer()
          }
          .frame(maxWidth: .infinity)
          .padding(.leading, 120)
          .accessibilityHidden(true)

          // Right: Sign-in form
          VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 32) {
              Text("Sign In")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)

              VStack(spacing: 16) {
                TextField("Server Address", text: $server)
                  .frame(maxWidth: 480)
                Text("Enter your NAS IP address or QuickConnect ID")
                  .font(.system(size: 14))
                  .foregroundStyle(Color.dsTextMuted)
                  .frame(maxWidth: 480, alignment: .leading)
                TextField("Username", text: $username)
                  .textContentType(.username)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .frame(maxWidth: 480)
                SecureField("Password", text: $password)
                  .textContentType(.password)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .frame(maxWidth: 480)
                Toggle("Use HTTPS", isOn: $useHTTPS)
                  .frame(maxWidth: 480)
                  .tint(Color.dsAccent)
              }

              if let error = appState.loginError {
                Text(error)
                  .font(.callout)
                  .foregroundStyle(Color.dsError)
                  .multilineTextAlignment(.leading)
                  .frame(maxWidth: 480, alignment: .leading)
              }

              Button {
                appState.useHTTPS = useHTTPS
                appState.baseURL = server
                appState.username = username
                appState.savedPassword = password
                Task { await appState.login() }
              } label: {
                if appState.isLoggingIn {
                  ProgressView().tint(.white).frame(maxWidth: 480)
                } else {
                  Text("Sign In").font(.system(size: 19, weight: .semibold)).frame(maxWidth: 480)
                }
              }
              .buttonStyle(.borderedProminent)
              .tint(Color.dsAccent)
              .accessibilityLabel(appState.isLoggingIn ? "Signing in, please wait" : "Sign In")
              .disabled(appState.isLoggingIn || username.isEmpty || (server.isEmpty && username.trimmingCharacters(in: .whitespaces).lowercased() != "appledemo"))
            }
            Spacer()
          }
          .frame(maxWidth: 560)
          .padding(.trailing, 120)
        }
      }
      .onAppear {
        server = appState.baseURL
        username = appState.username
        password = appState.savedPassword
        useHTTPS = appState.useHTTPS
      }
      .onChange(of: appState.sessionToken) { _, token in
        if token != nil { dismiss() }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Back") { dismiss() }
        }
      }
    }
  }
}

// MARK: - Home


private struct TVHomeView: View {
  @Environment(AppState.self) private var appState
  @State private var showPairing: Bool = false
  @State private var showSettings: Bool = false
  @State private var showSearch: Bool = false

  var body: some View {
    NavigationStack {
      ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()

        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 56) {
            if let loadError = appState.homeError, appState.homeAllRailsEmpty {
              VStack(spacing: 32) {
                ContentUnavailableView(
                  "Unable to Load",
                  systemImage: "exclamationmark.triangle",
                  description: Text(loadError)
                )
                .foregroundStyle(.white)

                Button {
                  appState.logout()
                } label: {
                  Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 48)
                    .padding(.vertical, 20)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(white: 0.2))
              }
              .padding(.top, 60)
            } else {
              // Continue Watching rail
              if !appState.homeContinueWatching.isEmpty {
                TVLandscapeRail(title: "Continue Watching", items: appState.homeContinueWatching)
              }

              // Just Added rail
              if !appState.homeJustAdded.isEmpty {
                TVLandscapeRail(title: "Just Added", items: appState.homeJustAdded)
              }

              // Empty state
              if appState.homeLibraries.isEmpty && !appState.homeIsLoading {
                ContentUnavailableView(
                  "No Libraries",
                  systemImage: "film.stack",
                  description: Text("No video libraries were found on your NAS.")
                )
                .foregroundStyle(.white)
                .padding(.top, 40)
              }

              // Per-library rails
              ForEach(appState.homeLibraries) { lib in
                TVLibraryRail(library: lib)
              }
            }
          }
          .padding(.top, 60)
          .padding(.bottom, 80)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            showSettings = true
          } label: {
            Image(systemName: "gear")
              .foregroundStyle(.white)
          }
          .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .topBarLeading) {
          Button {
            showSearch = true
          } label: {
            Image(systemName: "magnifyingglass")
              .foregroundStyle(.white)
          }
          .accessibilityLabel("Search")
        }
        if !appState.isDemoMode {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              showPairing = true
            } label: {
              // iphone.and.arrow.right.inward is tvOS 17+; fall back for older tvOS (TASK-446).
              if #available(tvOS 17, *) {
                Label("Pair iOS Device", systemImage: "iphone.and.arrow.right.inward")
                  .foregroundStyle(.white)
              } else {
                Label("Pair iOS Device", systemImage: "iphone.and.arrow.right")
                  .foregroundStyle(.white)
              }
            }
          }
        }
      }
    }
    .sheet(isPresented: $showSettings) {
      TVSettingsView()
        .environment(appState)
    }
    .sheet(isPresented: $showPairing) {
      TVPairingView()
        .environment(appState)
    }
    .sheet(isPresented: $showSearch) {
      TVSearchView()
        .environment(appState)
    }
    .task { await appState.homeLoad() }
  }
}

// MARK: - Landscape Card Rail (Continue Watching / Just Added)

private struct TVLandscapeRail: View {
  let title: String
  let items: [ItemSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(title)
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 60)
        .accessibilityAddTraits(.isHeader)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 28) {
          ForEach(items) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              TVLandscapeCard(item: item)
            }
            .buttonStyle(.card)
            .accessibilityLabel("\(item.title)\(item.year.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens video details")
          }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 12)
      }
    }
  }
}

// MARK: - Library Rail (per-library, landscape cards)

private struct TVLibraryRail: View {
  @Environment(AppState.self) private var appState
  let library: Library

  @State private var items: [ItemSummary] = []
  @State private var isLoading: Bool = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      // Library header — navigates to full grid
      NavigationLink {
        if library.kind == "tv" {
          TVShowsView(library: library)
        } else {
          ItemsGridView(library: library)
        }
      } label: {
        HStack(spacing: 10) {
          Text(library.title)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.white)
          Image(systemName: "chevron.right")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.dsTextSecondary)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 60)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(library.title)
      .accessibilityHint("Opens full library")

      if let error {
        Text(error)
          .font(.footnote)
          .foregroundStyle(Color.dsTextMuted)
          .padding(.horizontal, 60)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 28) {
          ForEach(items.prefix(20)) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              // TV library uses portrait cards for movie/show posters
              TVPortraitCard(item: item)
            }
            .buttonStyle(.card)
            .accessibilityLabel("\(item.title)\(item.year.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens video details")
          }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 12)
      }
    }
    .task { await load() }
  }

  private func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    // Demo mode — serve static data directly; no API calls during App Review.
    if appState.isDemoMode {
      items = DemoData.items(for: library)
      return
    }

    // Prefer LocalStore (already populated by delta sync) to avoid a redundant
    // network call on every TVHomeView appear (TASK-415).
    let cached = await LocalStore.shared.fetchItems(forLibraryId: library.id, limit: 50)
    if !cached.isEmpty {
      items = cached
      return
    }

    // LocalStore empty (first launch before sync completes) — fall back to API.
    do {
      items = try await appState.api.items(libraryId: library.id, limit: 50, offset: 0).items
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Couldn't load"
    }
  }
}

// MARK: - Landscape Card (16:9, for Continue Watching / Just Added)

private struct TVLandscapeCard: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

  // 16:9 landscape at TV-appropriate size
  private let cardWidth: CGFloat = 380
  private let cardHeight: CGFloat = 214

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .bottom) {
        // Backdrop/poster image
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(white: 0.1))
          .frame(width: cardWidth, height: cardHeight)

        if let imageID = item.backdropImageId ?? item.posterImageId {
          AuthenticatedImage(
            url: appState.api.imageURL(id: imageID, width: 760),
            token: appState.sessionToken,
            usesTunnelCookie: appState.api.usesTunnelCookie
          )
          .scaledToFill()
          .frame(width: cardWidth, height: cardHeight)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let assetName = DemoData.posterAssetNames[item.id],
                  let img = UIImage(named: assetName) {
          Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(white: 0.1))
            .frame(width: cardWidth, height: cardHeight)
            .overlay(
              Image(systemName: "play.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityHidden(true)
            )
        }

        // Bottom gradient
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.4),
            .init(color: .black.opacity(0.75), location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: cardWidth, height: cardHeight)

        // Progress bar at bottom edge
        if let progress = item.progress, progress.durationSeconds > 0 {
          let frac = min(1.0, Double(progress.positionSeconds) / Double(progress.durationSeconds))
          if frac < 1.0 {
            VStack(spacing: 0) {
              Spacer()
              GeometryReader { geo in
                ZStack(alignment: .leading) {
                  Rectangle()
                    .fill(Color(white: 0.3))
                    .frame(height: 4)
                  Rectangle()
                    .fill(Color.dsAccent)
                    .frame(width: geo.size.width * frac, height: 4)
                }
              }
              .frame(height: 4)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
          }
        }
      }
      .frame(width: cardWidth, height: cardHeight)

      // Title + year below card
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.white)
          .lineLimit(1)
          .frame(width: cardWidth, alignment: .leading)

        if let year = item.year {
          Text(String(year))
            .font(.system(size: 15))
            .foregroundStyle(Color.dsTextSecondary)
        }
      }
      .padding(.leading, 10)
    }
  }
}

// MARK: - Portrait Card (2:3, for library rails and grid)

private struct TVPortraitCard: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

  private let cardWidth: CGFloat = 220
  private let cardHeight: CGFloat = 330  // 2:3

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(white: 0.1))
          .frame(width: cardWidth, height: cardHeight)

        if let posterID = item.posterImageId {
          AuthenticatedImage(
            url: appState.api.imageURL(id: posterID, width: 440),
            token: appState.sessionToken,
            usesTunnelCookie: appState.api.usesTunnelCookie
          )
          .scaledToFill()
          .frame(width: cardWidth, height: cardHeight)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let assetName = DemoData.posterAssetNames[item.id],
                  let img = UIImage(named: assetName) {
          Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(white: 0.08))
            .frame(width: cardWidth, height: cardHeight)
            .overlay(
              Image(systemName: "film.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.25))
                .accessibilityHidden(true)
            )
        }

        // Gradient + progress
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.5),
            .init(color: .black.opacity(0.7), location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: cardWidth, height: cardHeight)

        // Progress bar
        if let progress = item.progress, progress.durationSeconds > 0 {
          let frac = min(1.0, Double(progress.positionSeconds) / Double(progress.durationSeconds))
          if frac < 1.0 {
            VStack(spacing: 0) {
              Spacer()
              GeometryReader { geo in
                ZStack(alignment: .leading) {
                  Rectangle().fill(Color(white: 0.3)).frame(height: 4)
                  Rectangle().fill(Color.dsAccent).frame(width: geo.size.width * frac, height: 4)
                }
              }
              .frame(height: 4)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
          }
        }

        // Watched badge
        if let progress = item.progress, progress.durationSeconds > 0 {
          let frac = min(1.0, Double(progress.positionSeconds) / Double(progress.durationSeconds))
          if frac >= 0.95 {
            VStack {
              HStack {
                Spacer()
                Circle()
                  .fill(Color.dsSuccess)
                  .frame(width: 28, height: 28)
                  .overlay(
                    Image(systemName: "checkmark")
                      .font(.system(size: 13, weight: .bold))
                      .foregroundStyle(.black)
                  )
                  .padding(8)
              }
              Spacer()
            }
            .frame(width: cardWidth, height: cardHeight)
            .accessibilityHidden(true)
          }
        }
      }
      .frame(width: cardWidth, height: cardHeight)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.white)
          .lineLimit(2)
          .frame(width: cardWidth, alignment: .leading)

        if let year = item.year {
          Text(String(year))
            .font(.system(size: 15))
            .foregroundStyle(Color.dsTextSecondary)
        }
      }
      .padding(.leading, 10)
    }
  }
}

// MARK: - Settings

private struct TVSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 32) {
          // Server info
          VStack(alignment: .leading, spacing: 8) {
            Text("Connected Server")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(Color.dsTextSecondary)
            Text(appState.baseURL.isEmpty ? "Unknown" : appState.baseURL)
              .font(.system(size: 24, weight: .medium))
              .foregroundStyle(.white)
            Text("Signed in as \(appState.username)")
              .font(.system(size: 18))
              .foregroundStyle(Color.dsTextSecondary)
          }

          Divider().background(Color(white: 0.2))

          // Logout button
          Button {
            appState.logout()
            dismiss()
          } label: {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: 400, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .tint(.white)
          .accessibilityHint("Select to sign out of your account")

          Spacer()
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .navigationTitle("Settings")
    }
  }
}

// MARK: - Search

private struct TVSearchView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var searchText: String = ""
  @State private var results: [ItemSummary] = []
  @State private var isSearching: Bool = false
  @State private var hasSearched: Bool = false
  @State private var searchError: String?
  @State private var debounceTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Group {
        if isSearching {
          ProgressView("Searching…")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if let err = searchError {
          Text(err)
            .font(.callout)
            .foregroundStyle(Color.dsError)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if hasSearched && results.isEmpty {
          ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No videos match \"\(searchText)\"")
          )
          .foregroundStyle(.white)
        } else if !results.isEmpty {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(results) { item in
                NavigationLink {
                  ItemDetailView(itemID: item.id, fallbackTitle: item.title)
                } label: {
                  HStack(spacing: 16) {
                    if let posterID = item.posterImageId {
                      AuthenticatedImage(
                        url: appState.api.imageURL(id: posterID, width: 120),
                        token: appState.sessionToken,
                        usesTunnelCookie: appState.api.usesTunnelCookie
                      )
                      .scaledToFill()
                      .frame(width: 60, height: 90)
                      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                      RoundedRectangle(cornerRadius: 6)
                        .fill(Color(white: 0.15))
                        .frame(width: 60, height: 90)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                      Text(item.title)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                      if let year = item.year {
                        Text(String(year))
                          .font(.system(size: 16))
                          .foregroundStyle(Color.dsTextSecondary)
                      }
                    }
                    Spacer()
                  }
                  .padding(.vertical, 12)
                  .padding(.horizontal, 60)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title + (item.year.map { ", \($0)" } ?? ""))
                .accessibilityHint("Opens video details")
                Divider().background(Color(white: 0.2)).padding(.horizontal, 60)
              }
            }
          }
        } else {
          ContentUnavailableView(
            "Search Your Library",
            systemImage: "magnifyingglass",
            description: Text("Enter a title to find movies and TV shows")
          )
          .foregroundStyle(.white)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.ignoresSafeArea())
      .navigationTitle("Search")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .searchable(text: $searchText, prompt: "Search your library")
      .onChange(of: searchText) { _, newValue in
        if newValue.isEmpty {
          debounceTask?.cancel()
          results = []
          hasSearched = false
          searchError = nil
        } else if newValue.count >= 2 {
          debounceTask?.cancel()
          debounceTask = Task {
            do {
              try await Task.sleep(for: .milliseconds(500))
              await search()
            } catch { }
          }
        }
      }
      .onSubmit(of: .search) {
        debounceTask?.cancel()
        debounceTask = Task { await search() }
      }
      .onDisappear {
        debounceTask?.cancel()
      }
    }
  }

  private func search() async {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2 else { return }

    isSearching = true
    hasSearched = true
    defer { isSearching = false }

    guard !appState.isDemoMode else {
      let allDemoItems = DemoData.movieItems + DemoData.tvItems
      results = allDemoItems.filter { $0.title.localizedCaseInsensitiveContains(query) }
      searchError = nil
      return
    }

    do {
      let response = try await appState.api.search(query: query, limit: 100)
      results = response.items
      searchError = nil
    } catch {
      results = []
      searchError = (error as? APIError)?.userMessage ?? error.localizedDescription
    }

    if !results.isEmpty {
      AccessibilityNotification.Announcement("\(results.count) results found").post()
    } else if hasSearched {
      AccessibilityNotification.Announcement("No results found").post()
    }
  }
}

#Preview {
  TVMainView()
    .environment(AppState())
}

#endif
