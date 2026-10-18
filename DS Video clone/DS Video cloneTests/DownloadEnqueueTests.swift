import Foundation
import Testing
@testable import DSM_Video

// MARK: - One entry per title (TASK-964 · FR-040)

private func makeContainer(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-enqueue-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private let deadURL = URL(string: "http://127.0.0.1:9/stream.mp4")!

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<200 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// Resume data that `downloadTask(withResumeData:)` accepts without raising: a property list
/// shaped like the system's (an arbitrary blob makes CFNetwork throw). The transfer it starts
/// goes nowhere (nothing listens on the discard port).
private func resumeBlob() throws -> Data {
  let info: [String: Any] = [
    "NSURLSessionDownloadURL": deadURL.absoluteString,
    "NSURLSessionResumeBytesReceived": 1024,
    "NSURLSessionResumeInfoVersion": 2,
    "NSURLSessionResumeEntityTag": "\"etag\"",
  ]
  return try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
}

/// Starts `itemId` and stops it with resume data, the way the system hands a paused transfer
/// back: the item ends up in the paused map, not the active one.
@MainActor
private func startAndPause(_ manager: DownloadManager, itemId: String, sessionID: String?) async throws {
  let blob = try resumeBlob()
  manager.startDownload(itemId: itemId, title: "Paused Film", year: 2019, videoURL: deadURL,
                        posterURL: nil, token: nil, durationSeconds: 6000, ageLevel: 1,
                        playbackSessionID: sessionID)
  let task = try #require(manager.activeDownloads[itemId]?.task)
  let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
    NSURLSessionDownloadTaskResumeData: blob,
  ])
  manager.urlSession(URLSession.shared, task: task, didCompleteWithError: cancelled)
  #expect(await eventually { manager.isPaused(itemId: itemId) }, "resume data makes it paused")
}

@MainActor
struct DownloadEnqueueTests {

  /// FR-040 · TASK-964 AC-1/2. A Download request for a paused title does not open a second
  /// transfer beside the partial: exactly one of {active, paused} holds the item, and the
  /// session the caller opened for the request is handed back.
  @Test func startingAPausedTitleKeepsASingleEntryAndReleasesTheSession() async throws {
    let container = try makeContainer("paused")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    var released: [String] = []
    manager.releaseSessionProvider = { released.append($0) }
    try await startAndPause(manager, itemId: "mv-p", sessionID: "sid-first")
    #expect(manager.activeDownloads.count + manager.pausedDownloads.count == 1)

    manager.startDownload(itemId: "mv-p", title: "Paused Film", year: 2019, videoURL: deadURL,
                          posterURL: nil, token: nil, durationSeconds: 6000, ageLevel: 1,
                          playbackSessionID: "sid-tap")

    let inActive = manager.activeDownloads["mv-p"] != nil
    let inPaused = manager.pausedDownloads["mv-p"] != nil
    #expect(inActive != inPaused, "exactly one of active/paused holds the title")
    #expect(manager.activeDownloads.count + manager.pausedDownloads.count == 1)
    #expect(released.contains("sid-tap"), "the tap's own fresh session is not left running")
  }

  /// FR-040 · TASK-964 AC-3. The title page's control for a paused download is Resume. The
  /// mapping is the manager's, so the view cannot send a paused title down the Download path.
  /// Red if `affordance` maps a paused item to `.download`.
  @Test func aPausedTitleOffersResumeNotDownload() async throws {
    let container = try makeContainer("afford")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.affordance(for: "mv-a") == .download, "untouched title downloads")

    manager.startDownload(itemId: "mv-a", title: "Film", year: nil, videoURL: deadURL,
                          posterURL: nil, token: nil, playbackSessionID: nil)
    #expect(manager.affordance(for: "mv-a") == .cancel, "a running transfer offers cancel")

    let task = try #require(manager.activeDownloads["mv-a"]?.task)
    let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
      NSURLSessionDownloadTaskResumeData: Data("resume-blob".utf8),
    ])
    manager.urlSession(URLSession.shared, task: task, didCompleteWithError: cancelled)
    #expect(await eventually { manager.isPaused(itemId: "mv-a") })
    #expect(manager.affordance(for: "mv-a") == .resume)
  }
}
