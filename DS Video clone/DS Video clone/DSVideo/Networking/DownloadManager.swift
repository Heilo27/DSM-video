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

  private var backgroundSession: URLSession!
  private var downloadTasks: [URLSessionDownloadTask: String] = [:]
  private var pendingDownloadInfo: [String: (title: String, year: Int?, posterURL: URL?)] = [:]

  private let storageKey = "dsReel.downloadedItems"

  override private init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: "com.heiloprojects.dsreel.downloads")
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  // MARK: - Public API

  func startDownload(
    itemId: String,
    title: String,
    year: Int?,
    videoURL: URL,
    posterURL: URL?,
    token: String?
  ) {
    guard activeDownloads[itemId] == nil else { return }
    guard !isDownloaded(itemId: itemId) else { return }

    var request = URLRequest(url: videoURL)
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let task = backgroundSession.downloadTask(with: request)
    downloadTasks[task] = itemId
    pendingDownloadInfo[itemId] = (title: title, year: year, posterURL: posterURL)

    let download = ActiveDownload(id: itemId, title: title, progress: 0, task: task)
    activeDownloads[itemId] = download
    downloadProgress[itemId] = 0

    task.resume()
  }

  func cancelDownload(itemId: String) {
    guard let download = activeDownloads[itemId] else { return }
    download.task.cancel()
    downloadTasks.removeValue(forKey: download.task)
    activeDownloads.removeValue(forKey: itemId)
    downloadProgress.removeValue(forKey: itemId)
    pendingDownloadInfo.removeValue(forKey: itemId)
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
  }

  func isDownloaded(itemId: String) -> Bool {
    getDownloadedItems().contains { $0.id == itemId }
  }

  func isDownloading(itemId: String) -> Bool {
    activeDownloads[itemId] != nil
  }

  func getDownloadedItems() -> [DownloadedItem] {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let items = try? JSONDecoder().decode([DownloadedItem].self, from: data) else {
      return []
    }
    // Filter out items whose files no longer exist
    return items.filter { FileManager.default.fileExists(atPath: $0.videoPath) }
  }

  func getDownloadedItem(itemId: String) -> DownloadedItem? {
    getDownloadedItems().first { $0.id == itemId }
  }

  // MARK: - Private

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

    let item = DownloadedItem(
      id: itemId,
      title: info.title,
      year: info.year,
      videoPath: videoPath.path,
      posterPath: nil,
      fileSize: fileSize,
      downloadedAt: Date()
    )

    var items = getDownloadedItems()
    items.insert(item, at: 0)
    saveDownloadedItems(items)

    activeDownloads.removeValue(forKey: itemId)
    downloadProgress.removeValue(forKey: itemId)
    pendingDownloadInfo.removeValue(forKey: itemId)
  }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // The temp file at `location` is only valid during this synchronous call.
    // Copy it immediately before crossing actor boundaries.
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
    Task { @MainActor in
      guard let itemId = downloadTasks[downloadTask] else { return }
      if error != nil {
        activeDownloads.removeValue(forKey: itemId)
        downloadProgress.removeValue(forKey: itemId)
        pendingDownloadInfo.removeValue(forKey: itemId)
        downloadTasks.removeValue(forKey: downloadTask)
      }
    }
  }
}
