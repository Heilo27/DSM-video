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
                    .foregroundStyle(Color.dsAccentOn)
                    .offset(x: 3)
                )
              Text(AppInfo.displayName)
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
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
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
                Toggle(isOn: $useHTTPS) {
                  Text("Use HTTPS")
                    .foregroundStyle(.white)
                }
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
  @State private var deepLinkItemID: String? = nil
  @State private var navPath: [String] = []

  var body: some View {
    NavigationStack(path: $navPath) {
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
                  Task { await appState.homeLoad() }
                } label: {
                  Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 48)
                    .padding(.vertical, 20)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.dsAccent)

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

              // Recently Watched rail
              if !appState.homeRecentlyWatched.isEmpty {
                TVLandscapeRail(title: "Recently Watched", items: appState.homeRecentlyWatched)
              }

              // Empty state.
              //
              // Gated on "nothing at all is on screen", NOT just on homeLibraries being empty.
              // Libraries can be present while every home rail AND every library rail is empty
              // (a configured but unscanned library, or a library whose items all failed to
              // sync). In that case the previous condition was false, so no empty state
              // rendered — and every rail above is wrapped in `if !isEmpty`, so they rendered
              // nothing either. The result on tvOS was a blank screen with NO focusable
              // element, which the focus engine cannot escape: force-quit was the only exit.
              // The Refresh button matters as much as the message — it gives focus a home.
              if !appState.homeIsLoading
                  && appState.homeContinueWatching.isEmpty
                  && appState.homeJustAdded.isEmpty
                  && appState.homeRecentlyWatched.isEmpty
                  && appState.homeLibraries.isEmpty {
                ContentUnavailableView(
                  "No Libraries",
                  systemImage: "film.stack",
                  description: Text("No video libraries were found on your NAS.")
                )
                .foregroundStyle(.white)
                .padding(.top, 40)
                Button("Refresh") { Task { await appState.homeLoad() } }
                  .buttonStyle(.borderedProminent)
                  .tint(Color.dsAccent)
              }
              // NOTE: no separate "libraries exist but are empty" branch is needed —
              // TVLibraryRail always renders a focusable NavigationLink header even when the
              // library has zero items, so focus always has a home in that case. The only
              // truly blank+unfocusable state is the one handled above.

              // Per-library rails
              ForEach(Array(appState.homeLibraries.enumerated()), id: \.element.id) { idx, lib in
                TVLibraryRail(library: lib, index: idx)
              }
            }
          }
          // Reduced from 100: the header actions now sit in a .safeAreaInset above this
          // content rather than floating over it, so the old clearance is no longer needed.
          .padding(.top, 24)
          .padding(.bottom, 80)
        }
      }
      .navigationDestination(for: String.self) { itemID in
        ItemDetailView(itemID: itemID, fallbackTitle: "")
          .environment(appState)
      }
      // Header actions live IN the content, not in a .toolbar.
      //
      // tvOS does not lay out topBarLeading/topBarTrailing items the way iOS does — it
      // renders them as free-floating pills near the top-left of the window, OUTSIDE the
      // scroll content and outside the 60pt title-safe inset. Measured on an Apple TV 4K
      // sim at 1920x1080, the Settings and Search buttons drew at x 46–283, y 60–135,
      // printing directly on top of the "Just Added" rail header (it read "ust A d" on
      // screen) and extending 14px into the left overscan band.
      //
      // This is the same defect class as the sort controls in ItemsGridView/TVShowsView and
      // the player's transport row: iOS toolbar API compiled for tvOS, laid out somewhere
      // the author never saw. A plain focusable HStack inside the scroll content is
      // positioned by us, respects title-safe, and joins the normal focus order.
      .safeAreaInset(edge: .top, spacing: 0) {
        HStack(spacing: 24) {
          Button { showSettings = true } label: {
            Image(systemName: "gear").foregroundStyle(.white)
          }
          .accessibilityLabel("Settings")

          Button { showSearch = true } label: {
            Image(systemName: "magnifyingglass").foregroundStyle(.white)
          }
          .accessibilityLabel("Search")

          Spacer()

          if !appState.isDemoMode {
            Button { showPairing = true } label: {
              if #available(tvOS 17, *) {
                Label("Pair iOS Device", systemImage: "iphone.and.arrow.right.inward")
                  .foregroundStyle(.white)
              } else {
                Label("Pair iOS Device", systemImage: "iphone.and.arrow.right")
                  .foregroundStyle(.white)
              }
            }
            .accessibilityLabel("Pair iOS Device")
          }
        }
        .padding(.horizontal, 60)   // title-safe
        .padding(.vertical, 24)
        .background(Color.black.opacity(0.95))
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
    // fullScreenCover, not sheet: on tvOS a sheet renders as a small centred card, so
    // pushing ItemDetailView from a search result confined the detail page — hero art,
    // metadata and the Play/Start Over buttons — to that card's bounds.
    .fullScreenCover(isPresented: $showSearch) {
      TVSearchView()
        .environment(appState)
    }
    .task { await appState.homeLoad() }
    .onChange(of: appState.pendingDeepLinkItemID) { _, newID in
      guard let id = newID else { return }
      navPath = [id]
      appState.pendingDeepLinkItemID = nil
    }
  }
}

// MARK: - Landscape Card Rail (Continue Watching / Just Added)

private struct TVLandscapeRail: View {
  @Environment(AppState.self) private var appState
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
            if let showId = item.showFolderId, !showId.isEmpty,
               let tvLibrary = appState.homeLibraries.first(where: {
                 item.libraryId != nil ? $0.id == item.libraryId : $0.kind == "tv" && item.libraryId == nil
               }) {
              // TV episode — navigate to the show's season/episode list,
              // highlighting the episode so the user can back out and browse,
              // or play it directly with next-episode support.
              NavigationLink {
                TVShowDetailView(
                  show: TVShow(
                    id: showId,
                    title: item.showName ?? item.title,
                    year: item.year,
                    seasonCount: nil,
                    episodeCount: nil,
                    posterImageId: item.posterImageId,
                    lastWatchedAt: nil,
                    addedAt: nil
                  ),
                  library: tvLibrary,
                  highlightEpisodeID: item.id,
                  highlightSeason: item.seasonNumber
                )
              } label: {
                TVLandscapeCard(item: item)
              }
              .buttonStyle(.card)
              .accessibilityLabel("\(item.showName ?? item.title)\(item.seasonNumber.map { ", Season \($0)" } ?? "")\(item.episodeNumber.map { ", Episode \($0)" } ?? "")")
              .accessibilityHint("Opens show to resume episode")
            } else {
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
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 12)
        .focusSection()
      }
    }
  }
}

// MARK: - Library Rail (per-library, landscape cards)

private struct TVLibraryRail: View {
  @Environment(AppState.self) private var appState
  let library: Library
  /// Rail index — used to stagger concurrent home-load fetches by 150ms per rail (TASK-432).
  var index: Int = 0

  @State private var items: [ItemSummary] = []
  @State private var shows: [TVShow] = []
  @State private var isLoading: Bool = false
  @State private var error: String?

  private var isTVLibrary: Bool { library.kind == "tv" }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      // Library header — navigates to full grid
      NavigationLink {
        if isTVLibrary {
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
      }
      .buttonStyle(.plain)
      // Title-safe padding goes OUTSIDE the Button, not inside its label. With it inside,
      // the button's own frame started at x=0 and tvOS drew the focus highlight around
      // that frame — 14px into the left overscan band, where a real TV clips it. Padding
      // the button itself keeps the highlight inside title-safe too.
      .padding(.horizontal, 60)
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
          if isTVLibrary {
            ForEach(shows.prefix(20)) { show in
              TVShowNavCard(show: show, library: library)
            }
          } else {
            ForEach(items.prefix(20)) { item in
              TVItemNavCard(item: item)
            }
          }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 12)
        .focusSection()
      }
    }
    // TASK-432: stagger per-rail fetches to avoid N concurrent requests on home load.
    // TASK-442: re-trigger fetch when homeForceRefresh bumps libraryRailsVersion.
    .task(id: appState.libraryRailsVersion) { await load() }
  }

  private func load() async {
    // TASK-432: stagger fetches based on rail index to spread concurrent network load.
    if index > 0 {
      try? await Task.sleep(for: .milliseconds(index * 150))
      guard !Task.isCancelled else { return }
    }
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    if appState.isDemoMode {
      if isTVLibrary {
        shows = DemoData.tvShows
      } else {
        items = DemoData.items(for: library)
      }
      return
    }

    do {
      if isTVLibrary {
        let response = try await appState.api.tvShows(libraryId: library.id)
        var seen = Set<String>()
        shows = response.shows.filter { seen.insert($0.id).inserted }
      } else {
        let cached = await LocalStore.shared.fetchItems(forLibraryId: library.id, limit: 50)
        if !cached.isEmpty {
          items = cached
          error = nil
          return
        }
        items = try await appState.api.items(libraryId: library.id, limit: 50, offset: 0).items
      }
      error = nil
    } catch is CancellationError {
      // View disappeared — discard, don't set error
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Couldn't load"
    }
  }
}

// Portrait card for a TVShow in the home rail
private struct TVShowNavCard: View {
  let show: TVShow
  let library: Library

  var body: some View {
    NavigationLink {
      TVShowDetailView(show: show, library: library)
    } label: {
      TVShowPortraitCard(show: show)
    }
    .buttonStyle(.card)
    .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")")
    .accessibilityHint("Opens show details")
  }
}

private struct TVItemNavCard: View {
  let item: ItemSummary

  var body: some View {
    NavigationLink {
      ItemDetailView(itemID: item.id, fallbackTitle: item.title)
    } label: {
      TVPortraitCard(item: item)
    }
    .buttonStyle(.card)
    .accessibilityLabel("\(item.title)\(item.year.map { ", \($0)" } ?? "")")
    .accessibilityHint("Opens video details")
  }
}

private struct TVShowPortraitCard: View {
  @Environment(AppState.self) private var appState
  let show: TVShow

  private let cardWidth: CGFloat = 220
  private let cardHeight: CGFloat = 330

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(white: 0.1))
          .frame(width: cardWidth, height: cardHeight)

        if let posterID = show.posterImageId {
          AuthenticatedImage(
            url: appState.api.imageURL(id: posterID, width: 440, version: show.metadataVersion),
            token: appState.sessionToken,
            usesTunnelCookie: appState.api.usesTunnelCookie
          )
          .scaledToFill()
          .frame(width: cardWidth, height: cardHeight, alignment: .top)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(white: 0.08))
            .frame(width: cardWidth, height: cardHeight)
            .overlay(
              Image(systemName: "tv.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.25))
                .accessibilityHidden(true)
            )
        }

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
      }
      .frame(width: cardWidth, height: cardHeight)

      VStack(alignment: .leading, spacing: 2) {
        Text(show.title)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.white)
          .lineLimit(2)
          .frame(width: cardWidth, alignment: .leading)

        if let year = show.year {
          Text(String(year))
            .font(.system(size: 15))
            .foregroundStyle(Color.dsTextSecondary)
        }
      }
      .padding(.leading, 10)
    }
    .privacySensitive()  // TASK-693/698: redact in app switcher / recordings
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
          .frame(width: cardWidth, height: cardHeight, alignment: .center)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let assetName = DemoData.posterAssetNames[item.id],
                  let img = UIImage(named: assetName) {
          Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: cardWidth, height: cardHeight, alignment: .center)
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
          // TASK-802: allow a second line + slight scale so long titles don't silently truncate.
          .lineLimit(2)
          .minimumScaleFactor(0.85)
          .frame(width: cardWidth, alignment: .leading)

        if let year = item.year {
          Text(String(year))
            .font(.system(size: 15))
            .foregroundStyle(Color.dsTextSecondary)
        }
      }
      .padding(.leading, 10)
    }
    .privacySensitive()  // TASK-693/698: redact in app switcher / recordings
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
          .frame(width: cardWidth, height: cardHeight, alignment: .top)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let assetName = DemoData.posterAssetNames[item.id],
                  let img = UIImage(named: assetName) {
          Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: cardWidth, height: cardHeight, alignment: .top)
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
          if frac >= PlaybackProgress.watchedThreshold {
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
    .privacySensitive()  // TASK-693/698: redact in app switcher / recordings
  }
}

// MARK: - Settings

private struct TVSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  // TASK-746: playback + subtitle prefs, shared keys with the iOS SettingsView so a
  // setting changed on either platform applies on both. Slider is unavailable on
  // tvOS, so subtitle size/background use Pickers over discrete steps.
  @AppStorage("dsReel.subtitleScale") private var subtitleScale: Double = 1.0
  @AppStorage("dsReel.subtitleTextColor") private var subtitleTextColor: String = "#FFFFFF"
  @AppStorage("dsReel.subtitleBackgroundOpacity") private var subtitleBackgroundOpacity: Double = 0.0
  // Theme selection (Classic / Nitrate). Shared key with the app entry and iOS Settings.
  @AppStorage("dsReel.theme") private var themeIDRaw: String = ThemeID.classic.rawValue

  var body: some View {
    NavigationStack {
      Form {
        Section("Appearance") {
          Picker("Theme", selection: $themeIDRaw) {
            ForEach(ThemeID.allCases) { id in
              Text(id.displayName).tag(id.rawValue)
            }
          }
        }

        Section("Playback") {
          Picker("Video Quality", selection: Binding(
            get: { appState.qualityCap },
            set: { appState.qualityCap = $0 }
          )) {
            Text("Auto").tag("auto")
            Text("1080p").tag("1080p")
            Text("720p").tag("720p")
            Text("480p").tag("480p")
          }
        }

        Section("Subtitles") {
          Picker("Text Size", selection: $subtitleScale) {
            Text("Small").tag(0.8)
            Text("Default").tag(1.0)
            Text("Large").tag(1.3)
            Text("Extra Large").tag(1.6)
          }
          Picker("Text Color", selection: $subtitleTextColor) {
            ForEach(SubtitleStyle.textColorPresets, id: \.hex) { preset in
              Text(preset.name).tag(preset.hex)
            }
          }
          Picker("Background", selection: $subtitleBackgroundOpacity) {
            Text("None").tag(0.0)
            Text("Light").tag(0.4)
            Text("Medium").tag(0.7)
            Text("Solid").tag(1.0)
          }
        }

        Section("Server") {
          LabeledContent("Connected To", value: appState.baseURL.isEmpty ? "Unknown" : appState.baseURL)
          LabeledContent("Signed in as", value: appState.username)
        }

        Section {
          Button(role: .destructive) {
            appState.logout()
            dismiss()
          } label: {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
          }
          .accessibilityHint("Select to sign out of your account")
        }
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
  @FocusState private var searchFieldFocused: Bool

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()

        VStack(alignment: .leading, spacing: 40) {
          // Prominent search field — full-width, large text, auto-focuses keyboard
          TextField("Search movies and TV shows…", text: $searchText)
            .font(.system(size: 36, weight: .regular))
            .foregroundStyle(.white)
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 60)
            .focused($searchFieldFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit {
              debounceTask?.cancel()
              debounceTask = Task { await search() }
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
                  do {
                    try await Task.sleep(for: .milliseconds(600))
                    await search()
                  } catch { /* debounce cancelled */ }
                }
              }
            }
            .accessibilityLabel("Search field")

          // Results area
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
              // TASK-801: give the empty-results region a focusable action so focus
              // has a home here (not only the search field / toolbar).
              VStack(spacing: 24) {
                ContentUnavailableView(
                  "No Results",
                  systemImage: "magnifyingglass",
                  description: Text("No videos match \"\(searchText)\"")
                )
                .foregroundStyle(.white)

                Button("Clear Search") {
                  searchText = ""
                  searchFieldFocused = true
                }
                .buttonStyle(.bordered)
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if !results.isEmpty {
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                  ForEach(results) { item in
                    NavigationLink {
                      // TASK-685/700: TV episodes open the show page (with the episode's
                      // season highlighted) so the user can browse seasons; movies open
                      // the item detail directly.
                      if let showId = item.showFolderId ?? item.showName,
                         !showId.isEmpty, let tvLibrary = appState.homeFirstTVLibrary {
                        TVShowDetailView(
                          show: TVShow(
                            id: showId, title: item.showName ?? showId, year: item.year,
                            seasonCount: nil, episodeCount: nil,
                            posterImageId: item.posterImageId,
                            lastWatchedAt: nil, addedAt: nil
                          ),
                          library: tvLibrary,
                          highlightEpisodeID: item.id,
                          highlightSeason: item.seasonNumber
                        )
                      } else {
                        ItemDetailView(itemID: item.id, fallbackTitle: item.title)
                      }
                    } label: {
                      HStack(spacing: 16) {
                        if let posterID = item.posterImageId {
                          AuthenticatedImage(
                            url: appState.api.imageURL(id: posterID, width: 120),
                            token: appState.sessionToken,
                            usesTunnelCookie: appState.api.usesTunnelCookie
                          )
                          .scaledToFill()
                          .frame(width: 60, height: 90, alignment: .top)
                          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                          RoundedRectangle(cornerRadius: 6)
                            .fill(Color(white: 0.15))
                            .frame(width: 60, height: 90)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                          Text(item.title)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                          if let year = item.year {
                            Text(String(year))
                              .font(.system(size: 20))
                              .foregroundStyle(Color.dsTextSecondary)
                          }
                        }
                        Spacer()
                      }
                      .padding(.vertical, 16)
                      .padding(.horizontal, 60)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title + (item.year.map { ", \($0)" } ?? ""))
                    .accessibilityHint("Opens video details")
                    Divider().background(Color(white: 0.2)).padding(.horizontal, 60)
                  }
                }
                .focusSection()
                .privacySensitive()  // TASK-693/698: redact search results (titles + posters)
              }
            } else {
              VStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                  .font(.system(size: 60))
                  .foregroundStyle(Color.dsTextMuted)
                Text("Search Your Library")
                  .font(.system(size: 28, weight: .semibold))
                  .foregroundStyle(.white)
                Text("Enter a title to find movies and TV shows")
                  .font(.system(size: 20))
                  .foregroundStyle(Color.dsTextSecondary)
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 60)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .onAppear { searchFieldFocused = true }
      .onDisappear { debounceTask?.cancel() }
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
