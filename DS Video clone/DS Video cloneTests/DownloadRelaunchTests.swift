import Foundation
import Testing
@testable import DSM_Video

// MARK: - Downloads survive app termination (TASK-947, TASK-971 · FR-045, FR-031..033)
//
// The background session outlives the app: iOS may terminate the process mid-transfer and
// relaunch it to deliver the result. A relaunch is modelled as a SECOND manager on the same
// container, handed the first manager's task exactly as the session would hand it over. The
// second manager has an empty task map, so these tests also stand where the bug stood: a
// callback for a task this process never started.

private func makeContainer(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-relaunch-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Nothing listens on the discard port, so a task resumed against it goes nowhere.
private let deadURL = URL(string: "http://127.0.0.1:9/stream.mp4")!

/// Polls the main actor until `condition` holds (delegate callbacks hop there in a Task).
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<200 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@MainActor
struct DownloadRelaunchTests {

  /// FR-045 · TASK-947 AC-1/3/6 · TASK-971 AC-1/4. A download started in one process finishes
  /// while that process is gone; the next process receives the completion and keeps the file,
  /// with the title and age level the first process recorded, and releases the session.
  /// Red if: the item is only known through the in-memory map (the relaunched manager's map
  /// is empty), the task is not labelled, or the metadata is not persisted at start.
  @Test func aDownloadThatFinishesAfterARelaunchIsKeptWithItsAgeLevel() async throws {
    let container = try makeContainer("finish")
    defer { try? FileManager.default.removeItem(at: container) }
    let first = DownloadManager(containerForTesting: container)
    first.startDownload(itemId: "mv-1", title: "Night Film", year: 2021, videoURL: deadURL,
                        posterURL: nil, token: nil, durationSeconds: 5400, ageLevel: 3,
                        playbackSessionID: "sid-first")
    let task = try #require(first.activeDownloads["mv-1"]?.task)
    #expect(task.taskDescription == "mv-1", "the item travels with the task")

    let relaunched = DownloadManager(containerForTesting: container)
    var released: [String] = []
    relaunched.releaseSessionProvider = { released.append($0) }
    let delivered = container.appendingPathComponent("delivered.tmp")
    try Data("finished-movie-bytes".utf8).write(to: delivered)
    relaunched.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: delivered)

    #expect(await eventually { relaunched.isDownloaded(itemId: "mv-1") }, "the finished file is kept")
    let item = try #require(relaunched.getDownloadedItem(itemId: "mv-1"))
    #expect(item.title == "Night Film")
    #expect(item.ageLevel == 3, "the FR-262 stamp recorded at start survives the relaunch")
    #expect(released == ["sid-first"], "whichever process ends the transfer releases its session")
    #expect(relaunched.failedDownloads["mv-1"] == nil)
  }

  /// FR-045 · TASK-947 AC-2/5. At launch a Download tap is held until the session has reported
  /// the transfers that survived; the surviving one is re-attached and the tap joins it, so no
  /// second transfer starts, and the tap's own fresh session is released.
  @Test func aSurvivingTransferIsReattachedAndATapDoesNotStartASecond() async throws {
    let container = try makeContainer("adopt")
    defer { try? FileManager.default.removeItem(at: container) }
    let first = DownloadManager(containerForTesting: container)
    first.startDownload(itemId: "mv-2", title: "Long Film", year: nil, videoURL: deadURL,
                        posterURL: nil, token: nil, durationSeconds: 9000, ageLevel: 2,
                        playbackSessionID: "sid-first")

    let relaunched = DownloadManager(containerForTesting: container, awaitingSurvivingTasks: true)
    var released: [String] = []
    relaunched.releaseSessionProvider = { released.append($0) }
    relaunched.startDownload(itemId: "mv-2", title: "Long Film", year: nil, videoURL: deadURL,
                             posterURL: nil, token: nil, durationSeconds: 9000, ageLevel: 2,
                             playbackSessionID: "sid-tap")
    #expect(relaunched.activeDownloads["mv-2"] == nil, "held until the session answers")

    // What the session reports: the previous process's transfer, still labelled, not running.
    let survivor = URLSession(configuration: .ephemeral).downloadTask(with: deadURL)
    survivor.taskDescription = "mv-2"
    defer { survivor.cancel() }
    relaunched.adoptSurvivingTasks([survivor])

    #expect(relaunched.activeDownloads["mv-2"]?.task === survivor, "the surviving transfer is the item's")
    #expect(relaunched.activeDownloads["mv-2"]?.title == "Long Film")
    #expect(released == ["sid-tap"], "the held tap attached to it and gave back its own session")
  }

  /// FR-045 · TASK-947 AC-4. A force-quit makes the system cancel the transfer and hand its
  /// resume data to the NEXT launch. That process records a paused download (not a failure),
  /// keeps the session the resume data replays, and the pause itself survives another relaunch.
  @Test func aForceQuitTransferArrivesAsAPausedDownload() async throws {
    let container = try makeContainer("forcequit")
    defer { try? FileManager.default.removeItem(at: container) }
    let first = DownloadManager(containerForTesting: container)
    first.startDownload(itemId: "mv-3", title: "Paused Film", year: 2019, videoURL: deadURL,
                        posterURL: nil, token: nil, durationSeconds: 6000, ageLevel: 1,
                        playbackSessionID: "sid-first")
    let task = try #require(first.activeDownloads["mv-3"]?.task)

    let relaunched = DownloadManager(containerForTesting: container)
    var released: [String] = []
    relaunched.releaseSessionProvider = { released.append($0) }
    let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
      NSURLSessionDownloadTaskResumeData: Data("resume-blob".utf8),
      NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication,
    ])
    relaunched.urlSession(URLSession.shared, task: task, didCompleteWithError: cancelled)

    #expect(await eventually { relaunched.isPaused(itemId: "mv-3") }, "resume data makes it paused")
    #expect(relaunched.failedDownloads["mv-3"] == nil, "a resumable stop is not a failure")
    #expect(relaunched.pausedDownloadTitle(itemId: "mv-3") == "Paused Film")
    #expect(released.isEmpty, "the resume data replays this session; it is kept")

    let again = DownloadManager(containerForTesting: container)
    #expect(again.isPaused(itemId: "mv-3"))
    #expect(again.pausedDownloadTitle(itemId: "mv-3") == "Paused Film")
  }

  /// FR-031/032/033 · TASK-971 AC-2/4. The finished temp file cannot be preserved (here: it is
  /// not there; on a device, typically a full disk). The item must leave Downloading for a
  /// retryable Failed row that names storage, never connection, and never sit at 100%.
  /// Red if the preserve-failure branch returns silently, as it did.
  @Test func aFinishedFileThatCannotBeSavedBecomesAStorageFailure() async throws {
    let container = try makeContainer("savefail")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    var released: [String] = []
    manager.releaseSessionProvider = { released.append($0) }
    manager.startDownload(itemId: "mv-4", title: "Big Film", year: nil, videoURL: deadURL,
                          posterURL: nil, token: nil, durationSeconds: 7200, ageLevel: 2,
                          playbackSessionID: "sid-4")
    let task = try #require(manager.activeDownloads["mv-4"]?.task)

    let vanished = container.appendingPathComponent("no-such-file.tmp")
    manager.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: vanished)

    #expect(await eventually { manager.failedDownloads["mv-4"] != nil }, "a Failed row, not silence")
    let failure = try #require(manager.failedDownloads["mv-4"])
    #expect(failure.message.contains("storage"))
    #expect(!failure.message.contains("connection"))
    #expect(!failure.isPermanent, "freeing space fixes it, so it can be retried")
    #expect(failure.title == "Big Film")
    #expect(manager.activeDownloads["mv-4"] == nil, "the row leaves Downloading")
    #expect(manager.downloadProgress["mv-4"] == nil)
    #expect(!manager.isDownloaded(itemId: "mv-4"))
    #expect(released == ["sid-4"])
  }

  /// FR-033 · TASK-971 AC-3. A transfer the system stopped because it could not write the file
  /// says storage; one that lost the network says connection. Same entry point, two causes.
  @Test func aWriteErrorAndANetworkErrorNameDifferentCauses() async throws {
    let container = try makeContainer("causes")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    for id in ["mv-write", "mv-net"] {
      manager.startDownload(itemId: id, title: id, year: nil, videoURL: deadURL, posterURL: nil,
                            token: nil, durationSeconds: 60)
    }
    let writeTask = try #require(manager.activeDownloads["mv-write"]?.task)
    let netTask = try #require(manager.activeDownloads["mv-net"]?.task)
    manager.urlSession(URLSession.shared, task: writeTask, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile))
    manager.urlSession(URLSession.shared, task: netTask, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))

    #expect(await eventually {
      manager.failedDownloads["mv-write"] != nil && manager.failedDownloads["mv-net"] != nil
    })
    #expect(manager.failedDownloads["mv-write"]?.message.contains("storage") == true)
    #expect(manager.failedDownloads["mv-net"]?.message.contains("connection") == true)
  }
}
