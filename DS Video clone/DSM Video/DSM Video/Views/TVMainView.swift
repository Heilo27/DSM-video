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
              Text("Your Synology NAS.\nOn your TV.")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.dsTextSecondary)
                .lineSpacing(4)
            }
            Spacer()
          }
          .frame(maxWidth: .infinity)
          .padding(.leading, 120)

          // Right: Sign-in form
          VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 32) {
              Text("Sign In")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)

              VStack(spacing: 16) {
                TextField("Server Address", text: $server)
                  .frame(maxWidth: 480)
                Text("Enter your NAS IP address or QuickConnect ID")
                  .font(.system(size: 14))
                  .foregroundStyle(Color.dsTextMuted)
                  .frame(maxWidth: 480, alignment: .leading)
                TextField("Username", text: $username)
                  .textContentType(.username)
                  .frame(maxWidth: 480)
                SecureField("Password", text: $password)
                  .textContentType(.password)
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
              .disabled(appState.isLoggingIn || server.isEmpty || username.isEmpty)
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
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Back") { dismiss() }
        }
      }
    }
  }
}

// MARK: - Home

private let _tvHomeDateFormatterFractional: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()

private let _tvHomeDateFormatter: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime]
  return f
}()

private func parseTVHomeDate(_ iso: String) -> Date {
  if let d = _tvHomeDateFormatterFractional.date(from: iso) { return d }
  return _tvHomeDateFormatter.date(from: iso) ?? Date.distantPast
}

private struct TVHomeView: View {
  @Environment(AppState.self) private var appState
  @State private var libraries: [Library] = []
  @State private var continueWatching: [ItemSummary] = []
  @State private var justAdded: [ItemSummary] = []
  @State private var isLoading: Bool = false
  @State private var loadError: String?
  @State private var showPairing: Bool = false
  @State private var showSettings: Bool = false

  var body: some View {
    NavigationStack {
      ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()

        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 56) {
            if let loadError {
              ContentUnavailableView(
                "Unable to Load",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
              )
              .foregroundStyle(.white)
              .padding(.top, 60)
            } else {
              // Continue Watching rail
              if !continueWatching.isEmpty {
                TVLandscapeRail(title: "Continue Watching", items: continueWatching)
              }

              // Just Added rail
              if !justAdded.isEmpty {
                TVLandscapeRail(title: "Just Added", items: justAdded)
              }

              // Empty state
              if libraries.isEmpty && !isLoading {
                ContentUnavailableView(
                  "No Libraries",
                  systemImage: "film.stack",
                  description: Text("No video libraries were found on your NAS.")
                )
                .foregroundStyle(.white)
                .padding(.top, 40)
              }

              // Per-library rails
              ForEach(libraries) { lib in
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
            Label("Settings", systemImage: "gear")
              .foregroundStyle(.white)
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showPairing = true
          } label: {
            Label("Pair iOS Device", systemImage: "iphone.and.arrow.right.inward")
              .foregroundStyle(.white)
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
    .task { await load() }
  }

  private func load() async {
    guard !isLoading else { return }
    loadError = nil
    isLoading = true
    defer { isLoading = false }

    do {
      libraries = try await appState.api.libraries().libraries

      let api = appState.api
      var allItems: [ItemSummary] = []
      await withTaskGroup(of: [ItemSummary].self) { group in
        for lib in libraries {
          group.addTask {
            (try? await api.items(libraryId: lib.id, limit: 20, offset: 0).items) ?? []
          }
        }
        for await items in group {
          allItems.append(contentsOf: items)
        }
      }

      continueWatching = allItems
        .filter { item in
          guard let progress = item.progress, progress.durationSeconds > 0 else { return false }
          let frac = Double(progress.positionSeconds) / Double(progress.durationSeconds)
          return frac > 0 && frac < 0.95
        }
        .sorted { ($0.progress?.updatedAt ?? "") > ($1.progress?.updatedAt ?? "") }

      justAdded = Array(
        allItems
          .sorted { lhs, rhs in
            let l = parseTVHomeDate(lhs.addedAt)
            let r = parseTVHomeDate(rhs.addedAt)
            if l != Date.distantPast || r != Date.distantPast { return l > r }
            return lhs.addedAt > rhs.addedAt
          }
          .prefix(20)
      )
    } catch {
      loadError =
        (error as? APIError)?.userMessage
        ?? "Failed to load content. Check your connection and try again."
    }
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

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 28) {
          ForEach(items) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              TVLandscapeCard(item: item)
            }
            .buttonStyle(.card)
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
        }
        .padding(.horizontal, 60)
      }
      .buttonStyle(.plain)

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

    do {
      items = try await appState.api.items(libraryId: library.id, limit: 50, offset: 0).items
    } catch {
      self.error = (error as? WebAPIError)?.userMessage ?? "Couldn't load"
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
            token: appState.sessionToken
          )
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
                .accessibilityLabel("No thumbnail")
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
            token: appState.sessionToken
          )
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
                .accessibilityLabel("No poster")
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
          .buttonStyle(.plain)

          Spacer()
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .navigationTitle("Settings")
    }
  }
}

#Preview {
  TVMainView()
    .environment(AppState())
}

#endif
