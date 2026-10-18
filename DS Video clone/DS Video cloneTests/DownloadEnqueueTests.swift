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

// MARK: - Durability (TASK-994 · FR-032 · FR-045)

private let posterURL = URL(string: "http://127.0.0.1:9/poster.jpg")!

@MainActor
struct DownloadDurabilityTests {

  /// FR-032 · TASK-994 AC-1. A Failed row survives a relaunch until the user dismisses it, and
  /// what is written for it holds no credential. Red if failures live only in memory.
  @Test func aFailedRowSurvivesARelaunchUntilDismissed() async throws {
    let container = try makeContainer("failrow")
    defer { try? FileManager.default.removeItem(at: container) }
    let first = DownloadManager(containerForTesting: container)
    first.startDownload(itemId: "mv-f", title: "Lost Film", year: 2020,
                        videoURL: URL(string: "http://127.0.0.1:9/stream.mp4?_sid=SECRET")!,
                        posterURL: nil, token: "tok-secret", durationSeconds: 100, ageLevel: 2)
    let task = try #require(first.activeDownloads["mv-f"]?.task)
    first.urlSession(URLSession.shared, task: task, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
    #expect(await eventually { first.failedDownloads["mv-f"] != nil })

    let second = DownloadManager(containerForTesting: container)
    let kept = try #require(second.failedDownloads["mv-f"])
    #expect(kept.title == "Lost Film")
    #expect(kept.ageLevel == 2)
    let onDisk = try String(contentsOf: container.appendingPathComponent("failedDownloads.json"), encoding: .utf8)
    #expect(!onDisk.contains("SECRET") && !onDisk.contains("tok-secret"), "no credential at rest")

    second.dismissFailedDownload(itemId: "mv-f")
    #expect(DownloadManager(containerForTesting: container).failedDownloads["mv-f"] == nil,
            "dismissed means gone for good")
  }

  /// FR-045 · TASK-994 AC-4. A pause that stops a transfer with nothing to resume, just as the
  /// transfer finished, must still keep the file that arrives afterwards. Red if the late
  /// delivery finds no owner and is discarded.
  @Test func aFileThatFinishesDuringAPauseIsKept() async throws {
    let container = try makeContainer("pauserace")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    manager.startDownload(itemId: "mv-race", title: "Racing Film", year: nil, videoURL: deadURL,
                          posterURL: nil, token: nil, durationSeconds: 90, ageLevel: 1)
    let task = try #require(manager.activeDownloads["mv-race"]?.task)

    await manager.pauseDownload(itemId: "mv-race")
    try #require(manager.failedDownloads["mv-race"] != nil, "no bytes yet: nothing to resume, so a Failed row")

    let delivered = container.appendingPathComponent("late.tmp")
    try Data("whole-movie".utf8).write(to: delivered)
    manager.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: delivered)

    #expect(await eventually { manager.isDownloaded(itemId: "mv-race") }, "the finished file is kept")
    #expect(manager.failedDownloads["mv-race"] == nil, "the Failed row gives way to the download")
  }

  /// FR-045 · TASK-994 AC-2. A download that completes before the app has wired its providers
  /// (a background relaunch) neither leaks its playback session nor loses its poster: both run
  /// when the providers arrive, even in a later process. Red if either is dropped.
  @Test func sessionReleaseAndPosterWaitForTheProviders() async throws {
    let container = try makeContainer("deferred")
    defer { try? FileManager.default.removeItem(at: container) }
    let first = DownloadManager(containerForTesting: container)
    first.startDownload(itemId: "mv-d", title: "Quiet Film", year: nil, videoURL: deadURL,
                        posterURL: posterURL, token: nil, durationSeconds: 90, ageLevel: 1,
                        playbackSessionID: "sid-d")
    let task = try #require(first.activeDownloads["mv-d"]?.task)
    let delivered = container.appendingPathComponent("done.tmp")
    try Data("movie".utf8).write(to: delivered)
    first.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: delivered)
    #expect(await eventually { first.isDownloaded(itemId: "mv-d") })

    let deferralFile = container.appendingPathComponent("deferredDownloadWork.json")
    let saved = try String(contentsOf: deferralFile, encoding: .utf8)
    #expect(saved.contains("sid-d"), "the session to release is remembered")
    #expect(saved.contains("poster.jpg"), "the poster to fetch is remembered")

    let later = DownloadManager(containerForTesting: container)
    var released: [String] = []
    later.flushDeferredWork()
    #expect(released.isEmpty && FileManager.default.fileExists(atPath: deferralFile.path),
            "nothing runs, and nothing is forgotten, before the providers exist")
    later.releaseSessionProvider = { released.append($0) }
    later.tokenProvider = { "live-token" }
    later.flushDeferredWork()
    #expect(released == ["sid-d"])
    #expect(!FileManager.default.fileExists(atPath: deferralFile.path), "done work is not repeated")
  }

  /// FR-045 · TASK-994 AC-5. The record that a transfer was started from resume data survives a
  /// termination, so a 404 from the replayed (reaped) session still restarts on a fresh one
  /// instead of failing. Red if the flag lives only in memory.
  @Test func theResumedFlagSurvivesARelaunch() async throws {
    let container = try makeContainer("resumedflag")
    defer { try? FileManager.default.removeItem(at: container) }
    let first = DownloadManager(containerForTesting: container)
    try await startAndPause(first, itemId: "mv-r", sessionID: nil)
    first.resumeDownload(itemId: "mv-r")
    #expect(first.activeDownloads["mv-r"] != nil)

    let relaunched = DownloadManager(containerForTesting: container)
    var resolved: [String] = []
    relaunched.urlResolver = { id in resolved.append(id); return nil }
    relaunched.recordHTTPFailure(itemId: "mv-r", status: 404)

    #expect(await eventually { !resolved.isEmpty }, "a fresh session is asked for, not a Failed row raised")
  }

  /// FR-032 · TASK-994. Signing out leaves no failed row or deferred work behind.
  @Test func clearingEverythingRemovesFailedRowsAndDeferredWork() async throws {
    let container = try makeContainer("clear")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    manager.startDownload(itemId: "mv-c", title: "Gone Film", year: nil, videoURL: deadURL,
                          posterURL: nil, token: nil, durationSeconds: 60)
    let task = try #require(manager.activeDownloads["mv-c"]?.task)
    manager.urlSession(URLSession.shared, task: task, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
    #expect(await eventually { manager.failedDownloads["mv-c"] != nil })

    manager.clearAll()

    #expect(manager.failedDownloads.isEmpty)
    #expect(DownloadManager(containerForTesting: container).failedDownloads.isEmpty)
  }
}
