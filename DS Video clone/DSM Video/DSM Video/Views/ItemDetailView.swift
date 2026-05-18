import AVKit
import SwiftUI

struct ItemDetailView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dismiss) private var dismiss
  @State private var downloadManager = DownloadManager.shared
  let itemID: String
  let fallbackTitle: String
  var autoPlay: Bool = false
  var nextEpisode: ItemSummary? = nil
  var onNextEpisode: (() -> Void)? = nil
  var onGoToShow: (() -> Void)? = nil
  var isLastOfSeason: Bool = false

  @State private var detail: ItemDetail?
  @State private var isLoading: Bool = false
  @State private var error: String?
  @State private var downloadError: String?

  @State private var showPlayer: Bool = false
  @State private var isStartingDownload: Bool = false
  @State private var showMetadataFixer: Bool = false
  @State private var autoPlayFired: Bool = false
  @State private var viewHeight: CGFloat = 852  // sensible default (iPhone 15 Pro)

  private var isDownloaded: Bool {
    downloadManager.isDownloaded(itemId: itemID)
  }

  private var isDownloading: Bool {
    downloadManager.isDownloading(itemId: itemID)
  }

  private var downloadProgress: Double {
    downloadManager.downloadProgress[itemID] ?? 0
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header

        VStack(alignment: .leading, spacing: 14) {
          // Metadata pills
          if detail != nil {
            metadataPills
          }

          // Action row: Play + compact icon buttons
          HStack(spacing: 12) {
            Button {
              showPlayer = true
            } label: {
              Label(isDownloaded ? "Play (Downloaded)" : "Play", systemImage: "play.fill")
                .font(.headline.weight(.semibold))
                #if os(tvOS)
                .frame(maxWidth: .infinity, minHeight: 80)
                #else
                .frame(maxWidth: .infinity, minHeight: 52)
                #endif
            }
            .background(DSReelBrandColor.background)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: DSReelBrandColor.background.opacity(0.45), radius: 8, x: 0, y: 4)
            .accessibilityLabel("Play \(detail?.title ?? fallbackTitle)")

            // Download icon button (iOS only)
            #if !os(tvOS)
            downloadIconButton
            watchlistIconButton
            #endif
          }

          // Download error (separate from detail-load error to avoid clobbering the header)
          #if !os(tvOS)
          if let dlErr = downloadError {
            Text(dlErr)
              .font(.footnote)
              .foregroundStyle(Color.dsError)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          #endif

          // Next Episode button (TV show context only)
          #if !os(tvOS)
          if let next = nextEpisode, let action = onNextEpisode {
            Button {
              action()
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "forward.end.fill")
                  .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                  Text("Next Episode")
                    .font(.subheadline.weight(.semibold))
                  Text((next.episodeNumber.map { "E\($0) · " } ?? "") + next.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.white.opacity(0.5))
              }
              .foregroundStyle(.white)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(Color(white: 0.12))
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next Episode\(next.episodeNumber.map { ", Episode \($0)" } ?? ""): \(next.title)")
            .accessibilityHint("Opens episode detail")
          } else if isLastOfSeason {
            HStack(spacing: 8) {
              Image(systemName: "flag.checkered")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
              Text("End of Season")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("End of season — no more episodes in this season")
          }
          #endif

          if let summary = detail?.summary, !summary.isEmpty {
            Text(summary)
              .font(.body)
              .foregroundStyle(.white.opacity(0.88))
              .fixedSize(horizontal: false, vertical: true)
          }

          if let director = detail?.cast?.first(where: { $0.role == "Director" }) {
            HStack(spacing: 4) {
              Text("Dir.")
                .foregroundStyle(Color.dsTextSecondary)
              Text(director.name)
                .foregroundStyle(Color.dsTextSecondary)
            }
            .font(.subheadline)
          }

          if let cast = detail?.cast, !cast.isEmpty {
            castSection(cast: cast)
          }

          Spacer(minLength: 32)
        }
        #if os(tvOS)
        .padding(.horizontal, 48)
        #else
        .padding(.horizontal, 16)
        .frame(maxWidth: horizontalSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity, alignment: .center)
        #endif
        .padding(.top, 16)
      }
      // Rebuild layout content when player dismisses — prevents horizontal
      // offset corruption that SwiftUI applies to ScrollView content after
      // fullScreenCover dismissal (shows content shifted left, clipping leading edge).
      .id(showPlayer)
    }
    .background(
      GeometryReader { geo in
        Color.black.ignoresSafeArea()
          .onAppear { viewHeight = geo.size.height }
          .onChange(of: geo.size.height) { _, h in viewHeight = h }
      }
    )
    .navigationTitle(detail?.title ?? fallbackTitle)
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarBackground(Color.black.opacity(0.85), for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    #endif
    .task(id: itemID) {
      await load()
    }
    .onAppear {
      // Reset autoPlayFired here (synchronously, on MainActor) before checking autoPlay.
      // Previously this reset lived in .task(id:) which could race with onAppear —
      // the task body ran after onAppear had already set autoPlayFired=true, clearing
      // the flag and preventing the player from ever opening on subsequent navigations.
      autoPlayFired = false
      if autoPlay {
        autoPlayFired = true
        showPlayer = true
      }
    }
    .fullScreenCover(isPresented: $showPlayer) {
      PlayerSheet(
        itemID: itemID,
        title: detail?.title ?? fallbackTitle,
        itemYear: detail?.year,
        nextEpisode: nextEpisode,
        onPlayNextEpisode: onNextEpisode,
        onGoToShow: onGoToShow
      )
      .environment(appState)
      #if !os(tvOS)
      .toolbarVisibility(.hidden, for: .tabBar)
      #endif
    }
    #if os(tvOS)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.left")
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Back")
      }
    }
    #else
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
    .sheet(isPresented: $showMetadataFixer) {
      MetadataFixerSheet(itemID: itemID, initialQuery: detail?.title ?? fallbackTitle) {
        // Reload detail after fix applied
        detail = nil
        Task { await load() }
      }
      .environment(appState)
    }
    #endif
  }

  // MARK: - Header

  private var backdropHeight: CGFloat {
    #if os(tvOS)
    return 450
    #else
    return horizontalSizeClass == .regular ? 420 : min(300, viewHeight * 0.35)
    #endif
  }

  @ViewBuilder
  private var header: some View {
    if isLoading && detail == nil {
      Color.black
        .frame(maxWidth: .infinity, minHeight: backdropHeight)
        .overlay(ProgressView("Loading").tint(.white).accessibilityLabel("Loading, please wait"))
    } else if let error {
      Color.black
        .frame(maxWidth: .infinity, minHeight: backdropHeight)
        .overlay(
          VStack(spacing: 12) {
            ContentUnavailableView(
              "Couldn't load details",
              systemImage: "exclamationmark.triangle",
              description: Text(error)
            )
            // FIX-18: retry button so users aren't stuck on error without navigating away
            Button("Retry") { Task { await load() } }
              .buttonStyle(.borderedProminent)
          }
        )
    } else {
      ZStack(alignment: .bottomLeading) {
        backdropImage
          .frame(maxWidth: .infinity, minHeight: backdropHeight)
          .frame(height: backdropHeight, alignment: .top)
          .clipped()
          #if !os(tvOS)
          .overlay(alignment: .topTrailing) {
            if !appState.isDemoMode,
               (detail?.summary == nil || detail?.summary?.isEmpty == true),
               detail?.images.backdrop.id == nil {
              Button {
                showMetadataFixer = true
              } label: {
                Text("No metadata · Fix")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.white)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .frame(minHeight: 44)  // HIG minimum tap target (TASK-445)
                  .background(Color.black.opacity(0.7))
                  .clipShape(Capsule())
              }
              .accessibilityLabel("Fix missing metadata for \(fallbackTitle)")
              .accessibilityHint("Opens metadata search")
              .padding(10)
            }
          }
          #endif

        // Gradient fade to black at bottom
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .black.opacity(0.8), location: 0.55),
            .init(color: .black, location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: backdropHeight)

        // Floating title/year on gradient — decorative duplicate of nav bar title
        VStack(alignment: .leading, spacing: 4) {
          Text(detail?.title ?? fallbackTitle)
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)

          if let year = detail?.year {
            Text(String(year))
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.75))
          }
        }
        .accessibilityHidden(true)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
      }
    }
  }

  @ViewBuilder
  private var backdropImage: some View {
    if let backdropId = detail?.images.backdrop.id ?? detail?.images.backdrop.mapperId {
      AuthenticatedImage(
        url: appState.api.imageURL(id: backdropId, width: 1200, version: detail?.changeSeq),
        token: appState.sessionToken,
        usesTunnelCookie: appState.api.usesTunnelCookie
      )
      .scaledToFill()
    } else {
      // No backdrop — gradient placeholder with title overlay
      LinearGradient(
        colors: [Color(white: 0.15), Color.black],
        startPoint: .top,
        endPoint: .bottom
      )
      .overlay(alignment: .bottomLeading) {
        Text(detail?.title ?? fallbackTitle)
          .font(.title2.bold())
          .foregroundStyle(.white.opacity(0.7))
          .padding(24)
          .accessibilityHidden(true)
      }
    }
  }

  // MARK: - Metadata Pills

  @ViewBuilder
  private var metadataPills: some View {
    let year = detail?.year
    let contentRating = detail?.contentRating
    let starRating = detail?.rating
    let genres = detail?.genres ?? []
    let durationSeconds = detail?.durationSeconds

    if year != nil || contentRating != nil || starRating != nil || !genres.isEmpty || durationSeconds != nil {
      let metaLabel: String = [
        year.map { String($0) },
        durationSeconds.flatMap { $0 > 0 ? formatDuration($0) : nil },
        contentRating.flatMap { $0.isEmpty ? nil : $0 },
        starRating.map { "Rating \(String(format: "%.1f", $0)) out of 10" },
        genres.isEmpty ? nil : genres.joined(separator: ", ")
      ].compactMap { $0 }.joined(separator: ", ")

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          if let year {
            MetadataPill(text: String(year))
          }
          if let secs = durationSeconds, secs > 0 {
            MetadataPill(text: formatDuration(secs))
          }
          if let contentRating, !contentRating.isEmpty {
            MetadataPill(text: contentRating)
          }
          if let starRating {
            HStack(spacing: 3) {
              Image(systemName: "star.fill")
                .foregroundStyle(Color.dsWarning)
                .font(.caption.weight(.medium))
                .accessibilityHidden(true)
              Text(String(format: "%.1f", starRating))
                .foregroundStyle(.white.opacity(0.85))
                .font(.caption.weight(.medium))
                .accessibilityLabel("Rating: \(String(format: "%.1f", starRating)) out of 10")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(white: 0.16))
            .clipShape(Capsule())
          }
          ForEach(genres, id: \.self) { genre in
            MetadataPill(text: genre)
          }
        }
        .padding(.vertical, 2)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(metaLabel)
    }
  }

  private func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    } else {
      return "\(minutes)m"
    }
  }

  // MARK: - Download Icon Button

  @ViewBuilder
  private var downloadIconButton: some View {
    Button {
      guard !appState.isDemoMode else { return }
      if isDownloading {
        downloadManager.cancelDownload(itemId: itemID)
      } else if isDownloaded {
        downloadManager.deleteDownload(itemId: itemID)
      } else {
        Task { await startDownload() }
      }
    } label: {
      ZStack {
        if isDownloading {
          ZStack {
            Circle()
              .stroke(Color(white: 0.3), lineWidth: 2)
            Circle()
              .trim(from: 0, to: min(1.0, max(0.0, downloadProgress)))
              .stroke(DSReelBrandColor.background, lineWidth: 2)
              .rotationEffect(.degrees(-90))
          }
          .frame(width: 22, height: 22)
        } else if isStartingDownload {
          ProgressView().tint(.white).frame(width: 22, height: 22)
        } else {
          Image(systemName: isDownloaded ? "checkmark" : "arrow.down")
            .font(.title3.weight(.semibold))
            .foregroundStyle(isDownloaded ? DSReelBrandColor.background : .white)
        }
      }
      .frame(width: 52, height: 52)
    }
    .background(Color(white: 0.12))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .disabled(isStartingDownload && !isDownloading)
    .accessibilityLabel(isStartingDownload ? "Starting download" : (isDownloaded ? "Remove download" : (isDownloading ? "Cancel download" : "Download")))
    .accessibilityValue(isDownloading && downloadProgress > 0 && downloadProgress < 1 ? "\(Int(downloadProgress * 100)) percent downloaded" : "")
  }

  // MARK: - Watchlist Icon Button

  private var isInWatchlist: Bool {
    guard let d = detail else { return false }
    return appState.watchlistItems.contains(where: { $0.id == d.id })
  }

  @ViewBuilder
  private var watchlistIconButton: some View {
    Button {
      guard let d = detail else { return }
      let summary = ItemSummary(
        id: d.id,
        type: d.type,
        title: d.title,
        year: d.year,
        durationSeconds: d.durationSeconds,
        addedAt: "",
        rating: d.rating,
        posterImageId: d.images.poster.id
      )
      Task { await appState.toggleWatchlist(item: summary) }
    } label: {
      Image(systemName: isInWatchlist ? "bookmark.fill" : "bookmark")
        .font(.title3.weight(.semibold))
        .foregroundStyle(isInWatchlist ? DSReelBrandColor.background : .white)
        .frame(width: 52, height: 52)
    }
    .background(Color(white: 0.12))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .disabled(detail == nil)
    .accessibilityLabel(isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist")
  }

  // MARK: - Cast Section

  /// Returns a deterministic accent color from a person's name for their avatar chip.
  private func avatarColor(for name: String) -> Color {
    let palette: [Color] = [
      Color(red: 0.55, green: 0.25, blue: 0.75),  // purple
      Color(red: 0.20, green: 0.55, blue: 0.85),  // blue
      Color(red: 0.20, green: 0.65, blue: 0.50),  // teal
      Color(red: 0.80, green: 0.45, blue: 0.20),  // orange
      Color(red: 0.75, green: 0.25, blue: 0.35),  // rose
      Color(red: 0.45, green: 0.60, blue: 0.25),  // green
    ]
    let index = abs(name.hashValue) % palette.count
    return palette[index]
  }

  @ViewBuilder
  private func castSection(cast: [ItemDetail.Person]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Cast")
        .font(.headline)
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)

      // Horizontal avatar chip scroll (TASK-289)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 14) {
          ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
            VStack(spacing: 6) {
              // 56pt circle avatar — photo if available, else initial on colored background
              ZStack {
                if let imageId = person.imageId {
                  AuthenticatedImage(
                    url: appState.api.imageURL(id: imageId, width: 120),
                    token: appState.sessionToken,
                    usesTunnelCookie: appState.api.usesTunnelCookie
                  )
                  .scaledToFill()
                  .frame(width: 56, height: 56)
                  .clipShape(Circle())
                } else {
                  Circle()
                    .fill(avatarColor(for: person.name))
                    .frame(width: 56, height: 56)
                  Text(String(person.name.prefix(1)).uppercased())
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                }
              }

              // Name
              Text(person.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 68)

              // Role
              if let role = person.role, !role.isEmpty {
                Text(role)
                  .font(.caption2)
                  .foregroundStyle(.white.opacity(0.6))
                  .lineLimit(1)
                  .frame(width: 68)
              }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(person.role.flatMap { $0.isEmpty ? nil : "\(person.name), \($0)" } ?? person.name)
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Data

  private func load() async {
    guard !isLoading else { return }
    // Clear detail only after confirming we will actually start a load — avoids
    // a blank header flash when the guard exits early (TASK-425).
    detail = nil
    if appState.isDemoMode {
      detail = DemoData.detail(for: itemID)
      return
    }
    error = nil
    isLoading = true
    defer { isLoading = false }

    do {
      detail = try await appState.api.itemDetail(id: itemID)
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Unknown error."
    }
  }

  private func startDownload() async {
    guard !isStartingDownload else { return }
    isStartingDownload = true
    defer { isStartingDownload = false }

    do {
      // Get playback info to get the video URL
      let info = try await appState.api.playback(id: itemID)
      guard let videoURL = info.streamUrl ?? info.hlsMasterUrl else {
        self.downloadError = "No playable URL available for download."
        return
      }

      // Get poster URL if available
      var posterURL: URL? = nil
      if let posterId = detail?.images.poster.id {
        posterURL = appState.api.imageURL(id: posterId, width: 400)
      }

      downloadManager.startDownload(
        itemId: itemID,
        title: detail?.title ?? fallbackTitle,
        year: detail?.year,
        videoURL: videoURL,
        posterURL: posterURL,
        token: appState.sessionToken,
        durationSeconds: detail?.durationSeconds ?? 0
      )
    } catch {
      let message = (error as? APIError)?.userMessage
        ?? error.localizedDescription
      self.downloadError = message
    }
  }
}

// MARK: - Metadata Fixer Sheet

#if !os(tvOS)
private struct MetadataFixerSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let itemID: String
  let initialQuery: String
  let onApplied: () -> Void

  @State private var searchQuery: String
  @State private var results: [TMDbCandidate] = []
  @State private var isSearching = false
  @State private var isApplying = false
  @State private var error: String?
  @State private var applied = false

  init(itemID: String, initialQuery: String, onApplied: @escaping () -> Void) {
    self.itemID = itemID
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
          ForEach(results) { candidate in
            Button {
              Task { await apply(candidate) }
            } label: {
              HStack(spacing: 12) {
                AsyncImage(url: candidate.posterURL) { img in
                  img.resizable().scaledToFill()
                } placeholder: {
                  Color(white: 0.15)
                }
                .frame(width: 50, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                  Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                  if let year = candidate.year {
                    Text(String(year))
                      .font(.caption)
                      .foregroundStyle(.secondary)
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
        if applied {
          Text("Metadata updated! Pull to refresh.")
            .foregroundStyle(.green)
            .font(.caption)
            .listRowBackground(Color(white: 0.08))
        }
      }
      .navigationTitle("Fix Metadata")
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
    }
  }

  private func search() async {
    guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    isSearching = true
    error = nil
    defer { isSearching = false }
    do {
      let resp = try await appState.api.tmdbSearch(itemId: itemID, query: searchQuery)
      results = resp.results
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Search failed."
    }
  }

  private func apply(_ candidate: TMDbCandidate) async {
    isApplying = true
    defer { isApplying = false }
    do {
      try await appState.api.tmdbFix(itemId: itemID, tmdbId: candidate.tmdbId, type: candidate.type)
      applied = true
      onApplied()
      dismiss()
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Failed to apply."
    }
  }
}
#endif

// MARK: - Metadata Pill

private struct MetadataPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.weight(.medium))
      .foregroundStyle(.white.opacity(0.85))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color(white: 0.16))
      .clipShape(Capsule())
  }
}

// MARK: - Player Sheet

private struct PlayerSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  let itemID: String
  let title: String
  var itemYear: Int? = nil
  var nextEpisode: ItemSummary? = nil
  var onPlayNextEpisode: (() -> Void)? = nil
  var onGoToShow: (() -> Void)? = nil

  @State private var playbackURL: URL?
  @State private var error: String?
  @State private var resumePosition: Double = 0
  @State private var isOffline: Bool = false
  @State private var chapters: [Chapter] = []
  @State private var subtitleOffset: Double = 0
  @State private var subtitleOffsetRestartTask: Task<Void, Never>? = nil

  // Progress sync debouncing
  @State private var lastSyncTime: Date = .distantPast
  @State private var lastSyncedPosition: Int = 0
  @State private var lastKnownDuration: Int = 0
  private let syncInterval: TimeInterval = 10  // Sync at most every 10 seconds
  private let seekThreshold: Int = 15  // Or if position changes by 15+ seconds (seek)

  // Autoplay next episode
  @State private var showNextEpisodeOverlay: Bool = false
  @State private var nextEpisodeCountdown: Int = 5
  @State private var countdownTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let url = playbackURL {
        GestureVideoPlayer(
          url: url,
          title: title,
          resumePosition: resumePosition,
          chapters: chapters,
          itemID: itemID,
          itemTitle: title,
          itemYear: itemYear,
          usesTunnelCookie: appState.api.usesTunnelCookie,
          onDismiss: {
            // Guard: if user dismissed before video started or position/duration are
            // unknown, skip setProgress entirely — must not overwrite real saved progress
            // with 0/0 on instant dismiss (P2-3).
            guard lastSyncedPosition > 0 && lastKnownDuration > 0 else {
              dismiss()
              return
            }
            if isOffline {
              // Persist final position locally for resume-on-reopen
              DownloadManager.shared.updateResumePosition(
                itemId: itemID,
                positionSeconds: lastSyncedPosition
              )
            }
            // Route through appState.recordProgress so LocalStore is updated (TASK-361).
            // Task is unavoidable here since onDismiss is a sync closure.
            let positionAtDismiss = lastSyncedPosition
            let durationAtDismiss = lastKnownDuration
            Task {
              await appState.recordProgress(
                itemId: itemID,
                positionSeconds: positionAtDismiss,
                durationSeconds: durationAtDismiss
              )
            }
            dismiss()
          },
          onProgressUpdate: { position, duration in
            let positionInt = Int(position)
            let durationInt = Int(duration)
            guard durationInt > 0 else { return }
            lastKnownDuration = durationInt

            let now = Date()
            let timeSinceLastSync = now.timeIntervalSince(lastSyncTime)
            let positionDelta = abs(positionInt - lastSyncedPosition)

            // Only sync if: enough time has passed OR user seeked significantly
            guard timeSinceLastSync >= syncInterval || positionDelta >= seekThreshold else {
              return
            }

            lastSyncTime = now
            lastSyncedPosition = positionInt

            if isOffline {
              // Persist position locally for resume-on-reopen
              DownloadManager.shared.updateResumePosition(
                itemId: itemID,
                positionSeconds: positionInt
              )
            }
            // Route through appState.recordProgress so LocalStore is updated (TASK-361).
            Task {
              await appState.recordProgress(
                itemId: itemID,
                positionSeconds: positionInt,
                durationSeconds: durationInt
              )
            }
          },
          onPlaybackFailed: {
            // Reset and re-fetch a fresh playback URL. Handles stale HLS sessions
            // (e.g. server restart clears in-memory sessions, causing 404 on stream).
            playbackURL = nil
            Task { await start() }
          },
          onPlaybackFinished: {
            guard nextEpisode != nil, onPlayNextEpisode != nil else { return }
            showNextEpisodeOverlay = true
            nextEpisodeCountdown = 5
            countdownTask?.cancel()
            countdownTask = Task { @MainActor in
              for remaining in stride(from: 5, through: 0, by: -1) {
                guard !Task.isCancelled else { return }
                nextEpisodeCountdown = remaining
                if remaining == 0 {
                  showNextEpisodeOverlay = false
                  onPlayNextEpisode?()
                  dismiss()
                  return
                }
                try? await Task.sleep(for: .seconds(1))
              }
            }
          },
          onSubtitleOffsetChange: { offset in
            subtitleOffset = offset
            subtitleOffsetRestartTask?.cancel()
            subtitleOffsetRestartTask = Task {
              try? await Task.sleep(for: .milliseconds(500))
              guard !Task.isCancelled else { return }
              playbackURL = nil
              await start()
            }
          },
          onGoToShow: onGoToShow
        )
        .ignoresSafeArea()

        if showNextEpisodeOverlay, let next = nextEpisode {
          nextEpisodeOverlay(next: next)
        }
      } else if let error {
        VStack(spacing: 20) {
          ContentUnavailableView("Playback failed", systemImage: "exclamationmark.triangle", description: Text(error))
            .foregroundStyle(.white)
          Button("Dismiss") { dismiss() }
            .buttonStyle(.borderedProminent)
        }
      } else {
        VStack(spacing: 20) {
          ProgressView("Loading video")
            .tint(.white)
          Button("Cancel") { dismiss() }
            .foregroundStyle(.white.opacity(0.7))
        }
      }
    }
    .task { await start() }
    .onDisappear {
      // FIX-12: Cancel countdown when player is dismissed via system back gesture or swipe-to-dismiss.
      // Without this, the Task continues running against a deallocated binding and fires
      // onPlayNextEpisode into a dismissed view, causing a navigation no-op and potential crash.
      countdownTask?.cancel()
      countdownTask = nil
    }
    .onChange(of: scenePhase) { _, newPhase in
      // TASK-270: flush pending progress when app goes to background so force-kill
      // doesn't lose the last known position.
      if newPhase == .background, lastSyncedPosition > 0, lastKnownDuration > 0 {
        let pos = lastSyncedPosition
        let dur = lastKnownDuration
        if isOffline {
          DownloadManager.shared.updateResumePosition(itemId: itemID, positionSeconds: pos)
        }
        Task {
          await appState.recordProgress(itemId: itemID, positionSeconds: pos, durationSeconds: dur)
        }
      }
    }
  }

  @ViewBuilder
  private func nextEpisodeOverlay(next: ItemSummary) -> some View {
    VStack(spacing: 20) {
      Spacer()
      VStack(spacing: 12) {
        Text("Up Next")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.7))
          .textCase(.uppercase)
        Text(next.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .lineLimit(2)
        Text("Playing in \(nextEpisodeCountdown)s")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.7))
          .monospacedDigit()
        HStack(spacing: 16) {
          Button {
            countdownTask?.cancel()
            showNextEpisodeOverlay = false
            onPlayNextEpisode?()
            dismiss()
          } label: {
            Text("Play Now")
              .font(.headline)
              .foregroundStyle(.white)
              .padding(.horizontal, 24)
              .padding(.vertical, 10)
              .background(Color.dsAccent, in: Capsule())
          }
          .buttonStyle(.plain)
          Button {
            countdownTask?.cancel()
            showNextEpisodeOverlay = false
          } label: {
            Text("Cancel")
              .font(.headline)
              .foregroundStyle(.white)
              .padding(.horizontal, 24)
              .padding(.vertical, 10)
              .background(Color.white.opacity(0.2), in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(28)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
      .padding(.horizontal, 32)
      .padding(.bottom, 60)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.45).ignoresSafeArea())
    .transition(.opacity)
    .animation(.easeInOut(duration: 0.25), value: showNextEpisodeOverlay)
  }

  private func start() async {
    // Reset state for retry — ensures stale duration/position from a prior attempt
    // can't suppress the final progress write on the next dismiss (TASK-401).
    lastKnownDuration = 0
    lastSyncedPosition = 0
    isOffline = false

    // Demo mode — play the bundled royalty-free sample video (Big Buck Bunny,
    // Blender Foundation, CC BY 3.0) instead of hitting the server.
    if appState.isDemoMode {
      if let demoURL = Bundle.main.url(forResource: "demo_video", withExtension: "mp4") {
        playbackURL = demoURL
      } else {
        error = "Demo video not found."
      }
      return
    }

    // Check if we have a downloaded version first
    if let downloaded = DownloadManager.shared.getDownloadedItem(itemId: itemID) {
      let localURL = URL(fileURLWithPath: downloaded.videoPath)
      if FileManager.default.fileExists(atPath: downloaded.videoPath) {
        isOffline = true
        resumePosition = Double(downloaded.resumePositionSeconds)
        playbackURL = localURL
        return
      }
    }

    // Fall back to streaming
    do {
      let info = try await appState.api.playback(id: itemID, quality: appState.qualityCap, subtitleOffset: subtitleOffset)
      let url = info.streamUrl ?? info.hlsMasterUrl
      guard let url else {
        error = "No playable URL."
        return
      }
      resumePosition = Double(info.resumePositionSeconds)
      chapters = info.chapters ?? []
      playbackURL = url
    } catch {
      appState.handleConnectionFailure(error)
      // If this was a network failure and the server is a QuickConnect ID,
      // try re-resolving candidates (network context may have changed since login).
      if appState.serverUnreachable, await appState.reconnect() {
        do {
          let info = try await appState.api.playback(id: itemID, quality: appState.qualityCap, subtitleOffset: subtitleOffset)
          let url = info.streamUrl ?? info.hlsMasterUrl
          guard let url else { self.error = "No playable URL."; return }
          resumePosition = Double(info.resumePositionSeconds)
          chapters = info.chapters ?? []
          playbackURL = url
          appState.clearNetworkError()
          return
        } catch {
          appState.handleConnectionFailure(error)
        }
      }
      self.error = (error as? APIError)?.userMessage ?? "Couldn't connect to server."
    }
  }
}
