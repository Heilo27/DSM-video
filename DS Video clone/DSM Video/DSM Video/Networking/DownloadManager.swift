import Foundation
import Observation
import os.log
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

/// TASK-782: surfaces a genuine (non-pause) download failure to the UI so the row
/// shows "Download failed" + a retry/dismiss affordance instead of silently vanishing.
struct FailedDownload: Identifiable {
  let id: String
  let title: String
  /// Enough context to re-issue the download without the caller re-resolving the URL.
  let videoURL: URL?
  let posterURL: URL?
  let token: String?
  let year: Int?
  let durationSeconds: Int
  /// Permanent failures (e.g. disk full) can't be retried by a network retry — tell the user.
  let isPermanent: Bool
  let message: String
}

@MainActor
@Observable
final class DownloadManager: NSObject {
  static let shared = DownloadManager()

  private let log = Logger(subsystem: "com.dsm.dsvideo", category: "DownloadManager")

  private(set) var activeDownloads: [String: ActiveDownload] = [:]
  private(set) var downloadProgress: [String: Double] = [:]
  /// In-memory map of itemId → resume data blob for paused downloads.
  private(set) var pausedDownloads: [String: Data] = [:]
  /// TASK-782: itemId → failure record for genuinely-failed downloads. Populated in the
  /// non-pause error branch and the moveItem-catch so the Downloads UI can show a
  /// "Download failed — retry" row rather than the row silently disappearing.
  private(set) var failedDownloads: [String: FailedDownload] = [:]

  private var backgroundSession: URLSession
  private var downloadTasks: [URLSessionDownloadTask: String] = [:]
  private var pendingDownloadInfo: [String: (title: String, year: Int?, posterURL: URL?, durationSeconds: Int, token: String?, videoURL: URL?)] = [:]
  private var lastProgressUpdate: [String: Date] = [:]

  private let storageKey = "dsReel.downloadedItems"
  private let resumeDataKey = "dsReel.resumeData"
  /// Persists minimal metadata for paused downloads across app launches.
  private let pausedMetaKey = "dsReel.pausedMeta"
  private var cachedDownloadedItems: [DownloadedItem]?

  // FIX-7: Called by AppDelegate.handleEventsForBackgroundURLSession. Must be invoked
  // in urlSessionDidFinishEvents(forBackgroundURLSession:) after all events are processed.
  var backgroundCompletionHandler: (() -> Void)?

  override private init() {
    // TASK-738: default downloads to Wi-Fi only unless the user opts into cellular.
    UserDefaults.standard.register(defaults: ["dsReel.downloadsWifiOnly": true])
    let config = URLSessionConfiguration.background(withIdentifier: "com.heiloprojects.dsreel.downloads")
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    backgroundSession = URLSession(configuration: config, delegate: nil, delegateQueue: OperationQueue())
    super.init()
    // Re-assign with self as delegate now that super.init() has completed.
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

    // Clear any prior failure record — this itemId is being (re)started.
    failedDownloads.removeValue(forKey: itemId)

    var request = URLRequest(url: videoURL)
    // Video Station embeds the SID as a `_sid=` query parameter in the URL itself.
    // In that case no Authorization header is needed — the credential is already in the URL.
    // For the REST API backend, attach the Bearer token as a header.
    if !videoURL.absoluteString.contains("_sid="), let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    // TASK-738: honour the "Download over Wi-Fi only" preference (default on) at the
    // request level — works without recreating the background session. Defaults to
    // true when the key has never been set (registerDefaults below).
    request.allowsCellularAccess = !UserDefaults.standard.bool(forKey: "dsReel.downloadsWifiOnly")

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
    failedDownloads.removeValue(forKey: itemId)
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

  /// TASK-807: bulk-purge every downloaded file and all download state. Called on
  /// logout() so a shared device leaves no cross-user video residue on disk.
  func clearAll() {
    // Cancel any in-flight tasks first so no completion handler re-creates state
    // or writes a file after we've wiped the directory.
    for (_, download) in activeDownloads {
      download.task.cancel()
      downloadTasks.removeValue(forKey: download.task)
    }
    activeDownloads.removeAll()
    downloadProgress.removeAll()
    pausedDownloads.removeAll()
    failedDownloads.removeAll()
    pendingDownloadInfo.removeAll()

    let fm = FileManager.default

    // Remove individual poster files recorded in metadata (posters may live outside
    // the Downloads directory), then remove the whole Downloads directory.
    for item in getDownloadedItems() {
      try? fm.removeItem(atPath: item.videoPath)
      if let posterPath = item.posterPath {
        try? fm.removeItem(atPath: posterPath)
      }
    }
    try? fm.removeItem(at: downloadsDirectory())

    // Wipe persisted metadata and any lingering resume-data blobs.
    try? fm.removeItem(at: downloadsMetadataFileURL)
    cachedDownloadedItems = nil
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

  // MARK: - TASK-782: failed-download surface

  func isFailed(itemId: String) -> Bool {
    failedDownloads[itemId] != nil
  }

  /// Re-issue a previously-failed download from its captured metadata. No-op for a
  /// permanent failure (e.g. disk full) — retrying the network can't fix that.
  func retryFailedDownload(itemId: String) {
    guard let failure = failedDownloads[itemId], !failure.isPermanent,
          let videoURL = failure.videoURL else { return }
    failedDownloads.removeValue(forKey: itemId)
    startDownload(
      itemId: itemId,
      title: failure.title,
      year: failure.year,
      videoURL: videoURL,
      posterURL: failure.posterURL,
      token: failure.token,
      durationSeconds: failure.durationSeconds
    )
  }

  /// Dismiss a failure row without retrying.
  func dismissFailedDownload(itemId: String) {
    failedDownloads.removeValue(forKey: itemId)
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

    // Read from Application Support JSON file (canonical storage).
    // Migrate from UserDefaults on first launch after upgrade: copy data to file, then remove key.
    let fileURL = downloadsMetadataFileURL
    var rawData: Data?
    if let fileData = try? Data(contentsOf: fileURL) {
      rawData = fileData
    } else if let udData = UserDefaults.standard.data(forKey: storageKey) {
      // Migration path: write to Application Support, then remove from UserDefaults.
      // Only remove from UserDefaults after confirming the write succeeded — preserves
      // data if the write fails (e.g. disk full) so the next launch can retry (TASK-549).
      rawData = udData
      let dir = fileURL.deletingLastPathComponent()
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      do {
        try udData.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.complete],
          ofItemAtPath: fileURL.path
        )
        UserDefaults.standard.removeObject(forKey: storageKey) // only remove after successful write
      } catch {
        // Write failed — keep UserDefaults intact for next launch (TASK-767: log so it's diagnosable)
        log.error("persistDownloadedItems: file write failed, retaining UserDefaults fallback — \(error.localizedDescription)")
      }
    }

    guard let data = rawData,
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
    // Read raw items directly from the metadata file to preserve the filename-only storage invariant.
    // Using getDownloadedItems() would resolve absolute paths and write them back, undoing the fix.
    guard let rawData = try? Data(contentsOf: downloadsMetadataFileURL),
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

  /// SEC-01: Paused download metadata stored in Application Support with NSFileProtectionComplete.
  /// Replaces UserDefaults storage — metadata contains videoURLs that are user data.
  private var pausedMetaFileURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("pausedMeta.json")
  }

  private func loadPausedMetaFromDisk() -> [String: [String: String]] {
    guard let data = try? Data(contentsOf: pausedMetaFileURL),
          let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
      return [:]
    }
    return decoded
  }

  private func savePausedMetaToDisk(_ store: [String: [String: String]]) {
    let fileURL = pausedMetaFileURL
    let dir = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(store) else { return }
    try? data.write(to: fileURL, options: .atomic)
    try? FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: fileURL.path
    )
  }

  /// Load persisted resume data blobs (from disk) and paused item metadata (from Application Support file).
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
    // SEC-01: Migrate legacy paused metadata from UserDefaults to Application Support file.
    if let legacy = UserDefaults.standard.dictionary(forKey: pausedMetaKey) as? [String: [String: String]], !legacy.isEmpty {
      let existing = loadPausedMetaFromDisk()
      let merged = existing.merging(legacy) { file, _ in file }  // prefer already-migrated entries
      savePausedMetaToDisk(merged)
      UserDefaults.standard.removeObject(forKey: pausedMetaKey)
    }
    // Load resume data from disk files tracked in pausedMeta (Application Support file)
    let raw = loadPausedMetaFromDisk()
    for (itemId, _) in raw {
      if let data = try? Data(contentsOf: resumeDataFileURL(for: itemId)) {
        pausedDownloads[itemId] = data
      }
    }
    // Restore minimal pendingDownloadInfo so paused items remain resumable after app launch
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

  /// Persist resume data blob to a file in the Downloads directory.
  private func persistResumeData(_ data: Data, for itemId: String) {
    try? data.write(to: resumeDataFileURL(for: itemId), options: .atomic)
  }

  /// Persist minimal metadata for a paused download so it can be displayed and resumed after app relaunch.
  /// Stores the video URL so resumeDownload can fall back to a fresh startDownload if resume data is lost.
  /// The `_sid=` session token query parameter is stripped before persisting — it is a short-lived
  /// credential. Storage uses Application Support with NSFileProtectionComplete (SEC-01).
  private func persistPausedMeta(for itemId: String) {
    guard let info = pendingDownloadInfo[itemId] else { return }
    var store = loadPausedMetaFromDisk()
    var meta: [String: String] = ["title": info.title]
    if let year = info.year { meta["year"] = "\(year)" }
    if let posterURL = info.posterURL { meta["posterURL"] = posterURL.absoluteString }
    if let videoURL = info.videoURL {
      // Strip _sid= before persisting — it is a session credential.
      // startDownload re-attaches auth on resume.
      meta["videoURL"] = strippingSid(from: videoURL).absoluteString
    }
    meta["durationSeconds"] = "\(info.durationSeconds)"
    store[itemId] = meta
    savePausedMetaToDisk(store)
  }

  /// Returns a copy of `url` with the `_sid` query parameter removed.
  private func strippingSid(from url: URL) -> URL {
    guard url.absoluteString.contains("_sid="),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    components.queryItems = components.queryItems?.filter { $0.name != "_sid" }
    if components.queryItems?.isEmpty == true { components.queryItems = nil }
    return components.url ?? url
  }

  /// Remove a single item's resume data file and paused metadata from Application Support file.
  private func removePersistedResumeData(for itemId: String) {
    try? FileManager.default.removeItem(at: resumeDataFileURL(for: itemId))
    var store = loadPausedMetaFromDisk()
    store.removeValue(forKey: itemId)
    savePausedMetaToDisk(store)
  }

  /// URL for the downloads metadata JSON file in Application Support.
  /// This is the canonical storage location; UserDefaults is only consulted for migration.
  private var downloadsMetadataFileURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("downloads.json")
  }

  private func saveDownloadedItems(_ items: [DownloadedItem]) {
    // FIX-9: Log encode/write failures instead of silently discarding download metadata.
    let data: Data
    do {
      data = try JSONEncoder().encode(items)
    } catch {
      log.error("saveDownloadedItems: encode failed — \(error.localizedDescription)")
      return
    }
    let fileURL = downloadsMetadataFileURL
    // Ensure the Application Support directory exists
    let dir = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
      try data.write(to: fileURL, options: .atomic)
    } catch {
      log.error("saveDownloadedItems: write failed — \(error.localizedDescription)")
      return
    }
    // Apply complete file protection to the metadata file
    try? FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: fileURL.path
    )
  }

  private func downloadsDirectory() -> URL {
    let fm = FileManager.default
    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var dir = docs.appendingPathComponent("Downloads", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // Exclude downloaded videos (multi-GB) and resume-data blobs from iCloud/iTunes
    // backup. Without this, large media files count against the user's iCloud quota
    // and the app risks App Review rejection under guideline 2.5.x for storing
    // re-downloadable content in a backed-up location.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
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
      // TASK-782: surface the failure instead of silently dropping the row. A failed
      // move at this stage is almost always out-of-space — permanent, so no retry.
      failedDownloads[itemId] = FailedDownload(
        id: itemId, title: info.title, videoURL: info.videoURL,
        posterURL: info.posterURL, token: info.token, year: info.year,
        durationSeconds: info.durationSeconds, isPermanent: true,
        message: "Couldn't save the file. Free up space and try again."
      )
      activeDownloads.removeValue(forKey: itemId)
      downloadProgress.removeValue(forKey: itemId)
      pendingDownloadInfo.removeValue(forKey: itemId)
      return
    }

    // Apply complete file protection so the video is inaccessible when the device is locked.
    try? fm.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: videoPath.path
    )

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

    // Read raw items from the metadata file to preserve filename-only storage invariant,
    // then insert the new item (which already uses filename-only videoPath).
    let rawItems: [DownloadedItem]
    if let rawData = try? Data(contentsOf: downloadsMetadataFileURL),
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

    // Download finished and is now playable offline — confirm with a success haptic.
    Haptics.play(.success)

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
          log.debug("[DownloadManager] Poster fetch failed: HTTP \(status)")
          return
        }

        try data.write(to: posterDestination, options: .atomic)
        try? FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.complete],
          ofItemAtPath: posterDestination.path
        )

        // Update the persisted item with the poster path (filename only).
        // Read raw from the metadata file to preserve the filename-only videoPath invariant.
        await MainActor.run {
          let metaURL = self.downloadsMetadataFileURL
          guard let rawData = try? Data(contentsOf: metaURL),
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
          self.saveDownloadedItems(rawItems)
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
      lastProgressUpdate.removeValue(forKey: itemId)
      completeDownload(itemId: itemId, tempURL: stableCopy)
    }
  }

  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    let writtenSnapshot = totalBytesWritten
    let expectedSnapshot = totalBytesExpectedToWrite
    Task { @MainActor in
      guard let itemId = downloadTasks[downloadTask] else { return }
      let now = Date()
      if let last = lastProgressUpdate[itemId], now.timeIntervalSince(last) < 0.1 { return }
      lastProgressUpdate[itemId] = now
      let progress = expectedSnapshot > 0 ? Double(writtenSnapshot) / Double(expectedSnapshot) : 0
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
        lastProgressUpdate.removeValue(forKey: itemId)
        downloadTasks.removeValue(forKey: downloadTask)
        // Note: pendingDownloadInfo is intentionally kept when pausing so resumeDownload can access it
        if nsError.code != NSURLErrorCancelled || resumeData == nil {
          // Genuine failure (not a pause). TASK-782: surface it so the Downloads UI
          // shows "Download failed — retry" rather than the row silently vanishing.
          // A user-initiated cancel (code == Cancelled) is not a failure and is skipped.
          if nsError.code != NSURLErrorCancelled, let info = pendingDownloadInfo[itemId] {
            failedDownloads[itemId] = FailedDownload(
              id: itemId, title: info.title, videoURL: info.videoURL,
              posterURL: info.posterURL, token: info.token, year: info.year,
              durationSeconds: info.durationSeconds, isPermanent: false,
              message: "Download failed. Check your connection and retry."
            )
          }
          // Clean up pendingDownloadInfo too (failedDownloads now carries the retry context).
          pendingDownloadInfo.removeValue(forKey: itemId)
        }
      }
    }
  }

  // FIX-7: Called by URLSession after all background events for a session are delivered.
  // Invoke the stored completion handler so iOS knows the app has finished processing,
  // allowing the system to take a new snapshot and release the background runtime extension.
  nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor in
      backgroundCompletionHandler?()
      backgroundCompletionHandler = nil
    }
  }
}
