import SwiftUI

struct TVShowDetailView: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let library: Library

  @State private var seasons: [TVSeason] = []
  @State private var isLoading = false
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        showHeader

        if isLoading && seasons.isEmpty {
          ProgressView().padding(.top, 32).frame(maxWidth: .infinity)
        } else if let error {
          ContentUnavailableView("Couldn't load seasons", systemImage: "exclamationmark.triangle", description: Text(error))
            .padding(.top, 32)
        } else {
          ForEach(seasons, id: \.seasonNumber) { season in
            SeasonSection(show: show, season: season, library: library)
          }
        }
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(show.title)
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await load() }
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
        #if os(tvOS)
        .frame(maxWidth: .infinity, minHeight: 400, maxHeight: 400)
        #else
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
        #endif
        .clipped()
      } else {
        Color(white: 0.08)
          #if os(tvOS)
          .frame(maxWidth: .infinity, minHeight: 400, maxHeight: 400)
          #else
          .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
          #endif
          .overlay(Image(systemName: "tv.fill").font(.system(size: 48)).foregroundStyle(.white.opacity(0.2)).accessibilityLabel("No poster available"))
      }

      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.0),
          .init(color: .black.opacity(0.6), location: 0.55),
          .init(color: .black, location: 1.0)
        ],
        startPoint: .top, endPoint: .bottom
      )
      #if os(tvOS)
      .frame(maxWidth: .infinity, minHeight: 400, maxHeight: 400)
      #else
      .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
      #endif

      VStack(alignment: .leading, spacing: 4) {
        Text(show.title)
          .font(.title2.weight(.bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
        HStack(spacing: 8) {
          if let year = show.year { Text(String(year)).font(.subheadline).foregroundStyle(.white.opacity(0.75)) }
          Text("·").foregroundStyle(.white.opacity(0.5))
          Text("\(show.seasonCount) season\(show.seasonCount == 1 ? "" : "s")")
            .font(.subheadline).foregroundStyle(.white.opacity(0.75))
        }
      }
      #if os(tvOS)
      .padding(.horizontal, 48)
      #else
      .padding(.horizontal, 16)
      #endif
      .padding(.bottom, 14)
    }
  }

  private func load() async {
    guard !isLoading else { return }
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

// MARK: - Season Section

private struct SeasonSection: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let season: TVSeason
  let library: Library

  @State private var episodes: [ItemSummary] = []
  @State private var isLoading = false
  @State private var isExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Season header — tappable to collapse
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
        #if os(tvOS)
        .padding(.horizontal, 48)
        .padding(.vertical, 20)
        #else
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #endif
      }
      #if os(tvOS)
      .buttonStyle(.card)
      #else
      .buttonStyle(.plain)
      #endif

      Divider().background(Color.white.opacity(0.1))

      if isExpanded {
        if isLoading && episodes.isEmpty {
          ProgressView().padding(.vertical, 16).frame(maxWidth: .infinity)
        } else {
          ForEach(episodes) { ep in
            NavigationLink {
              ItemDetailView(itemID: ep.id, fallbackTitle: ep.title)
            } label: {
              EpisodeRow(ep: ep)
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(.plain)
            #endif

            #if os(tvOS)
            Divider().background(Color.white.opacity(0.07)).padding(.leading, 48)
            #else
            Divider().background(Color.white.opacity(0.07)).padding(.leading, 16)
            #endif
          }
        }
      }
    }
    .task { await load() }
  }

  private func load() async {
    guard !isLoading, episodes.isEmpty else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let resp = try await appState.api.tvShowEpisodes(showId: show.id, season: season.seasonNumber, libraryId: library.id)
      episodes = resp.items
    } catch {
      // silent failure — user can refresh parent
    }
  }
}

// MARK: - Episode Row

private struct EpisodeRow: View {
  let ep: ItemSummary

  var body: some View {
    HStack(spacing: 12) {
      // Episode number badge
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

      // Progress indicator
      if let prog = ep.progress, prog.durationSeconds > 0 {
        let frac = Double(prog.positionSeconds) / Double(prog.durationSeconds)
        CircularProgressView(fraction: frac)
          #if os(tvOS)
          .frame(width: 36, height: 36)
          #else
          .frame(width: 20, height: 20)
          #endif
      }

      #if !os(tvOS)
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.3))
        .accessibilityLabel("View episode")
      #endif
    }
    #if os(tvOS)
    .padding(.horizontal, 48)
    .padding(.vertical, 20)
    #else
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    #endif
  }

  private func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
  }
}

// MARK: - Circular Progress

private struct CircularProgressView: View {
  let fraction: Double

  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(Color(red: 0.82, green: 0.15, blue: 0.19), lineWidth: 2)
        .rotationEffect(.degrees(-90))
    }
  }
}
