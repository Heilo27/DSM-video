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
          .accessibilityHidden(true)

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

private struct TVHomeView: View {
  @Environment(AppState.self) private var appState
  @State private var libraries: [Library] = []
  @State private var allItems: [ItemSummary] = []
  @State private var continueWatching: [ItemSummary] = []
  @State private var justAdded: [ItemSummary] = []
  @State private var recentlyWatched: [ItemSummary] = []
  @State private var railsReady: Bool = false
  @State private var isLoading: Bool = false
  @State private var loadError: String?
  @State private var showPairing: Bool = false
  @State private var showSettings: Bool = false
  @State private var showSearch: Bool = false

  var body: some View {
    NavigationStack {
      ZStack(alignment: .top) {
        Color.black.ignoresSafeArea()

        VStack(spacing: 0) {
          // Offline banner at top
          OfflineBanner(isOffline: appState.isOffline, serverUnreachable: appState.serverUnreachable)
            .animation(.easeInOut(duration: 0.3), value: appState.isOffline || appState.serverUnreachable)

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
                // Continue Watching — always in tree, collapses when empty post-load
                TVLandscapeRail(title: "Continue Watching", items: continueWatching, isLoading: !railsReady)
                  .opacity(railsReady && continueWatching.isEmpty ? 0 : 1)
                  .frame(height: railsReady && continueWatching.isEmpty ? 0 : nil)
                  .clipped()

                // Just Added — always in tree
                TVLandscapeRail(title: "Just Added", items: justAdded, isLoading: !railsReady)
                  .opacity(railsReady && justAdded.isEmpty ? 0 : 1)
                  .frame(height: railsReady && justAdded.isEmpty ? 0 : nil)
                  .clipped()

                // Recently Watched — always in tree (new rail)
                TVLandscapeRail(title: "Recently Watched", items: recentlyWatched, isLoading: !railsReady)
                  .opacity(railsReady && recentlyWatched.isEmpty ? 0 : 1)
                  .frame(height: railsReady && recentlyWatched.isEmpty ? 0 : nil)
                  .clipped()

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
        ToolbarItem(placement: .topBarLeading) {
          Button {
            showSearch = true
          } label: {
            Label("Search", systemImage: "magnifyingglass")
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
    .sheet(isPresented: $showSearch) {
      TVSearchView()
        .environment(appState)
    }
    .task { await load() }
    .onReceive(NotificationCenter.default.publisher(for: .playerDidDismiss)) { _ in
      guard !allItems.isEmpty else { return }
      Task { await refreshProgress() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .networkDidReconnect)) { _ in
      Task { await load() }
    }
  }

  // MARK: - Load

  private func load() async {
    guard !isLoading else { return }

    if appState.isDemoMode {
      libraries = DemoData.libraries
      allItems = DemoData.movieItems + DemoData.tvItems
      await refreshProgress()
      return
    }

    loadError = nil
    isLoading = true
    defer { isLoading = false }

    do {
      libraries = try await appState.api.libraries().libraries

      let api = appState.api
      var fetched: [ItemSummary] = []
      await withTaskGroup(of: [ItemSummary].self) { group in
        for lib in libraries {
          group.addTask {
            (try? await api.items(libraryId: lib.id, limit: 200, offset: 0).items) ?? []
          }
        }
        for await items in group {
          fetched.append(contentsOf: items)
        }
      }
      allItems = fetched
      await refreshProgress()
    } catch {
      appState.handleConnectionFailure(error)
      loadError =
        (error as? APIError)?.userMessage
        ?? "Failed to load content. Check your connection and try again."
    }
  }

  // MARK: - Progress Refresh

  /// Fetches current watch progress for all in-memory items, merges it, then recomputes rails.
  /// Guards on isDemoMode — demo items already have embedded progress.
  private func refreshProgress() async {
    guard !allItems.isEmpty, !appState.isDemoMode else {
      recomputeRails()
      return
    }
    let ids = allItems.map(\.id)
    let chunkSize = 200
    let chunks = stride(from: 0, to: ids.count, by: chunkSize).map {
      Array(ids[$0..<min($0 + chunkSize, ids.count)])
    }
    let api = appState.api
    var progressMap: [String: ItemProgress] = [:]
    do {
      let maxConcurrent = 4
      let results = try await withThrowingTaskGroup(of: Result<[String: ItemProgress], Error>.self) { group in
        var inFlight = 0
        var chunkIterator = chunks.makeIterator()
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
    } catch {
      // Non-fatal: rails will show without progress data
    }
    recomputeRails()
  }

  // MARK: - Rail Computation

  /// Recomputes all three rail arrays off the main thread, then applies results atomically.
  /// Always sets railsReady=true — only call when items+progress are both final.
  private func recomputeRails() {
    let items = allItems
    Task.detached(priority: .userInitiated) {
      let (cont, added, watched) = Self.computeRails(items)
      await MainActor.run {
        self.continueWatching = cont
        self.justAdded = added
        self.recentlyWatched = watched
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
}

// MARK: - Landscape Card Rail (Continue Watching / Just Added / Recently Watched)

private struct TVLandscapeRail: View {
  let title: String
  let items: [ItemSummary]
  var isLoading: Bool = false

  private let skeletonCount = 4

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(title)
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 60)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 28) {
          if isLoading {
            ForEach(0..<skeletonCount, id: \.self) { _ in
              TVSkeletonLandscapeCard()
            }
          } else {
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
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 12)
      }
    }
  }
}

// MARK: - Library Rail (per-library, portrait cards)

private struct TVLibraryRail: View {
  @Environment(AppState.self) private var appState
  let library: Library

  @State private var items: [ItemSummary] = []
  @State private var isLoading: Bool = false
  @State private var error: String?

  private let skeletonCount = 5

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

      if let error {
        Text(error)
          .font(.footnote)
          .foregroundStyle(Color.dsTextMuted)
          .padding(.horizontal, 60)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 28) {
          if isLoading && items.isEmpty {
            ForEach(0..<skeletonCount, id: \.self) { _ in
              TVSkeletonPortraitCard()
            }
          } else {
            ForEach(items.prefix(20)) { item in
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
      self.error = (error as? APIError)?.userMessage ?? "Couldn't load"
    }
  }
}

// MARK: - Skeleton Cards

/// Skeleton placeholder for landscape (16:9) cards — matches TVLandscapeCard dimensions (380×214pt).
private struct TVSkeletonLandscapeCard: View {
  private let cardWidth: CGFloat = 380
  private let cardHeight: CGFloat = 214
  @State private var shimmerPhase: CGFloat = 0

  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(Color.white.opacity(0.08))
      .frame(width: cardWidth, height: cardHeight)
      .overlay(
        GeometryReader { geo in
          LinearGradient(
            gradient: Gradient(colors: [.clear, Color.white.opacity(0.12), .clear]),
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: geo.size.width * 2)
          .offset(x: shimmerPhase * (geo.size.width * 3) - geo.size.width)
          .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      )
      .accessibilityHidden(true)
      .onAppear {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
          shimmerPhase = 1
        }
      }
  }
}

/// Skeleton placeholder for portrait (2:3) cards — matches TVPortraitCard dimensions (220×330pt).
private struct TVSkeletonPortraitCard: View {
  private let cardWidth: CGFloat = 220
  private let cardHeight: CGFloat = 330
  @State private var shimmerPhase: CGFloat = 0

  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(Color.white.opacity(0.08))
      .frame(width: cardWidth, height: cardHeight)
      .overlay(
        GeometryReader { geo in
          LinearGradient(
            gradient: Gradient(colors: [.clear, Color.white.opacity(0.12), .clear]),
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: geo.size.width * 2)
          .offset(x: shimmerPhase * (geo.size.width * 3) - geo.size.width)
          .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      )
      .accessibilityHidden(true)
      .onAppear {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
          shimmerPhase = 1
        }
      }
  }
}

// MARK: - Landscape Card (16:9, for Continue Watching / Just Added / Recently Watched)

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
      VStack(alignment: .leading, spacing: 32) {
        TextField("Search your library", text: $searchText)
          .font(.system(size: 32))
          .frame(maxWidth: 800)
          .onSubmit { Task { await search() } }
          .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
              debounceTask?.cancel()
              results = []
              hasSearched = false
              searchError = nil
            } else if newValue.count >= 2 {
              debounceTask?.cancel()
              debounceTask = Task {
                if (try? await Task.sleep(for: .milliseconds(500))) != nil {
                  await search()
                }
              }
            }
          }

        if isSearching {
          ProgressView("Searching…")
            .frame(maxWidth: .infinity, alignment: .center)
        } else if let err = searchError {
          Text(err)
            .font(.callout)
            .foregroundStyle(Color.dsError)
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
                        token: appState.sessionToken
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
                Divider().background(Color(white: 0.2)).padding(.horizontal, 60)
              }
            }
          }
        } else if !hasSearched {
          Text("Enter a title to search your library")
            .font(.system(size: 22))
            .foregroundStyle(Color.dsTextSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }

        Spacer()
      }
      .padding(.top, 60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.ignoresSafeArea())
      .navigationTitle("Search")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
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
  }
}

#Preview {
  TVMainView()
    .environment(AppState())
}

#endif
