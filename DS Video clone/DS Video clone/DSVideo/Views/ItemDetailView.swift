import AVKit
import SwiftUI

struct ItemDetailView: View {
  @Environment(AppState.self) private var appState
  private var downloadManager: DownloadManager { DownloadManager.shared }
  let itemID: String
  let fallbackTitle: String

  @State private var detail: ItemDetail?
  @State private var isLoading: Bool = false
  @State private var error: String?

  @State private var showPlayer: Bool = false
  @State private var isStartingDownload: Bool = false

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

          // Play button
          Button {
            showPlayer = true
          } label: {
            Label(isDownloaded ? "Play (Downloaded)" : "Play", systemImage: "play.fill")
              .font(.headline.weight(.semibold))
              #if os(tvOS)
              .frame(maxWidth: .infinity, minHeight: 80)
              #else
              .frame(maxWidth: .infinity, minHeight: 56)
              #endif
          }
          .background(DSReelBrandColor.background)
          .foregroundStyle(.white)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .shadow(color: DSReelBrandColor.background.opacity(0.45), radius: 8, x: 0, y: 4)
          .accessibilityLabel("Play \(detail?.title ?? fallbackTitle)")

          // Download button (iOS only — no persistent storage on tvOS)
          #if !os(tvOS)
          downloadSection
          #endif

          if let summary = detail?.summary, !summary.isEmpty {
            Text(summary)
              .font(.body)
              .foregroundStyle(.white.opacity(0.88))
              .fixedSize(horizontal: false, vertical: true)
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
        #endif
        .padding(.top, 16)
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(detail?.title ?? fallbackTitle)
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await load() }
    #if os(tvOS)
    .fullScreenCover(isPresented: $showPlayer) {
      PlayerSheet(itemID: itemID, title: detail?.title ?? fallbackTitle)
        .environment(appState)
    }
    #else
    .sheet(isPresented: $showPlayer) {
      PlayerSheet(itemID: itemID, title: detail?.title ?? fallbackTitle)
        .environment(appState)
    }
    #endif
  }

  // MARK: - Header

  @ViewBuilder
  private var header: some View {
    if isLoading && detail == nil {
      Color.black
        #if os(tvOS)
        .frame(maxWidth: .infinity, minHeight: 450)
        #else
        .frame(maxWidth: .infinity, minHeight: 230)
        #endif
        .overlay(ProgressView().tint(.white))
    } else if let error {
      Color.black
        #if os(tvOS)
        .frame(maxWidth: .infinity, minHeight: 450)
        #else
        .frame(maxWidth: .infinity, minHeight: 230)
        #endif
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
          #if os(tvOS)
          .frame(maxWidth: .infinity, minHeight: 450, maxHeight: 450)
          #else
          .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 230)
          #endif
          .clipped()

        // Gradient fade to black at bottom
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .black.opacity(0.6), location: 0.55),
            .init(color: .black, location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        #if os(tvOS)
        .frame(maxWidth: .infinity, minHeight: 450, maxHeight: 450)
        #else
        .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 230)
        #endif

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
    } else if let posterId = detail?.images.poster.id ?? detail?.id {
      AuthenticatedImage(
        url: appState.api.imageURL(id: posterId, width: 1200),
        token: appState.sessionToken
      )
      .scaledToFill()
    } else {
      Color(white: 0.06)
        .overlay(
          Image(systemName: "film.fill")
            .font(.system(size: 48))
            .foregroundStyle(.white.opacity(0.2))
            .accessibilityLabel("No poster available")
        )
    }
  }

  // MARK: - Metadata Pills

  @ViewBuilder
  private var metadataPills: some View {
    let year = detail?.year
    let rating = detail?.contentRating
    let genres = detail?.genres ?? []

    if year != nil || rating != nil || !genres.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          if let year {
            MetadataPill(text: String(year))
          }
          if let rating, !rating.isEmpty {
            MetadataPill(text: rating)
          }
          ForEach(genres, id: \.self) { genre in
            MetadataPill(text: genre)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  // MARK: - Download Section

  @ViewBuilder
  private var downloadSection: some View {
    if isDownloaded {
      Button(role: .destructive) {
        downloadManager.deleteDownload(itemId: itemID)
      } label: {
        Label("Remove Download", systemImage: "trash")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 52)
      }
      .background(Color(white: 0.14))
      .foregroundStyle(.red)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    } else if isDownloading {
      VStack(spacing: 8) {
        ProgressView(value: downloadProgress)
          .tint(DSReelBrandColor.background)
          .frame(height: 3)
          .scaleEffect(y: 1, anchor: .center)
        HStack {
          Text("Downloading... \(Int(downloadProgress * 100))%")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
          Spacer()
          Button("Cancel") {
            downloadManager.cancelDownload(itemId: itemID)
          }
          .font(.subheadline)
          .foregroundStyle(.red)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(Color(white: 0.10))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    } else {
      Button {
        Task { await startDownload() }
      } label: {
        if isStartingDownload {
          ProgressView()
            .tint(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
        } else {
          Label("Download", systemImage: "arrow.down.circle")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
      }
      .background(Color(white: 0.14))
      .foregroundStyle(.white)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .disabled(isStartingDownload)
    }
  }

  // MARK: - Cast Section

  @ViewBuilder
  private func castSection(cast: [ItemDetail.Person]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Cast")
        .font(.headline)
        .foregroundStyle(.white)
      ForEach(cast, id: \.self) { person in
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
    guard !isLoading else { return }
    error = nil
    isLoading = true
    defer { isLoading = false }

    do {
      detail = try await appState.api.itemDetail(id: itemID)
    } catch {
      self.error = (error as? WebAPIError)?.userMessage ?? (error as? APIError)?.userMessage ?? "Unknown error."
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
        token: appState.sessionToken
      )
    } catch {
      // Download failed to start
    }
  }
}

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
            // Save final position on dismiss (only if online)
            if !isOffline {
              Task {
                try? await appState.api.setProgress(
                  id: itemID,
                  positionSeconds: lastSyncedPosition,
                  durationSeconds: lastKnownDuration
                )
              }
            }
            dismiss()
          },
          onProgressUpdate: { position, duration in
            // Skip progress sync if playing offline
            guard !isOffline else { return }

            // Debounced progress sync
            let positionInt = Int(position)
            let durationInt = Int(duration)
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

            Task {
              try? await appState.api.setProgress(
                id: itemID,
                positionSeconds: positionInt,
                durationSeconds: durationInt
              )
            }
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
  }

  private func start() async {
    // Check if we have a downloaded version first
    if let downloaded = DownloadManager.shared.getDownloadedItem(itemId: itemID) {
      let localURL = URL(fileURLWithPath: downloaded.videoPath)
      if FileManager.default.fileExists(atPath: downloaded.videoPath) {
        isOffline = true
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
      self.error = (error as? WebAPIError)?.userMessage ?? (error as? APIError)?.userMessage ?? "Unknown error."
    }
  }
}
