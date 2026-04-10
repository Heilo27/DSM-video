import AVKit
import SwiftUI

struct ItemDetailView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var downloadManager = DownloadManager.shared
  let itemID: String
  let fallbackTitle: String
  var nextEpisode: ItemSummary? = nil
  var onNextEpisode: (() -> Void)? = nil

  @State private var detail: ItemDetail?
  @State private var isLoading: Bool = false
  @State private var error: String?

  @State private var showPlayer: Bool = false
  @State private var isStartingDownload: Bool = false
  @State private var showMetadataFixer: Bool = false

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
            #endif
          }

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
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(detail?.title ?? fallbackTitle)
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarBackground(Color.black.opacity(0.85), for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    #endif
    .task(id: itemID) { await load() }
    .fullScreenCover(isPresented: $showPlayer) {
      PlayerSheet(itemID: itemID, title: detail?.title ?? fallbackTitle)
        .environment(appState)
        #if !os(tvOS)
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
    }
    #if !os(tvOS)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Fix Metadata", systemImage: "magnifyingglass") {
            showMetadataFixer = true
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
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
    return horizontalSizeClass == .regular ? 420 : 300
    #endif
  }

  @ViewBuilder
  private var header: some View {
    if isLoading && detail == nil {
      Color.black
        .frame(maxWidth: .infinity, minHeight: backdropHeight)
        .overlay(ProgressView("Loading").tint(.white))
    } else if let error {
      Color.black
        .frame(maxWidth: .infinity, minHeight: backdropHeight)
        .overlay(
          ContentUnavailableView(
            "Couldn't load details",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
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
                  .padding(.vertical, 16)
                  .background(Color.black.opacity(0.7))
                  .clipShape(Capsule())
              }
              .accessibilityLabel("No metadata. Fix metadata")
              .accessibilityHint("Opens metadata search to correct this item")
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

        // Floating title/year on gradient
        VStack(alignment: .leading, spacing: 4) {
          Text(detail?.title ?? fallbackTitle)
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)

          if let year = detail?.year {
            Text(String(year))
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.75))
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
      }
    }
  }

  @ViewBuilder
  private var backdropImage: some View {
    if let backdropId = detail?.images.backdrop.id ?? detail?.images.backdrop.mapperId {
      AuthenticatedImage(
        url: appState.api.imageURL(id: backdropId, width: 1200),
        token: appState.sessionToken
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

  // MARK: - Cast Section

  @ViewBuilder
  private func castSection(cast: [ItemDetail.Person]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Cast")
        .font(.headline)
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
        HStack {
          Text(person.name)
            .foregroundStyle(.white)
          Spacer()
          if let role = person.role, !role.isEmpty {
            Text(role)
              .foregroundStyle(.white.opacity(0.7))
          }
        }
        .font(.footnote)
      }
    }
  }

  // MARK: - Data

  private func load() async {
    detail = nil
    guard !isLoading else { return }
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
        self.error = "No playable URL available for download."
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
      self.error = message
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
            ProgressView().tint(.white)
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

  @State private var playbackURL: URL?
  @State private var error: String?
  @State private var resumePosition: Double = 0
  @State private var isOffline: Bool = false

  // Progress sync debouncing
  @State private var lastSyncTime: Date = .distantPast
  @State private var lastSyncedPosition: Int = 0
  @State private var lastKnownDuration: Int = 0
  private let syncInterval: TimeInterval = 10  // Sync at most every 10 seconds
  private let seekThreshold: Int = 15  // Or if position changes by 15+ seconds (seek)

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let url = playbackURL {
        GestureVideoPlayer(
          url: url,
          title: title,
          resumePosition: resumePosition,
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
              // Also sync to server so home rails (Continue Watching) reflect progress
              let positionAtDismiss = lastSyncedPosition
              let durationAtDismiss = lastKnownDuration
              Task {
                try? await appState.api.setProgress(
                  id: itemID,
                  positionSeconds: positionAtDismiss,
                  durationSeconds: durationAtDismiss
                )
              }
            } else {
              // Save final position to the server for online items.
              // Task is unavoidable here since onDismiss is a sync closure.
              // dismiss() has already been called by GestureVideoPlayer before this fires,
              // so we do NOT call dismiss() inside the Task.
              let positionAtDismiss = lastSyncedPosition
              let durationAtDismiss = lastKnownDuration
              Task {
                do {
                  try await appState.api.setProgress(
                    id: itemID,
                    positionSeconds: positionAtDismiss,
                    durationSeconds: durationAtDismiss
                  )
                } catch { }
              }
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
            // Always sync to server (online or offline) so home rails stay current
            Task {
              try? await appState.api.setProgress(
                id: itemID,
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
          }
        )
        .ignoresSafeArea()
      } else if let error {
        ContentUnavailableView("Playback failed", systemImage: "exclamationmark.triangle", description: Text(error))
          .foregroundStyle(.white)
      } else {
        ProgressView()
          .tint(.white)
      }
    }
    .task { await start() }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .background, lastSyncedPosition > 0 {
        let pos = lastSyncedPosition
        let dur = lastKnownDuration
        Task {
          try? await appState.api.setProgress(
            id: itemID,
            positionSeconds: pos,
            durationSeconds: dur
          )
        }
      }
    }
  }

  private func start() async {
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
      let info = try await appState.api.playback(id: itemID)
      let url = info.streamUrl ?? info.hlsMasterUrl
      guard let url else {
        error = "No playable URL."
        return
      }
      resumePosition = Double(info.resumePositionSeconds)
      playbackURL = url
    } catch {
      appState.handleConnectionFailure(error)
      self.error = (error as? APIError)?.userMessage ?? "Unknown error."
    }
  }
}
