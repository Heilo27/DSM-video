import SwiftUI
import os.log

private let showLog = Logger(subsystem: "com.dsm.dsvideo", category: "TVShowDetail")

struct TVShowDetailView: View {
  let show: TVShow
  let library: Library
  var highlightEpisodeID: String? = nil
  var highlightSeason: Int? = nil

  var body: some View {
    #if os(tvOS)
    TVShowDetailSplitView(show: show, library: library,
                          highlightEpisodeID: highlightEpisodeID,
                          highlightSeason: highlightSeason)
    #else
    TVShowDetailScrollView(show: show, library: library,
                           highlightEpisodeID: highlightEpisodeID,
                           highlightSeason: highlightSeason)
    #endif
  }
}

// MARK: - tvOS: Cinematic Split-Screen

#if os(tvOS)
private struct TVShowDetailSplitView: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let library: Library
  var highlightEpisodeID: String? = nil
  var highlightSeason: Int? = nil

  @State private var seasons: [TVSeason] = []
  @State private var isLoading = false
  @State private var error: String?
  // Computed resume point — derived from episode progress after seasons load
  @State private var resolvedHighlightEpisodeID: String? = nil
  @State private var resolvedHighlightSeason: Int? = nil

  private var effectiveHighlightEpisodeID: String? { highlightEpisodeID ?? resolvedHighlightEpisodeID }
  private var effectiveHighlightSeason: Int? { highlightSeason ?? resolvedHighlightSeason }

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
            .focusSection()
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
      if appState.isDemoMode, let assetName = DemoData.posterAssetNames[show.id] {
        Image(assetName)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .clipped()
          .accessibilityHidden(true)
      } else if let posterId = show.posterImageId {
        AuthenticatedImage(
          url: appState.api.imageURL(id: posterId, width: 1400, version: show.metadataVersion),
          token: appState.sessionToken,
          usesTunnelCookie: appState.api.usesTunnelCookie
        )
        .scaledToFill()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .accessibilityHidden(true)
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
            .accessibilityHidden(true)
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
          if show.year != nil {
            Circle()
              .fill(Color.dsTextMuted)
              .frame(width: 4, height: 4)
              .accessibilityHidden(true)
          }
          if let sc = show.seasonCount {
            Text("\(sc) season\(sc == 1 ? "" : "s")")
              .font(.system(size: 20))
              .foregroundStyle(Color.dsTextSecondary)
          }
        }
      }
      .accessibilityElement(children: .combine)
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
            TVSeasonSection(show: show, season: season, library: library,
                            allSeasons: seasons,
                            highlightEpisodeID: effectiveHighlightEpisodeID,
                            highlightSeason: effectiveHighlightSeason)
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
      // Only resolve a resume point if none was passed in from outside
      if highlightEpisodeID == nil, highlightSeason == nil {
        await resolveResumePoint(for: resp.seasons)
      }
    } catch {
      let msg = (error as? APIError)?.userMessage ?? "Unknown error."
      if seasons.isEmpty { self.error = msg }
    }
  }

  // Find the last in-progress episode across all seasons. Fetches season episodes
  // concurrently; stops scanning once a clear resume point is found.
  private func resolveResumePoint(for seasons: [TVSeason]) async {
    guard !seasons.isEmpty else { return }
    // Fan out: fetch all seasons in parallel (episodes come with progress data)
    let results: [(season: Int, episodes: [ItemSummary])] = await withTaskGroup(
      of: (Int, [ItemSummary]).self
    ) { group in
      for s in seasons {
        group.addTask {
          do {
            let resp = try await appState.api.tvShowEpisodes(
              showId: show.id, season: s.seasonNumber, libraryId: library.id)
            return (s.seasonNumber, resp.items)
          } catch {
            return (s.seasonNumber, [])
          }
        }
      }
      var out: [(Int, [ItemSummary])] = []
      for await pair in group { out.append(pair) }
      return out.map { (season: $0.0, episodes: $0.1) }.sorted { $0.season < $1.season }
    }

    // Walk seasons in order; find the last episode with meaningful progress.
    // Priority: in-progress (0 < frac < 0.95) > first unwatched > nothing
    var inProgressEp: ItemSummary? = nil
    var inProgressSeason: Int? = nil
    var firstUnwatchedEp: ItemSummary? = nil
    var firstUnwatchedSeason: Int? = nil

    for entry in results {
      for ep in entry.episodes {
        if let prog = ep.progress, prog.durationSeconds > 0 {
          let frac = Double(prog.positionSeconds) / Double(prog.durationSeconds)
          if frac > 0.02 && frac < 0.95 {
            // Track the *latest* in-progress episode (overwrite as we walk forward)
            inProgressEp = ep
            inProgressSeason = entry.season
          } else if frac >= 0.95 {
            // Fully watched — next episode (if any) is the first unwatched candidate
            // We'll pick it up in the next iteration
          }
        } else if firstUnwatchedEp == nil && inProgressEp == nil {
          // No progress at all on this episode — first genuinely unwatched
          firstUnwatchedEp = ep
          firstUnwatchedSeason = entry.season
        }
      }
      // After each fully-watched season, reset firstUnwatched to pick from next season
      if let _ = inProgressEp { firstUnwatchedEp = nil; firstUnwatchedSeason = nil }
    }

    // After the in-progress episode, the *next* episode is the one to land on
    if let ipEp = inProgressEp, let ipSeason = inProgressSeason {
      // Find the next episode after the in-progress one in the same or next season
      var foundNext = false
      outer: for entry in results where entry.season >= ipSeason {
        for ep in entry.episodes {
          if foundNext {
            resolvedHighlightEpisodeID = ep.id
            resolvedHighlightSeason = entry.season
            return
          }
          if ep.id == ipEp.id { foundNext = true }
        }
      }
      // In-progress episode is the last one (or end of series) — open on it directly
      resolvedHighlightEpisodeID = ipEp.id
      resolvedHighlightSeason = ipSeason
      return
    }

    if let ep = firstUnwatchedEp, let s = firstUnwatchedSeason {
      resolvedHighlightEpisodeID = ep.id
      resolvedHighlightSeason = s
    }
  }
}

// MARK: - tvOS Season Section

private struct TVSeasonSection: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let season: TVSeason
  let library: Library
  let allSeasons: [TVSeason]
  var highlightEpisodeID: String? = nil
  var highlightSeason: Int? = nil

  @State private var episodes: [ItemSummary] = []
  @State private var isLoading = false
  // Default collapsed — only open if this season contains the highlighted episode
  @State private var isExpanded: Bool
  @State private var error: String?

  init(show: TVShow, season: TVSeason, library: Library, allSeasons: [TVSeason],
       highlightEpisodeID: String? = nil, highlightSeason: Int? = nil) {
    self.show = show
    self.season = season
    self.library = library
    self.allSeasons = allSeasons
    self.highlightEpisodeID = highlightEpisodeID
    self.highlightSeason = highlightSeason
    // Open the season that has the highlight; collapse everything else
    self._isExpanded = State(initialValue: highlightSeason == season.seasonNumber)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Season header
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
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
            .accessibilityHidden(true)
        }
        .padding(.vertical, 20)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Season \(season.seasonNumber), \(season.episodeCount) episode\(season.episodeCount == 1 ? "" : "s"), \(isExpanded ? "expanded" : "collapsed")")

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
              Button("Retry") { Task { await load() } }
                .font(.system(size: 17))
                .foregroundStyle(Color.dsAccent)
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 20)
          }
          let seasonIdx = allSeasons.firstIndex(where: { $0.seasonNumber == season.seasonNumber }) ?? 0
          ForEach(Array(episodes.enumerated()), id: \.element.id) { index, ep in
            TVEpisodeNavRow(
              ep: ep,
              isHighlighted: ep.id == highlightEpisodeID,
              destination: TVEpisodeDetailView(
                episodes: episodes,
                initialIndex: index,
                show: show,
                library: library,
                allSeasons: allSeasons,
                currentSeasonIndex: seasonIdx,
                autoPlay: ep.id == highlightEpisodeID
              )
            )

            Rectangle()
              .fill(Color.dsBorderSubtle)
              .frame(height: 1)
          }
        }
      }
    }
    .focusSection()
    .task { await load() }
  }

  private func load() async {
    guard !isLoading else { return }
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
    } catch is CancellationError {
      self.error = nil
    } catch {
      let nsErr = error as NSError
      if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
      self.error = (error as? APIError)?.userMessage ?? "Failed to load episodes."
    }
  }
}

// MARK: - tvOS Episode Nav Row (plain button style to prevent focus-scale clipping)

private struct TVEpisodeNavRow<Destination: View>: View {
  let ep: ItemSummary
  let isHighlighted: Bool
  let destination: Destination
  @FocusState private var isFocused: Bool

  var body: some View {
    NavigationLink {
      destination
    } label: {
      TVEpisodeRow(ep: ep, isHighlighted: isHighlighted)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isFocused ? Color(white: 0.22) : Color.clear)
        )
    }
    .buttonStyle(.plain)
    .focused($isFocused)
  }
}

// MARK: - tvOS Episode Row

private struct TVEpisodeRow: View {
  @Environment(AppState.self) private var appState
  let ep: ItemSummary
  var isHighlighted: Bool = false

  var body: some View {
    HStack(spacing: 20) {
      // Episode number badge
      Text(ep.episodeNumber.map { "E\($0)" } ?? "–")
        .font(.system(size: 17, weight: .semibold).monospacedDigit())
        .foregroundStyle(Color.dsTextMuted)
        .frame(width: 40, alignment: .center)
        .accessibilityHidden(true)

      // Thumbnail (16:9 landscape)
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(white: 0.1))
          .frame(width: 120, height: 68)

        if appState.isDemoMode, let assetName = DemoData.posterAssetNames[ep.id] {
          Image(assetName)
            .resizable()
            .scaledToFill()
            .frame(width: 120, height: 68, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let posterID = ep.posterImageId {
          AuthenticatedImage(
            url: appState.api.imageURL(id: posterID, width: 240),
            token: appState.sessionToken,
            usesTunnelCookie: appState.api.usesTunnelCookie
          )
          .scaledToFill()
          .frame(width: 120, height: 68, alignment: .top)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
          Image(systemName: "play.fill")
            .font(.system(size: 20))
            .foregroundStyle(.white.opacity(0.3))
        }
      }

      // Title + duration
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(ep.title)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
          if isHighlighted {
            Image(systemName: "play.circle.fill")
              .font(.system(size: 18))
              .foregroundStyle(Color.dsAccent)
              .accessibilityLabel("Resume here")
          }
        }

        if let dur = ep.durationSeconds, dur > 0 {
          Text(formatDuration(dur))
            .font(.system(size: 15))
            .foregroundStyle(Color.dsTextSecondary)
        }
      }

      Spacer()

      // Progress indicator (tvOS)
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
            .accessibilityLabel("Watched")
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
          .accessibilityLabel("\(ep.episodeNumber.map { "Episode \($0), " } ?? "")\(Int(frac * 100)) percent watched")
        }
      }
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 20)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - tvOS Episode Detail (with next-episode support)

private struct TVEpisodeDetailView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var currentEpisodes: [ItemSummary]
  @State private var currentIndex: Int
  @State private var autoPlayCurrent: Bool
  let show: TVShow
  let library: Library
  let allSeasons: [TVSeason]
  @State private var currentSeasonIndex: Int
  @State private var nextSeasonEpisodes: [ItemSummary] = []
  @State private var isFetchingNextSeason = false

  // "Are you still watching?" state
  @State private var consecutiveEpisodesWatched: Int = 0
  @State private var showStillWatching: Bool = false
  @State private var stillWatchingCountdown: Int = 20
  @State private var stillWatchingTask: Task<Void, Never>? = nil
  // Pending next-episode advance — held until user confirms or timer fires
  @State private var pendingAdvance: (() -> Void)? = nil

  private let stillWatchingThreshold = 4

  init(episodes: [ItemSummary], initialIndex: Int, show: TVShow, library: Library,
       allSeasons: [TVSeason] = [], currentSeasonIndex: Int = 0, autoPlay: Bool = false) {
    self._currentEpisodes = State(initialValue: episodes)
    self._currentIndex = State(initialValue: initialIndex)
    self._autoPlayCurrent = State(initialValue: autoPlay)
    self.show = show
    self.library = library
    self.allSeasons = allSeasons
    self._currentSeasonIndex = State(initialValue: currentSeasonIndex)
  }

  private var current: ItemSummary? {
    guard !currentEpisodes.isEmpty else { return nil }
    return currentEpisodes[min(currentIndex, currentEpisodes.count - 1)]
  }

  private var hasNextInSeason: Bool { currentIndex + 1 < currentEpisodes.count }
  private var isAtSeasonBoundary: Bool {
    !currentEpisodes.isEmpty
      && currentIndex == currentEpisodes.count - 1
      && currentSeasonIndex + 1 < allSeasons.count
  }
  private var isLastOfSeason: Bool {
    !currentEpisodes.isEmpty
      && currentIndex == currentEpisodes.count - 1
      && currentSeasonIndex + 1 >= allSeasons.count
  }
  private var nextEpisode: ItemSummary? {
    if hasNextInSeason { return currentEpisodes[currentIndex + 1] }
    if isAtSeasonBoundary, let first = nextSeasonEpisodes.first { return first }
    return nil
  }

  var body: some View {
    ZStack {
      if let current {
        ItemDetailView(
          itemID: current.id,
          fallbackTitle: current.title,
          autoPlay: autoPlayCurrent,
          nextEpisode: nextEpisode,
          onNextEpisode: nextEpisode != nil ? { advanceToNextEpisode() } : nil,
          onGoToShow: { dismiss() },
          isLastOfSeason: isLastOfSeason,
          seasonNumber: current.seasonNumber,
          episodeNumber: current.episodeNumber
        )
        .id(current.id)
        .task(id: currentIndex) {
          guard isAtSeasonBoundary, !isFetchingNextSeason, nextSeasonEpisodes.isEmpty else { return }
          await fetchNextSeason()
        }
      }

      if showStillWatching {
        StillWatchingOverlay(
          countdown: stillWatchingCountdown,
          onYes: {
            stillWatchingTask?.cancel()
            showStillWatching = false
            consecutiveEpisodesWatched = 0
            pendingAdvance?()
            pendingAdvance = nil
          },
          onStop: {
            stillWatchingTask?.cancel()
            showStillWatching = false
            dismiss()
          }
        )
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: showStillWatching)
      }
    }
    .onDisappear {
      stillWatchingTask?.cancel()
    }
  }

  private func advanceToNextEpisode() {
    consecutiveEpisodesWatched += 1

    let advance = {
      if self.hasNextInSeason {
        self.currentIndex += 1
        self.autoPlayCurrent = true
      } else if self.isAtSeasonBoundary, !self.nextSeasonEpisodes.isEmpty {
        self.currentEpisodes = self.nextSeasonEpisodes
        self.nextSeasonEpisodes = []
        self.currentSeasonIndex += 1
        self.currentIndex = 0
        self.autoPlayCurrent = true
      }
    }

    guard consecutiveEpisodesWatched >= stillWatchingThreshold else {
      advance()
      return
    }

    // Hit the threshold — pause and ask
    pendingAdvance = advance
    stillWatchingCountdown = 20
    showStillWatching = true
    stillWatchingTask?.cancel()
    stillWatchingTask = Task { @MainActor in
      for remaining in stride(from: 20, through: 0, by: -1) {
        guard !Task.isCancelled else { return }
        stillWatchingCountdown = remaining
        if remaining == 0 {
          showStillWatching = false
          pendingAdvance = nil
          dismiss()
          return
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }

  private func fetchNextSeason() async {
    guard isAtSeasonBoundary, !isFetchingNextSeason, nextSeasonEpisodes.isEmpty else { return }
    let nextSeasonNumber = allSeasons[currentSeasonIndex + 1].seasonNumber
    isFetchingNextSeason = true
    defer { isFetchingNextSeason = false }
    do {
      let resp = try await appState.api.tvShowEpisodes(
        showId: show.id, season: nextSeasonNumber, libraryId: library.id)
      nextSeasonEpisodes = resp.items
    } catch {
      showLog.error("fetchNextSeason failed for show \(show.id) season \(allSeasons[currentSeasonIndex + 1].seasonNumber): \(error)")
    }
  }
}

// MARK: - Still Watching Overlay (tvOS)

private struct StillWatchingOverlay: View {
  let countdown: Int
  let onYes: () -> Void
  let onStop: () -> Void

  @FocusState private var focused: StillWatchingButton?
  enum StillWatchingButton: Hashable { case yes, stop }

  var body: some View {
    ZStack {
      Color.black.opacity(0.75).ignoresSafeArea()

      VStack(spacing: 32) {
        VStack(spacing: 12) {
          Text("Are you still watching?")
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(.white)
          Text("Stopping in \(countdown)s")
            .font(.system(size: 22))
            .foregroundStyle(Color.dsTextSecondary)
            .monospacedDigit()
        }

        HStack(spacing: 24) {
          stillWatchingButton(label: "Yes, keep playing", sfSymbol: "play.fill",
                              button: .yes, isPrimary: true, action: onYes)
          stillWatchingButton(label: "Stop", sfSymbol: "stop.fill",
                              button: .stop, isPrimary: false, action: onStop)
        }
      }
      .padding(60)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    .onAppear { focused = .yes }
  }

  @ViewBuilder
  private func stillWatchingButton(label: String, sfSymbol: String,
                                   button: StillWatchingButton, isPrimary: Bool,
                                   action: @escaping () -> Void) -> some View {
    let isFocused = focused == button
    Button(action: action) {
      Label(label, systemImage: sfSymbol)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 280, height: 60)
        .background(
          Group {
            if isPrimary {
              Color.red.brightness(isFocused ? 0.12 : 0)
            } else {
              isFocused ? Color(white: 0.35) : Color(white: 0.22)
            }
          }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .focused($focused, equals: button)
  }
}

#endif  // os(tvOS)

// MARK: - iOS/macOS Scroll View (non-tvOS)

#if !os(tvOS)
private struct TVShowDetailScrollView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let show: TVShow
  let library: Library
  var highlightEpisodeID: String? = nil
  var highlightSeason: Int? = nil

  @State private var seasons: [TVSeason] = []
  @State private var isLoading = false
  @State private var error: String?
  @State private var showMetadataFixer = false
  @State private var metadataFixApplied = false

  private var headerHeight: CGFloat {
    horizontalSizeClass == .regular ? 320 : 220
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        showHeader

        VStack(alignment: .leading, spacing: 0) {
          if isLoading && seasons.isEmpty {
            ProgressView("Loading").padding(.top, 32).frame(maxWidth: .infinity)
              .accessibilityLabel("Loading seasons, please wait")
          } else if let error {
            ContentUnavailableView(
              "Couldn't load seasons",
              systemImage: "exclamationmark.triangle",
              description: Text(error)
            )
            .padding(.top, 32)
          } else if seasons.isEmpty {
            VStack(spacing: 16) {
              ContentUnavailableView(
                "No seasons found",
                systemImage: "exclamationmark.triangle",
                description: Text("Couldn't load episodes for this show.")
              )
              Button("Retry") { isLoading = false; Task { await load() } }
                .buttonStyle(.bordered)
            }
            .padding(.top, 32)
            .frame(maxWidth: .infinity)
          } else {
            ForEach(seasons, id: \.seasonNumber) { season in
              // FIX-2: pass allSeasons so EpisodeDetailView can navigate cross-season
              iOSSeasonSection(show: show, season: season, library: library,
                               highlightEpisodeID: highlightEpisodeID,
                               highlightSeason: highlightSeason,
                               allSeasons: seasons)
            }
          }
        }
        .frame(maxWidth: horizontalSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(show.title)
    .task { await load() }
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarBackground(Color.black.opacity(0.85), for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Fix Metadata", systemImage: "magnifyingglass") {
            showMetadataFixer = true
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More options")
      }
    }
    .sheet(isPresented: $showMetadataFixer, onDismiss: {
      let shouldReload = metadataFixApplied
      metadataFixApplied = false
      if shouldReload {
        Task { await load() }
      }
    }) {
      TVShowMetadataFixerSheet(showId: show.id, initialQuery: show.title, onApplied: {
        metadataFixApplied = true
      })
      .environment(appState)
    }
    #endif
  }

  @ViewBuilder
  private var showHeader: some View {
    ZStack(alignment: .bottomLeading) {
      if appState.isDemoMode, let assetName = DemoData.posterAssetNames[show.id] {
        Image(assetName)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight, alignment: .top)
          .clipped()
          .accessibilityHidden(true)
      } else if let posterId = show.posterImageId {
        AuthenticatedImage(
          url: appState.api.imageURL(id: posterId, width: 1200, version: show.metadataVersion),
          token: appState.sessionToken,
          usesTunnelCookie: appState.api.usesTunnelCookie
        )
        .scaledToFill()
        .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight, alignment: .top)
        .clipped()
        .accessibilityHidden(true)
      } else {
        Color(white: 0.08)
          .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight)
          .overlay(
            Image(systemName: "tv.fill")
              .font(.system(size: 48))
              .foregroundStyle(.white.opacity(0.2))
              .accessibilityHidden(true)
          )
      }

      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.0),
          .init(color: .black.opacity(0.8), location: 0.55),
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
          if show.year != nil { Text("·").foregroundStyle(.white.opacity(0.5)).accessibilityHidden(true) }
          if let sc = show.seasonCount {
            Text("\(sc) season\(sc == 1 ? "" : "s")")
              .font(.subheadline).foregroundStyle(.white.opacity(0.75))
          }
        }
      }
      .accessibilityElement(children: .combine)
      .padding(.horizontal, 16)
      .padding(.bottom, 14)
    }
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
      showLog.info("load: showId=\(show.id, privacy: .public) libraryId=\(library.id, privacy: .public)")
      let resp = try await appState.api.tvShowSeasons(showId: show.id, libraryId: library.id)
      showLog.info("load: got \(resp.seasons.count) seasons")
      seasons = resp.seasons
      error = nil
    } catch {
      let msg = (error as? APIError)?.userMessage ?? "Unknown error."
      showLog.error("load: failed — \(msg, privacy: .public)")
      if seasons.isEmpty { self.error = msg }
    }
  }
}
#endif  // !os(tvOS)

// MARK: - iOS Season + Episode (non-tvOS)

#if !os(tvOS)
private struct iOSSeasonSection: View {
  @Environment(AppState.self) private var appState
  let show: TVShow
  let season: TVSeason
  let library: Library
  var highlightEpisodeID: String? = nil
  var highlightSeason: Int? = nil
  // FIX-2: pass full seasons list so EpisodeDetailView can navigate across seasons
  var allSeasons: [TVSeason] = []

  @State private var episodes: [ItemSummary] = []
  @State private var isLoading = false
  @State private var isExpanded: Bool
  @State private var error: String?
  @State private var episodeLoadTask: Task<Void, Never>?

  init(show: TVShow, season: TVSeason, library: Library,
       highlightEpisodeID: String? = nil, highlightSeason: Int? = nil,
       allSeasons: [TVSeason] = []) {
    self.show = show
    self.season = season
    self.library = library
    self.highlightEpisodeID = highlightEpisodeID
    self.highlightSeason = highlightSeason
    self.allSeasons = allSeasons
    // Auto-expand the season that contains the highlighted episode
    self._isExpanded = State(initialValue: highlightSeason == nil || highlightSeason == season.seasonNumber)
  }

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
            .foregroundStyle(.white.opacity(0.75))
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Season \(season.seasonNumber), \(season.episodeCount) episode\(season.episodeCount == 1 ? "" : "s"), \(isExpanded ? "expanded" : "collapsed")")

      Divider().background(Color.white.opacity(0.1))

      if isExpanded {
        if isLoading && episodes.isEmpty {
          ProgressView("Loading").padding(.vertical, 16).frame(maxWidth: .infinity)
            .accessibilityLabel("Loading episodes, please wait")
        } else {
          if let error, episodes.isEmpty {
            HStack {
              Text(error)
                .font(.footnote)
                .foregroundStyle(Color.dsTextMuted)
              Spacer()
              Button("Retry") {
                episodeLoadTask?.cancel()
                episodeLoadTask = Task { await load() }
              }
              .font(.footnote)
              .foregroundStyle(Color.dsAccent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          }
          ForEach(Array(episodes.enumerated()), id: \.element.id) { index, ep in
            let isHighlighted = ep.id == highlightEpisodeID
            // FIX-2: compute season index so EpisodeDetailView can cross seasons
            let seasonIdx = allSeasons.firstIndex(where: { $0.seasonNumber == season.seasonNumber }) ?? 0
            NavigationLink {
              EpisodeDetailView(
                episodes: episodes,
                initialIndex: index,
                show: show,
                library: library,
                allSeasons: allSeasons,
                currentSeasonIndex: seasonIdx,
                autoPlay: isHighlighted
              )
            } label: {
              iOSEpisodeRow(ep: ep, isHighlighted: isHighlighted)
                .contentShape(Rectangle())
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
    // FIX-17: removed `episodes.isEmpty` guard — allows reload after metadata update.
    // Previously, once episodes were loaded, retapping would no-op even after a metadata
    // fix was applied. isLoading guard still prevents concurrent fetches.
    guard !isLoading else { return }
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
    } catch is CancellationError {
      self.error = nil
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Failed to load episodes."
    }
  }
}
#endif  // !os(tvOS)

#if !os(tvOS)
private struct iOSEpisodeRow: View {
  let ep: ItemSummary
  var isHighlighted: Bool = false

  var body: some View {
    HStack(spacing: 12) {
      Text(ep.episodeNumber.map { "E\($0)" } ?? "–")
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(isHighlighted ? Color.dsAccent : .white.opacity(0.75))
        .frame(width: 32, alignment: .center)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(ep.title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(2)
          if isHighlighted {
            Image(systemName: "play.circle.fill")
              .font(.caption)
              .foregroundStyle(Color.dsAccent)
              .accessibilityLabel("Resume here")
          }
        }

        if let dur = ep.durationSeconds, dur > 0 {
          Text(formatDuration(dur))
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))
        }
      }

      Spacer()

      if let prog = ep.progress, prog.durationSeconds > 0 {
        let frac = min(1.0, Double(prog.positionSeconds) / Double(prog.durationSeconds))
        if frac >= 0.95 {
          Image(systemName: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.dsSuccess)
            .frame(width: 20, height: 20)
            .accessibilityLabel("Watched")
        } else {
          iOSCircularProgress(fraction: frac)
            .frame(width: 20, height: 20)
            .accessibilityLabel("\(Int(frac * 100)) percent watched")
        }
      }

      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.3))
        .accessibilityHidden(true)
    }
    .frame(minHeight: 44)
    .accessibilityElement(children: .combine)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }
}
#endif  // !os(tvOS)

// MARK: - Episode Detail View (iOS/macOS — with Next Episode nav)

#if !os(tvOS)
private struct EpisodeDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState
  // FIX-2: mutable episodes list — starts as the initial season, can be swapped when
  // crossing into the next season.
  @State private var currentEpisodes: [ItemSummary]
  @State private var currentIndex: Int
  @State private var autoPlayCurrent: Bool
  let show: TVShow
  let library: Library
  // FIX-2: all seasons for this show so we can cross season boundaries
  let allSeasons: [TVSeason]
  // FIX-2: mutable season cursor — advances when crossing into the next season
  @State private var currentSeasonIndex: Int

  // FIX-2: next season's episodes, fetched lazily when approaching season boundary
  @State private var nextSeasonEpisodes: [ItemSummary] = []
  @State private var isFetchingNextSeason: Bool = false

  init(episodes: [ItemSummary], initialIndex: Int, show: TVShow, library: Library,
       allSeasons: [TVSeason] = [], currentSeasonIndex: Int = 0,
       autoPlay: Bool = false) {
    self._currentEpisodes = State(initialValue: episodes)
    self._currentIndex = State(initialValue: initialIndex)
    self._autoPlayCurrent = State(initialValue: autoPlay)
    self.show = show
    self.library = library
    self.allSeasons = allSeasons
    self._currentSeasonIndex = State(initialValue: currentSeasonIndex)
  }

  private var current: ItemSummary? {
    guard !currentEpisodes.isEmpty else { return nil }
    let index = min(currentIndex, currentEpisodes.count - 1)
    return currentEpisodes[index]
  }

  // True if there is a same-season next episode
  private var hasNextInSeason: Bool { currentEpisodes.count > 0 && currentIndex + 1 < currentEpisodes.count }
  // True if we're on the last episode of this season AND there is a subsequent season
  private var isAtSeasonBoundary: Bool {
    !currentEpisodes.isEmpty
      && currentIndex == currentEpisodes.count - 1
      && currentSeasonIndex + 1 < allSeasons.count
  }
  // True if this is the last episode with no further seasons to cross into
  private var isLastOfSeason: Bool {
    !currentEpisodes.isEmpty
      && currentIndex == currentEpisodes.count - 1
      && currentSeasonIndex + 1 >= allSeasons.count
  }

  // The next episode: same-season takes priority, then first of next season
  private var nextEpisode: ItemSummary? {
    if hasNextInSeason { return currentEpisodes[currentIndex + 1] }
    if isAtSeasonBoundary, let first = nextSeasonEpisodes.first { return first }
    return nil
  }

  var body: some View {
    if let current {
      ItemDetailView(
        itemID: current.id,
        fallbackTitle: current.title,
        autoPlay: autoPlayCurrent,
        nextEpisode: nextEpisode,
        onNextEpisode: nextEpisode != nil ? {
          if hasNextInSeason {
            // Same season — simple index bump
            currentIndex += 1
            autoPlayCurrent = true
          } else if isAtSeasonBoundary, !nextSeasonEpisodes.isEmpty {
            // FIX-2: Cross-season — swap episodes list to next season, reset index.
            // The .id(current.id) modifier forces ItemDetailView to fully recreate.
            currentEpisodes = nextSeasonEpisodes
            nextSeasonEpisodes = []
            currentSeasonIndex += 1
            currentIndex = 0
            autoPlayCurrent = true
          }
        } : nil,
        onGoToShow: { dismiss() },
        isLastOfSeason: isLastOfSeason,
        seasonNumber: current.seasonNumber,
        episodeNumber: current.episodeNumber
      )
      .id(current.id)  // force view recreation when episode changes
      .task(id: currentIndex) {
        // FIX-2: Prefetch next season's episodes when the user reaches the last episode
        // of the current season, so the "Next Episode" button appears without delay.
        guard isAtSeasonBoundary,
              !isFetchingNextSeason,
              nextSeasonEpisodes.isEmpty else { return }
        await fetchNextSeasonIfNeeded()
      }
    }
  }

  private func fetchNextSeasonIfNeeded() async {
    guard isAtSeasonBoundary, !isFetchingNextSeason, nextSeasonEpisodes.isEmpty else { return }
    let nextSeasonNumber = allSeasons[currentSeasonIndex + 1].seasonNumber
    isFetchingNextSeason = true
    defer { isFetchingNextSeason = false }
    do {
      let resp = try await appState.api.tvShowEpisodes(
        showId: show.id, season: nextSeasonNumber, libraryId: library.id)
      nextSeasonEpisodes = resp.items
    } catch {
      // Non-fatal: "Next Episode" cross-season button simply won't appear if fetch fails.
      // User can still navigate manually via the season list.
    }
  }
}
#endif

// Shared duration formatter used by episode row views in this file (TASK-507).
private func formatDuration(_ seconds: Int) -> String {
  let h = seconds / 3600
  let m = (seconds % 3600) / 60
  if h > 0 { return "\(h)h \(m)m" }
  return "\(m)m"
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

// MARK: - TV Show Metadata Fixer Sheet

#if !os(tvOS)
private struct TVShowMetadataFixerSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let showId: String
  let initialQuery: String
  var onApplied: (() -> Void)?

  @State private var searchQuery: String
  @State private var results: [TMDbCandidate] = []
  @State private var isSearching = false
  @State private var isApplying = false
  @State private var error: String?

  init(showId: String, initialQuery: String, onApplied: (() -> Void)? = nil) {
    self.showId = showId
    self.initialQuery = initialQuery
    self.onApplied = onApplied
    _searchQuery = State(initialValue: initialQuery)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          TextField("Search TMDb...", text: $searchQuery)
            .onSubmit { Task { await search() } }
            .foregroundStyle(.white)
        }
        .listRowBackground(Color(white: 0.12))

        if isSearching {
          HStack {
            Spacer()
            ProgressView("Searching").tint(.white)
            Spacer()
          }
          .listRowBackground(Color(white: 0.08))
        } else {
          // Pre-compute which title+year keys appear more than once so the
          // ForEach body avoids an O(n²) filter on every render pass.
          let duplicateKeys: Set<String> = {
            var counts: [String: Int] = [:]
            for r in results {
              let key = "\(r.title)|\(r.year.map(String.init) ?? "")"
              counts[key, default: 0] += 1
            }
            return Set(counts.filter { $0.value > 1 }.keys)
          }()
          ForEach(results) { candidate in
            let isDuplicate = duplicateKeys.contains("\(candidate.title)|\(candidate.year.map(String.init) ?? "")")
            Button {
              Task { await apply(candidate) }
            } label: {
              HStack(spacing: 12) {
                AuthenticatedImage(url: candidate.posterURL, token: nil)
                  .scaledToFill()
                  .frame(width: 50, height: 75, alignment: .top)
                  .clipShape(RoundedRectangle(cornerRadius: 6))
                  .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                  Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                  HStack(spacing: 6) {
                    if let year = candidate.year {
                      Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if isDuplicate {
                      Text("ID \(candidate.tmdbId)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                  }
                  if let overview = candidate.overview, !overview.isEmpty {
                    Text(overview)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(3)
                  }
                }
              }
            }
            .accessibilityLabel({
              let base = "\(candidate.title)\(candidate.year.map { ", \($0)" } ?? "")"
              return isDuplicate ? "\(base), TMDb ID \(candidate.tmdbId)" : base
            }())
            .buttonStyle(.plain)
            .disabled(isApplying)
            .listRowBackground(Color(white: 0.1))
          }
        }

        if let error {
          Text(error)
            .foregroundStyle(.red)
            .font(.caption)
            .listRowBackground(Color(white: 0.08))
        }
      }
      .navigationTitle("Fix Show Metadata")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Search") { Task { await search() } }
            .disabled(isSearching)
        }
      }
      .task { await search() }
      .scrollContentBackground(.hidden)
      .background(Color.black)
      .onChange(of: error) { _, msg in
        if let msg { AccessibilityNotification.Announcement(msg).post() }
      }
    }
  }

  private func search() async {
    guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    isSearching = true
    error = nil
    defer { isSearching = false }
    do {
      let resp = try await appState.api.tvShowTMDbSearch(showId: showId, query: searchQuery)
      results = resp.results
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Search failed."
    }
  }

  private func apply(_ candidate: TMDbCandidate) async {
    isApplying = true
    defer { isApplying = false }
    do {
      try await appState.api.tvShowTMDbFix(showId: showId, tmdbId: candidate.tmdbId)
      AccessibilityNotification.Announcement("Metadata updated successfully.").post()
      onApplied?()
      dismiss()
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Failed to apply."
    }
  }
}
#endif
