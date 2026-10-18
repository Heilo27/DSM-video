import Foundation
import Testing
@testable import DSM_Video

// MARK: - Downloads list: what the user reads after a stop, a double tap, a lost file
// (TASK-967 · OC-1041 · OC-1043 · OC-1051 · OC-1054 · OC-1139 · FR-030..043)
//
// Observed at the layer the user reads (the failed list, the downloaded list, the badge a card
// shows) and through a FRESH manager on the same container for anything that must survive a
// relaunch. Expected values are literals only.

private func makeContainer(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-listoracle-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Nothing listens on the discard port, so the transfer goes nowhere.
private let deadURL = URL(string: "http://127.0.0.1:9/stream.mp4")!

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<300 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@MainActor
struct DownloadListOracleTests {

  private func start(_ manager: DownloadManager, _ id: String, session: String? = nil) {
    manager.startDownload(itemId: id, title: "Film \(id)", year: 2020, videoURL: deadURL,
                          posterURL: nil, token: nil, durationSeconds: 5400, ageLevel: 2,
                          playbackSessionID: session)
  }

  /// Completes a download of `id` the way the background session does.
  private func finish(_ manager: DownloadManager, _ id: String, in container: URL) async throws {
    start(manager, id)
    let task = try #require(manager.activeDownloads[id]?.task)
    let delivered = container.appendingPathComponent("\(id).tmp")
    try Data("movie-bytes".utf8).write(to: delivered)
    manager.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: delivered)
    try #require(await eventually { manager.isDownloaded(itemId: id) }, "fixture download \(id) completed")
  }

  // MARK: OC-1041 · OC-1139 · OC-1042

  /// OC-1139 · OC-1041 · OC-1042 · given a download at 40% in progress, when the connection is
  /// lost, then the entry is listed as Failed (it does not vanish), reads as interrupted and
  /// never as downloaded, holds no partial progress, and is not offered as a playable download;
  /// the row is still there after a relaunch.
  /// Red if: a transport error is treated as success (the title enters the downloaded list), or
  /// the entry is dropped instead of kept as a failed row.
  @Test func aTransferCutOffMidwayIsAFailedRowAndNeverADownloadedOne() async throws {
    let container = try makeContainer("cutoff")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    start(manager, "mv-cut", session: "sid-cut")
    let task = try #require(manager.activeDownloads["mv-cut"]?.task)
    manager.urlSession(URLSession.shared, downloadTask: task, didWriteData: 400,
                       totalBytesWritten: 400, totalBytesExpectedToWrite: 1000)
    #expect(await eventually { manager.downloadProgress["mv-cut"] == 0.4 }, "precondition: 40% reached")

    manager.urlSession(URLSession.shared, task: task, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))

    #expect(await eventually { manager.failedDownloads["mv-cut"] != nil }, "listed as failed")
    #expect(manager.failedDownloads.count == 1)
    #expect(manager.failedDownloads["mv-cut"]?.title == "Film mv-cut")
    #expect(manager.activeDownloads.isEmpty)
    #expect(manager.downloadProgress["mv-cut"] == nil, "no stale percent on a failed row")
    #expect(!manager.isDownloaded(itemId: "mv-cut"))
    #expect(manager.getDownloadedItems().isEmpty)
    #expect(manager.badgeState(for: "mv-cut", offline: false) == .none,
            "a card never claims a cut-off transfer is downloaded")

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.failedDownloads["mv-cut"] != nil, "the failed row is still listed next launch")
    #expect(!relaunched.isDownloaded(itemId: "mv-cut"))
  }

  // MARK: OC-1043

  /// OC-1043 · given downloads failing for each cause (connection lost, storage cannot be
  /// written, server error 500, server error 503), when the user reads each failure, then each
  /// names its own cause in the app's wording, and none blames the video format or the user's
  /// credentials/session.
  /// Red if: any cause is mapped to another's sentence, the wording drifts, or a cause starts
  /// blaming the format or the session.
  @Test func eachFailureCauseNamesItselfAndNoneBlamesFormatOrCredentials() async throws {
    let container = try makeContainer("causes")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    for id in ["mv-net", "mv-disk"] { start(manager, id) }
    let netTask = try #require(manager.activeDownloads["mv-net"]?.task)
    let diskTask = try #require(manager.activeDownloads["mv-disk"]?.task)
    manager.urlSession(URLSession.shared, task: netTask, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
    manager.urlSession(URLSession.shared, task: diskTask, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile))
    manager.recordHTTPFailure(itemId: "mv-500", status: 500)
    manager.recordHTTPFailure(itemId: "mv-503", status: 503)
    #expect(await eventually {
      manager.failedDownloads["mv-net"] != nil && manager.failedDownloads["mv-disk"] != nil
    })

    let expected: [(String, String)] = [
      ("mv-net", "Download failed. Check your connection and retry."),
      ("mv-disk", "Couldn't save the download on this device. Check free storage, then retry."),
      ("mv-500", "The server had a problem preparing this video. Try again shortly."),
      ("mv-503", "The server had a problem preparing this video. Try again shortly."),
    ]
    #expect(manager.failedDownloads.count == 4)
    for (id, text) in expected {
      let message = manager.failedDownloads[id]?.message ?? "<no failure listed>"
      #expect(message == text, "\(id)")
      let lowered = message.lowercased()
      for banned in ["format", "codec", "password", "credential", "sign in", "session", "expired"] {
        #expect(!lowered.contains(banned), "\(id): \"\(message)\" must not mention \(banned)")
      }
    }
  }

  // MARK: OC-1051

  /// OC-1051 · given a title already downloading, when Download is tapped on it again (a double
  /// tap), then there is still exactly one entry, it is the SAME running transfer (not a
  /// replacement), the redundant playback session is released, and the first tap's session is
  /// not; a different title is unaffected and a tap on a title that is already downloaded adds
  /// no entry either.
  /// Red if: the second tap starts a second transfer or replaces the task, or leaks its session.
  @Test func tappingDownloadTwiceLeavesOneEntryAndOneTransfer() async throws {
    let container = try makeContainer("doubletap")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    var released: [String] = []
    manager.releaseSessionProvider = { released.append($0) }

    start(manager, "mv-dbl", session: "sid-first")
    let first = try #require(manager.activeDownloads["mv-dbl"]?.task)
    start(manager, "mv-dbl", session: "sid-second")

    #expect(manager.activeDownloads.count == 1)
    #expect(manager.activeDownloads["mv-dbl"]?.task === first, "the tap attached to the running task")
    #expect(released == ["sid-second"], "only the redundant session is released")

    // A title that is already downloaded: a further tap adds nothing and wastes no session.
    try await finish(manager, "mv-done", in: container)
    released.removeAll()
    start(manager, "mv-done", session: "sid-third")
    #expect(manager.activeDownloads["mv-done"] == nil)
    #expect(manager.activeDownloads.count == 1)
    #expect(manager.getDownloadedItems().map(\.id) == ["mv-done"])
    #expect(released == ["sid-third"])
  }

  // MARK: OC-1054

  /// OC-1054 · given a completed download whose file is removed outside the app, when the app
  /// next opens Downloads (a fresh manager), then that title is no longer listed, not playable,
  /// not badged as downloaded, and its neighbours are untouched.
  /// Red if: the manifest entry is trusted without the file, so the title is offered for
  /// playback and fails when played.
  @Test func aDownloadWhoseFileWasRemovedOutsideTheAppIsNoLongerOffered() async throws {
    let container = try makeContainer("filegone")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    for id in ["mv-a", "mv-gone", "mv-c"] { try await finish(manager, id, in: container) }
    let before = DownloadManager(containerForTesting: container)
    #expect(before.getDownloadedItems().map(\.id).sorted() == ["mv-a", "mv-c", "mv-gone"],
            "precondition: all three are listed with their files")
    let path = try #require(before.getDownloadedItem(itemId: "mv-gone")?.videoPath)
    try FileManager.default.removeItem(atPath: path)

    let reopened = DownloadManager(containerForTesting: container)

    #expect(reopened.getDownloadedItems().map(\.id).sorted() == ["mv-a", "mv-c"])
    #expect(!reopened.isDownloaded(itemId: "mv-gone"))
    #expect(reopened.getDownloadedItem(itemId: "mv-gone") == nil)
    #expect(reopened.playableDownloadedItem(itemId: "mv-gone") == nil)
    #expect(reopened.badgeState(for: "mv-gone", offline: false) == .none)
    #expect(reopened.playableDownloadedItem(itemId: "mv-a")?.id == "mv-a", "neighbours still play")
    #expect(reopened.playableDownloadedItem(itemId: "mv-c")?.id == "mv-c")
  }
}
