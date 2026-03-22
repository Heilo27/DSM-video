import SwiftUI

struct TVShowDetailView: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let library: Library

  @State private var seasons: [TVSeason] = []
  @State private var isLoading = false
  @State private var error: String?

  var body: some View {
    #if os(tvOS)
    TVShowDetailSplitView(show: show, library: library)
    #else
    TVShowDetailScrollView(show: show, library: library, seasons: seasons, isLoading: isLoading, error: error)
      .task { await load() }
    #endif
  }

  // Shared load used only by iOS path (tvOS loads internally)
  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      seasons = DemoData.seasons(for: show.id)
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let resp = try await appState.api.tvShowSeasons(showId: show.id, libraryId: library.id)
      seasons = resp.seasons
      error = nil
    } catch {
      let msg = (error as? APIError)?.userMessage ?? "Unknown error."
      if seasons.isEmpty { self.error = msg }
    }
  }
}

// MARK: - tvOS: Cinematic Split-Screen

#if os(tvOS)
private struct TVShowDetailSplitView: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let library: Library

  @State private var seasons: [TVSeason] = []
  @State private var isLoading = false
  @State private var error: String?

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.black.ignoresSafeArea()

      GeometryReader { geo in
        HStack(spacing: 0) {
          // LEFT: Backdrop / poster panel — 55% width
          backdropPanel
            .frame(width: geo.size.width * 0.55)
            .ignoresSafeArea(edges: .leading)

          // RIGHT: Info + episodes — 45% width
          infoPanel
            .frame(width: geo.size.width * 0.45)
        }
      }
    }
    .task { await load() }
  }

  // MARK: Backdrop Panel

  @ViewBuilder
  private var backdropPanel: some View {
    ZStack(alignment: .bottomLeading) {
      // Background image
      if let posterId = show.posterImageId {
        AuthenticatedImage(
          url: appState.api.imageURL(id: posterId, width: 1400),
          token: appState.sessionToken
        )
        .scaledToFill()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      } else {
        LinearGradient(
          colors: [Color(white: 0.14), Color.black],
          startPoint: .topTrailing,
          endPoint: .bottomLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
          Image(systemName: "tv.fill")
            .font(.system(size: 80))
            .foregroundStyle(.white.opacity(0.12))
            .accessibilityLabel("No poster available")
        )
      }

      // Right-edge gradient fade into the info panel
      HStack(spacing: 0) {
        Spacer()
        LinearGradient(
          colors: [.clear, .black],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: 200)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // Bottom gradient
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.0),
          .init(color: .black.opacity(0.5), location: 0.6),
          .init(color: .black, location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // Show title & meta overlaid bottom-left
      VStack(alignment: .leading, spacing: 8) {
        Text(show.title)
          .font(.system(size: 48, weight: .bold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)

        HStack(spacing: 12) {
          if let year = show.year {
            Text(String(year))
              .font(.system(size: 20))
              .foregroundStyle(Color.dsTextSecondary)
          }
          Circle()
            .fill(Color.dsTextMuted)
            .frame(width: 4, height: 4)
          Text("\(show.seasonCount) season\(show.seasonCount == 1 ? "" : "s")")
            .font(.system(size: 20))
            .foregroundStyle(Color.dsTextSecondary)
        }
      }
      .padding(.leading, 60)
      .padding(.bottom, 60)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Info + Episodes Panel

  @ViewBuilder
  private var infoPanel: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 0) {
        // Header spacer so content starts midscreen
        Spacer().frame(height: 80)

        if isLoading && seasons.isEmpty {
          HStack {
            Spacer()
            ProgressView().tint(.white).scaleEffect(1.5).padding(.top, 80)
            Spacer()
          }
        } else if let error {
          ContentUnavailableView(
            "Couldn't load seasons",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
          .foregroundStyle(.white)
          .padding(.top, 60)
        } else {
          ForEach(seasons, id: \.seasonNumber) { season in
            TVSeasonSection(show: show, season: season, library: library)
          }
        }

        Spacer(minLength: 80)
      }
    }
    .padding(.leading, 48)
    .padding(.trailing, 60)
  }

  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      seasons = DemoData.seasons(for: show.id)
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let resp = try await appState.api.tvShowSeasons(showId: show.id, libraryId: library.id)
      seasons = resp.seasons
      error = nil
    } catch {
      let msg = (error as? APIError)?.userMessage ?? "Unknown error."
      if seasons.isEmpty { self.error = msg }
    }
  }
}

// MARK: - tvOS Season Section

private struct TVSeasonSection: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let season: TVSeason
  let library: Library

  @State private var episodes: [ItemSummary] = []
  @State private var isLoading = false
  @State private var isExpanded = true
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Season header
      Button {
        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 12) {
          Text("Season \(season.seasonNumber)")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)

          Spacer()

          Text("\(season.episodeCount) ep\(season.episodeCount == 1 ? "" : "s")")
            .font(.system(size: 17))
            .foregroundStyle(Color.dsTextSecondary)

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.dsTextSecondary)
            .accessibilityLabel(isExpanded ? "Collapse season" : "Expand season")
        }
        .padding(.vertical, 20)
      }
      .buttonStyle(.plain)

      Rectangle()
        .fill(Color.dsBorderSubtle)
        .frame(height: 1)

      if isExpanded {
        if isLoading && episodes.isEmpty {
          HStack {
            Spacer()
            ProgressView().tint(.white).padding(.vertical, 24)
            Spacer()
          }
        } else {
          if let error, episodes.isEmpty {
            HStack {
              Text(error)
                .font(.system(size: 17))
                .foregroundStyle(Color.dsTextMuted)
              Spacer()
              Button("Retry") {
                Task { await load() }
              }
              .font(.system(size: 17))
              .foregroundStyle(Color.dsAccent)
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 20)
          }
          ForEach(episodes) { ep in
            NavigationLink {
              ItemDetailView(itemID: ep.id, fallbackTitle: ep.title)
            } label: {
              TVEpisodeRow(ep: ep)
            }
            .buttonStyle(.card)

            Rectangle()
              .fill(Color.dsBorderSubtle)
              .frame(height: 1)
          }
        }
      }
    }
    .task { await load() }
  }

  private func load() async {
    guard !isLoading, episodes.isEmpty else { return }
    if appState.isDemoMode {
      episodes = DemoData.episodes(for: show.id, season: season.seasonNumber)
      return
    }
    error = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let resp = try await appState.api.tvShowEpisodes(
        showId: show.id, season: season.seasonNumber, libraryId: library.id)
      episodes = resp.items
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Failed to load episodes."
    }
  }
}

// MARK: - tvOS Episode Row

private struct TVEpisodeRow: View {
  @Environment(AppState.self) private var appState
  let ep: ItemSummary

  var body: some View {
    HStack(spacing: 20) {
      // Episode number badge
      Text(ep.episodeNumber.map { "E\($0)" } ?? "–")
        .font(.system(size: 17, weight: .semibold).monospacedDigit())
        .foregroundStyle(Color.dsTextMuted)
        .frame(width: 40, alignment: .center)

      // Thumbnail (16:9 landscape)
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(white: 0.1))
          .frame(width: 120, height: 68)

        if let posterID = ep.posterImageId {
          AuthenticatedImage(
            url: appState.api.imageURL(id: posterID, width: 240),
            token: appState.sessionToken
          )
          .scaledToFill()
          .frame(width: 120, height: 68)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
          Image(systemName: "play.fill")
            .font(.system(size: 20))
            .foregroundStyle(.white.opacity(0.3))
        }
      }

      // Title + duration
      VStack(alignment: .leading, spacing: 6) {
        Text(ep.title)
          .font(.system(size: 19, weight: .medium))
          .foregroundStyle(.white)
          .lineLimit(2)

        if let dur = ep.durationSeconds, dur > 0 {
          Text(formatDuration(dur))
            .font(.system(size: 15))
            .foregroundStyle(Color.dsTextSecondary)
        }
      }

      Spacer()

      // Progress indicator
      if let prog = ep.progress, prog.durationSeconds > 0 {
        let frac = min(1.0, Double(prog.positionSeconds) / Double(prog.durationSeconds))
        if frac >= 0.95 {
          Circle()
            .fill(Color.dsSuccess)
            .frame(width: 32, height: 32)
            .overlay(
              Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
            )
        } else {
          ZStack {
            Circle()
              .stroke(Color(white: 0.25), lineWidth: 3)
            Circle()
              .trim(from: 0, to: frac)
              .stroke(Color.dsAccent, lineWidth: 3)
              .rotationEffect(.degrees(-90))
          }
          .frame(width: 32, height: 32)
        }
      }
    }
    .padding(.vertical, 16)
  }

  private func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
  }
}

#endif  // os(tvOS)

// MARK: - iOS/macOS Scroll View (unchanged logic, minor polish)

private struct TVShowDetailScrollView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let show: TVShow
  let library: Library
  let seasons: [TVSeason]
  let isLoading: Bool
  let error: String?

  private var headerHeight: CGFloat {
    horizontalSizeClass == .regular ? 320 : 220
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        showHeader

        if isLoading && seasons.isEmpty {
          ProgressView().padding(.top, 32).frame(maxWidth: .infinity)
        } else if let error {
          ContentUnavailableView(
            "Couldn't load seasons",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
          .padding(.top, 32)
        } else {
          ForEach(seasons, id: \.seasonNumber) { season in
            iOSSeasonSection(show: show, season: season, library: library)
          }
        }
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(show.title)
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  @ViewBuilder
  private var showHeader: some View {
    ZStack(alignment: .bottomLeading) {
      if let posterId = show.posterImageId {
        AuthenticatedImage(
          url: appState.api.imageURL(id: posterId, width: 1200),
          token: appState.sessionToken
        )
        .scaledToFill()
        .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight)
        .clipped()
      } else {
        Color(white: 0.08)
          .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight)
          .overlay(
            Image(systemName: "tv.fill")
              .font(.system(size: 48))
              .foregroundStyle(.white.opacity(0.2))
              .accessibilityLabel("No poster available")
          )
      }

      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.0),
          .init(color: .black.opacity(0.6), location: 0.55),
          .init(color: .black, location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight)

      VStack(alignment: .leading, spacing: 4) {
        Text(show.title)
          .font(.title2.weight(.bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
        HStack(spacing: 8) {
          if let year = show.year {
            Text(String(year)).font(.subheadline).foregroundStyle(.white.opacity(0.75))
          }
          Text("·").foregroundStyle(.white.opacity(0.5))
          Text("\(show.seasonCount) season\(show.seasonCount == 1 ? "" : "s")")
            .font(.subheadline).foregroundStyle(.white.opacity(0.75))
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 14)
    }
  }
}

// MARK: - iOS Season + Episode (non-tvOS)

private struct iOSSeasonSection: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let season: TVSeason
  let library: Library

  @State private var episodes: [ItemSummary] = []
  @State private var isLoading = false
  @State private var isExpanded = true
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
      } label: {
        HStack {
          Text("Season \(season.seasonNumber)")
            .font(.headline)
            .foregroundStyle(.white)
          Spacer()
          Text("\(season.episodeCount) ep\(season.episodeCount == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.55))
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.55))
            .accessibilityLabel(isExpanded ? "Collapse season" : "Expand season")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .buttonStyle(.plain)

      Divider().background(Color.white.opacity(0.1))

      if isExpanded {
        if isLoading && episodes.isEmpty {
          ProgressView().padding(.vertical, 16).frame(maxWidth: .infinity)
        } else {
          if let error, episodes.isEmpty {
            HStack {
              Text(error)
                .font(.footnote)
                .foregroundStyle(Color.dsTextMuted)
              Spacer()
              Button("Retry") {
                Task { await load() }
              }
              .font(.footnote)
              .foregroundStyle(Color.dsAccent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          }
          ForEach(episodes) { ep in
            NavigationLink {
              ItemDetailView(itemID: ep.id, fallbackTitle: ep.title)
            } label: {
              iOSEpisodeRow(ep: ep)
            }
            .buttonStyle(.plain)

            Divider().background(Color.white.opacity(0.07)).padding(.leading, 16)
          }
        }
      }
    }
    .task { await load() }
  }

  private func load() async {
    guard !isLoading, episodes.isEmpty else { return }
    if appState.isDemoMode {
      episodes = DemoData.episodes(for: show.id, season: season.seasonNumber)
      return
    }
    error = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let resp = try await appState.api.tvShowEpisodes(
        showId: show.id, season: season.seasonNumber, libraryId: library.id)
      episodes = resp.items
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Failed to load episodes."
    }
  }
}

private struct iOSEpisodeRow: View {
  let ep: ItemSummary

  var body: some View {
    HStack(spacing: 12) {
      Text(ep.episodeNumber.map { "E\($0)" } ?? "–")
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
        .frame(width: 32, alignment: .center)

      VStack(alignment: .leading, spacing: 3) {
        Text(ep.title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.white)
          .lineLimit(2)

        if let dur = ep.durationSeconds, dur > 0 {
          Text(formatDuration(dur))
            .font(.caption)
            .foregroundStyle(.white.opacity(0.55))
        }
      }

      Spacer()

      if let prog = ep.progress, prog.durationSeconds > 0 {
        let frac = Double(prog.positionSeconds) / Double(prog.durationSeconds)
        iOSCircularProgress(fraction: frac)
          .frame(width: 20, height: 20)
      }

      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.3))
        .accessibilityLabel("View episode")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
  }
}

private struct iOSCircularProgress: View {
  let fraction: Double

  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(Color.dsAccent, lineWidth: 2)
        .rotationEffect(.degrees(-90))
    }
  }
}
