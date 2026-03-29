import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

struct DownloadedItem: Identifiable, Codable {
  let id: String
  let title: String
  let year: Int?
  let videoPath: String
  let posterPath: String?
  let fileSize: Int64
  let downloadedAt: Date
  var resumePositionSeconds: Int
  var durationSeconds: Int

  // Explicit memberwise init — callers can omit resumePositionSeconds and durationSeconds (both default to 0).
  init(
    id: String,
    title: String,
    year: Int?,
    videoPath: String,
    posterPath: String?,
    fileSize: Int64,
    downloadedAt: Date,
    resumePositionSeconds: Int = 0,
    durationSeconds: Int = 0
  ) {
    self.id = id
    self.title = title
    self.year = year
    self.videoPath = videoPath
    self.posterPath = posterPath
    self.fileSize = fileSize
    self.downloadedAt = downloadedAt
    self.resumePositionSeconds = resumePositionSeconds
    self.durationSeconds = durationSeconds
  }

  // Custom Decodable init for migration: existing persisted JSON may lack newer fields;
  // fall back to 0 if any key is absent rather than throwing keyNotFound.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    year = try c.decodeIfPresent(Int.self, forKey: .year)
    videoPath = try c.decode(String.self, forKey: .videoPath)
    posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
    fileSize = try c.decode(Int64.self, forKey: .fileSize)
    downloadedAt = try c.decode(Date.self, forKey: .downloadedAt)
    resumePositionSeconds = (try c.decodeIfPresent(Int.self, forKey: .resumePositionSeconds)) ?? 0
    durationSeconds = (try c.decodeIfPresent(Int.self, forKey: .durationSeconds)) ?? 0
  }
}

struct ActiveDownload: Identifiable {
  let id: String
  let title: String
  let progress: Double
  let task: URLSessionDownloadTask
}

@MainActor
@Observable
final class DownloadManager: NSObject {
  static let shared = DownloadManager()

  private(set) var activeDownloads: [String: ActiveDownload] = [:]
  private(set) var downloadProgress: [String: Double] = [:]
  /// In-memory map of itemId → resume data blob for paused downloads.
  private(set) var pausedDownloads: [String: Data] = [:]

  private var backgroundSession: URLSession!
  private var downloadTasks: [URLSessionDownloadTask: String] = [:]
  private var pendingDownloadInfo: [String: (title: String, year: Int?, posterURL: URL?, durationSeconds: Int, token: String?, videoURL: URL?)] = [:]

  private let storageKey = "dsReel.downloadedItems"
  private let resumeDataKey = "dsReel.resumeData"
  /// Persists minimal metadata for paused downloads across app launches.
  private let pausedMetaKey = "dsReel.pausedMeta"
  private var cachedDownloadedItems: [DownloadedItem]?

  override private init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: "com.heiloprojects.dsreel.downloads")
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
    loadPersistedResumeData()
  }

  // MARK: - Public API

  func startDownload(
    itemId: String,
    title: String,
    year: Int?,
    videoURL: URL,
    posterURL: URL?,
    token: String?,
    durationSeconds: Int = 0
  ) {
    guard activeDownloads[itemId] == nil else { return }
    guard !isDownloaded(itemId: itemId) else { return }

    var request = URLRequest(url: videoURL)
    // Video Station embeds the SID as a `_sid=` query parameter in the URL itself.
    // In that case no Authorization header is needed — the credential is already in the URL.
    // For the REST API backend, attach the Bearer token as a header.
    if !videoURL.absoluteString.contains("_sid="), let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let task = backgroundSession.downloadTask(with: request)
    downloadTasks[task] = itemId
    pendingDownloadInfo[itemId] = (title: title, year: year, posterURL: posterURL, durationSeconds: durationSeconds, token: token, videoURL: videoURL)

    let download = ActiveDownload(id: itemId, title: title, progress: 0, task: task)
    activeDownloads[itemId] = download
    downloadProgress[itemId] = 0

    task.resume()
  }

  func cancelDownload(itemId: String) {
    // Cancel an active download if present
    if let download = activeDownloads[itemId] {
      download.task.cancel()
      downloadTasks.removeValue(forKey: download.task)
      activeDownloads.removeValue(forKey: itemId)
      downloadProgress.removeValue(forKey: itemId)
    }
    // Clean up all state regardless of whether download was active or paused
    pendingDownloadInfo.removeValue(forKey: itemId)
    pausedDownloads.removeValue(forKey: itemId)
    removePersistedResumeData(for: itemId)
  }

  func deleteDownload(itemId: String) {
    var items = getDownloadedItems()
    guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }

    let item = items[index]

    // Delete files
    let fm = FileManager.default
    try? fm.removeItem(atPath: item.videoPath)
    if let posterPath = item.posterPath {
      try? fm.removeItem(atPath: posterPath)
    }

    items.remove(at: index)
    saveDownloadedItems(items)
    cachedDownloadedItems = nil
    // Clear any resume data that might be lingering
    pausedDownloads.removeValue(forKey: itemId)
    removePersistedResumeData(for: itemId)
  }

  func isDownloaded(itemId: String) -> Bool {
    getDownloadedItems().contains { $0.id == itemId }
  }

  func isDownloading(itemId: String) -> Bool {
    activeDownloads[itemId] != nil
  }

  func isPaused(itemId: String) -> Bool {
    pausedDownloads[itemId] != nil
  }

  /// Returns the display title for a paused download (sourced from pendingDownloadInfo).
  func pausedDownloadTitle(itemId: String) -> String? {
    pendingDownloadInfo[itemId]?.title
  }

  /// Pause an active download, capturing resume data so it can be continued later.
  /// Async: awaits the resume-data callback before returning so callers know the pause is complete.
  func pauseDownload(itemId: String) async {
    guard let download = activeDownloads[itemId] else { return }

    let resumeData: Data? = await withCheckedContinuation { continuation in
      download.task.cancel(byProducingResumeData: { data in
        continuation.resume(returning: data)
      })
    }

    // Now back on @MainActor — update state with the resume data
    downloadTasks.removeValue(forKey: download.task)
    activeDownloads.removeValue(forKey: itemId)
    downloadProgress.removeValue(forKey: itemId)
    // Store resume data (keep pendingDownloadInfo so metadata is available for resume)
    if let data = resumeData {
      pausedDownloads[itemId] = data
      persistResumeData(data, for: itemId)
      persistPausedMeta(for: itemId)
    }
  }

  /// Resume a previously paused download.
  /// If resume data is available (happy path), resumes from where it left off.
  /// If resume data was lost after relaunch but the video URL was persisted, starts a fresh download.
  /// If neither is available, sets an error state on the item.
  func resumeDownload(itemId: String) {
    guard let info = pendingDownloadInfo[itemId] else { return }
    guard activeDownloads[itemId] == nil else { return } // already active

    if let resumeData = pausedDownloads[itemId] {
      // Resume with saved data
      let task = backgroundSession.downloadTask(withResumeData: resumeData)
      downloadTasks[task] = itemId
      let download = ActiveDownload(
        id: itemId,
        title: info.title,
        progress: downloadProgress[itemId] ?? 0,
        task: task
      )
      activeDownloads[itemId] = download
      // Clear the paused state
      pausedDownloads.removeValue(forKey: itemId)
      removePersistedResumeData(for: itemId)
      task.resume()
    } else if let videoURL = info.videoURL {
      // Resume data was lost (e.g. app was force-quit), but we have the original URL.
      // Clear paused state and restart from the beginning.
      pendingDownloadInfo.removeValue(forKey: itemId)
      removePersistedResumeData(for: itemId)
      startDownload(
        itemId: itemId,
        title: info.title,
        year: info.year,
        videoURL: videoURL,
        posterURL: info.posterURL,
        token: info.token,
        durationSeconds: info.durationSeconds
      )
    } else {
      // Neither resume data nor video URL available — cannot resume.
      // Clear orphaned metadata and surface an error by removing paused state.
      pendingDownloadInfo.removeValue(forKey: itemId)
      pausedDownloads.removeValue(forKey: itemId)
      removePersistedResumeData(for: itemId)
    }
  }

  func getDownloadedItems() -> [DownloadedItem] {
    if let cached = cachedDownloadedItems { return cached }

    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let items = try? JSONDecoder().decode([DownloadedItem].self, from: data) else {
      return []
    }
    let dir = downloadsDirectory()
    // Resolve stored videoPath: new items store a filename only; legacy items store an absolute path.
    // For legacy absolute paths that no longer exist (stale after app update), attempt recovery by
    // filename inside the current Downloads directory.
    let resolved = items.compactMap { item -> DownloadedItem? in
      let resolvedPath: String
      if item.videoPath.hasPrefix("/") {
        // Legacy absolute path — use as-is if it still exists, otherwise try filename recovery
        if FileManager.default.fileExists(atPath: item.videoPath) {
          resolvedPath = item.videoPath
        } else {
          let recovered = dir.appendingPathComponent(URL(fileURLWithPath: item.videoPath).lastPathComponent).path
          guard FileManager.default.fileExists(atPath: recovered) else { return nil }
          resolvedPath = recovered
        }
      } else {
        // New format: filename only — reconstruct full path
        resolvedPath = dir.appendingPathComponent(item.videoPath).path
        guard FileManager.default.fileExists(atPath: resolvedPath) else { return nil }
      }
      // Resolve posterPath: same filename-only / absolute-path logic as videoPath.
      let resolvedPosterPath: String?
      if let pp = item.posterPath {
        if pp.hasPrefix("/") {
          resolvedPosterPath = FileManager.default.fileExists(atPath: pp) ? pp : nil
        } else {
          let full = dir.appendingPathComponent(pp).path
          resolvedPosterPath = FileManager.default.fileExists(atPath: full) ? full : nil
        }
      } else {
        resolvedPosterPath = nil
      }

      // Return item with the resolved full paths for callers that use them directly
      return DownloadedItem(
        id: item.id,
        title: item.title,
        year: item.year,
        videoPath: resolvedPath,
        posterPath: resolvedPosterPath,
        fileSize: item.fileSize,
        downloadedAt: item.downloadedAt,
        resumePositionSeconds: item.resumePositionSeconds,
        durationSeconds: item.durationSeconds
      )
    }
    cachedDownloadedItems = resolved
    return resolved
  }

  func getDownloadedItem(itemId: String) -> DownloadedItem? {
    getDownloadedItems().first { $0.id == itemId }
  }

  /// Persists the current playback position for an offline item.
  /// Called periodically during playback (same debounce cadence as the online API sync)
  /// and once more on player dismiss.
  func updateResumePosition(itemId: String, positionSeconds: Int) {
    // Read raw items directly from UserDefaults to preserve the filename-only storage invariant.
    // Using getDownloadedItems() would resolve absolute paths and write them back, undoing the fix.
    guard let rawData = UserDefaults.standard.data(forKey: storageKey),
          var rawItems = try? JSONDecoder().decode([DownloadedItem].self, from: rawData),
          let index = rawItems.firstIndex(where: { $0.id == itemId }) else { return }
    rawItems[index].resumePositionSeconds = positionSeconds
    saveDownloadedItems(rawItems)
    cachedDownloadedItems = nil
  }

  // MARK: - Private

  // MARK: Resume Data Persistence

  /// Returns the filesystem URL for the resume data file of a given item.
  /// Resume data blobs can be multi-MB and must NOT be stored in UserDefaults.
  private func resumeDataFileURL(for itemId: String) -> URL {
    downloadsDirectory().appendingPathComponent("\(itemId).resumedata")
  }

  /// Load persisted resume data blobs (from disk) and paused item metadata (from UserDefaults).
  private func loadPersistedResumeData() {
    // Migrate legacy base64 blobs from UserDefaults to disk, then clear them.
    if let raw = UserDefaults.standard.dictionary(forKey: resumeDataKey) as? [String: String] {
      for (itemId, base64) in raw {
        if let data = Data(base64Encoded: base64) {
          try? data.write(to: resumeDataFileURL(for: itemId), options: .atomic)
          pausedDownloads[itemId] = data
        }
      }
      UserDefaults.standard.removeObject(forKey: resumeDataKey)
    }
    // Load resume data from disk files tracked in pausedMeta
    if let raw = UserDefaults.standard.dictionary(forKey: pausedMetaKey) as? [String: [String: String]] {
      for (itemId, _) in raw {
        if let data = try? Data(contentsOf: resumeDataFileURL(for: itemId)) {
          pausedDownloads[itemId] = data
        }
      }
    }
    // Restore minimal pendingDownloadInfo so paused items remain resumable after app launch
    if let raw = UserDefaults.standard.dictionary(forKey: pausedMetaKey) as? [String: [String: String]] {
      for (itemId, meta) in raw {
        let title = meta["title"] ?? itemId
        let year = meta["year"].flatMap { Int($0) }
        let posterURL = meta["posterURL"].flatMap { URL(string: $0) }
        let durationSeconds = meta["durationSeconds"].flatMap { Int($0) } ?? 0
        let videoURL = meta["videoURL"].flatMap { URL(string: $0) }
        // Restore if we have resume data OR a video URL (to allow fresh-start resume)
        if pausedDownloads[itemId] != nil || videoURL != nil {
          pendingDownloadInfo[itemId] = (title: title, year: year, posterURL: posterURL, durationSeconds: durationSeconds, token: nil, videoURL: videoURL)
        }
      }
    }
  }

  /// Persist resume data blob to a file in the Downloads directory.
  private func persistResumeData(_ data: Data, for itemId: String) {
    try? data.write(to: resumeDataFileURL(for: itemId), options: .atomic)
  }

  /// Persist minimal metadata for a paused download so it can be displayed and resumed after app relaunch.
  /// Stores the video URL so resumeDownload can fall back to a fresh startDownload if resume data is lost.
  private func persistPausedMeta(for itemId: String) {
    guard let info = pendingDownloadInfo[itemId] else { return }
    var store = (UserDefaults.standard.dictionary(forKey: pausedMetaKey) as? [String: [String: String]]) ?? [:]
    var meta: [String: String] = ["title": info.title]
    if let year = info.year { meta["year"] = "\(year)" }
    if let posterURL = info.posterURL { meta["posterURL"] = posterURL.absoluteString }
    if let videoURL = info.videoURL { meta["videoURL"] = videoURL.absoluteString }
    meta["durationSeconds"] = "\(info.durationSeconds)"
    store[itemId] = meta
    UserDefaults.standard.set(store, forKey: pausedMetaKey)
  }

  /// Remove a single item's resume data file and paused metadata from UserDefaults.
  private func removePersistedResumeData(for itemId: String) {
    try? FileManager.default.removeItem(at: resumeDataFileURL(for: itemId))
    if var store = UserDefaults.standard.dictionary(forKey: pausedMetaKey) as? [String: [String: String]] {
      store.removeValue(forKey: itemId)
      UserDefaults.standard.set(store, forKey: pausedMetaKey)
    }
  }

  private func saveDownloadedItems(_ items: [DownloadedItem]) {
    guard let data = try? JSONEncoder().encode(items) else { return }
    UserDefaults.standard.set(data, forKey: storageKey)
  }

  private func downloadsDirectory() -> URL {
    let fm = FileManager.default
    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func completeDownload(itemId: String, tempURL: URL) {
    guard let info = pendingDownloadInfo[itemId] else { return }

    let dir = downloadsDirectory()
    let videoFilename = "\(itemId).mp4"
    let videoPath = dir.appendingPathComponent(videoFilename)

    let fm = FileManager.default
    try? fm.removeItem(at: videoPath)

    do {
      try fm.moveItem(at: tempURL, to: videoPath)
    } catch {
      try? fm.removeItem(at: tempURL)
      activeDownloads.removeValue(forKey: itemId)
      downloadProgress.removeValue(forKey: itemId)
      pendingDownloadInfo.removeValue(forKey: itemId)
      return
    }

    let fileSize = (try? fm.attributesOfItem(atPath: videoPath.path)[.size] as? Int64) ?? 0

    // Save the item immediately with no poster; the async poster fetch below will update it.
    let item = DownloadedItem(
      id: itemId,
      title: info.title,
      year: info.year,
      videoPath: videoFilename,   // Store filename only — avoids stale absolute paths after app updates
      posterPath: nil,
      fileSize: fileSize,
      downloadedAt: Date(),
      durationSeconds: info.durationSeconds
    )

    // Read raw items from UserDefaults to preserve filename-only storage invariant,
    // then insert the new item (which already uses filename-only videoPath).
    let rawItems: [DownloadedItem]
    if let rawData = UserDefaults.standard.data(forKey: storageKey),
       let decoded = try? JSONDecoder().decode([DownloadedItem].self, from: rawData) {
      rawItems = decoded
    } else {
      rawItems = []
    }
    var updatedItems = rawItems
    updatedItems.insert(item, at: 0)
    saveDownloadedItems(updatedItems)
    cachedDownloadedItems = nil

    activeDownloads.removeValue(forKey: itemId)
    downloadProgress.removeValue(forKey: itemId)
    pendingDownloadInfo.removeValue(forKey: itemId)

    // Fetch poster image asynchronously and update the stored item once done.
    guard let posterURL = info.posterURL else { return }
    let posterFilename = "\(itemId).poster.jpg"
    let posterDestination = dir.appendingPathComponent(posterFilename)

    Task {
      var req = URLRequest(url: posterURL)
      if let tok = info.token {
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
      }

      do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              !data.isEmpty else {
          let status = (response as? HTTPURLResponse)?.statusCode ?? -1
          print("[DownloadManager] Poster fetch failed: HTTP \(status) for \(posterURL)")
          return
        }

        try data.write(to: posterDestination, options: .atomic)

        // Update the persisted item with the poster path (filename only).
        // Read raw from UserDefaults to preserve the filename-only videoPath invariant.
        await MainActor.run {
          let key = self.storageKey
          guard let rawData = UserDefaults.standard.data(forKey: key),
                var rawItems = try? JSONDecoder().decode([DownloadedItem].self, from: rawData),
                let idx = rawItems.firstIndex(where: { $0.id == itemId }) else { return }
          rawItems[idx] = DownloadedItem(
            id: rawItems[idx].id,
            title: rawItems[idx].title,
            year: rawItems[idx].year,
            videoPath: rawItems[idx].videoPath,
            posterPath: posterFilename,
            fileSize: rawItems[idx].fileSize,
            downloadedAt: rawItems[idx].downloadedAt,
            resumePositionSeconds: rawItems[idx].resumePositionSeconds,
            durationSeconds: rawItems[idx].durationSeconds
          )
          if let updated = try? JSONEncoder().encode(rawItems) {
            UserDefaults.standard.set(updated, forKey: key)
          }
          // Invalidate in-memory cache so next read resolves fresh from disk.
          self.cachedDownloadedItems = nil
        }
      } catch {
        // Poster fetch failed — item remains playable without a poster thumbnail.
      }
    }
  }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // URLSession calls delegates on the OperationQueue supplied at init (a background queue, NOT main).
    // We must hop to @MainActor for all state mutations — hence the Task { @MainActor in } pattern.
    // The temp file at `location` is only valid for the duration of this synchronous call.
    // Copy it before returning so we have a stable path for the move in completeDownload.
    let stableCopy = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel_dl_\(UUID().uuidString).tmp")
    do {
      try FileManager.default.copyItem(at: location, to: stableCopy)
    } catch {
      return // Nothing we can do — temp file couldn't be preserved
    }
    Task { @MainActor in
      guard let itemId = downloadTasks[downloadTask] else {
        try? FileManager.default.removeItem(at: stableCopy)
        return
      }
      downloadTasks.removeValue(forKey: downloadTask)
      completeDownload(itemId: itemId, tempURL: stableCopy)
    }
  }

  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    Task { @MainActor in
      guard let itemId = downloadTasks[downloadTask] else { return }
      let progress = totalBytesExpectedToWrite > 0
        ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        : 0
      downloadProgress[itemId] = progress
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let downloadTask = task as? URLSessionDownloadTask else { return }
    // Extract resume data from the error userInfo before crossing into MainActor context
    let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    Task { @MainActor in
      guard let itemId = downloadTasks[downloadTask] else { return }
      if let error {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled, let data = resumeData {
          // Download was paused (cancel with resume data) — save resume data, leave pendingDownloadInfo intact
          pausedDownloads[itemId] = data
          persistResumeData(data, for: itemId)
          persistPausedMeta(for: itemId)
        }
        // Always clean up active state on any error/cancellation
        activeDownloads.removeValue(forKey: itemId)
        downloadProgress.removeValue(forKey: itemId)
        downloadTasks.removeValue(forKey: downloadTask)
        // Note: pendingDownloadInfo is intentionally kept when pausing so resumeDownload can access it
        if nsError.code != NSURLErrorCancelled || resumeData == nil {
          // Genuine failure (not a pause) — clean up pendingDownloadInfo too
          pendingDownloadInfo.removeValue(forKey: itemId)
        }
      }
    }
  }
}
