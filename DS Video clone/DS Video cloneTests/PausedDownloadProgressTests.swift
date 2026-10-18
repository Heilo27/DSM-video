import Foundation
import Testing
@testable import DSM_Video

// MARK: - A paused download keeps its percent (TASK-1021 · FRD-001 FR-030)
//
// `recordStop` called `forgetProgress` before it looked at the resume data, so every paused row
// read "0%" and its bar sat empty, whatever had been downloaded. A paused row keeps the progress it
// reached; progress is cleared when the download ends (cancel, completion, failure, sign-out).

private func pauseContainer(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-pausedprogress-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Nothing listens on the discard port, so a task started against it goes nowhere.
private let pauseDeadURL = URL(string: "http://127.0.0.1:9/stream.mp4")!

@MainActor
private func pauseEventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<200 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// Starts `itemId`, delivers 420 of 1000 bytes, and waits for the manager to record them.
@MainActor
private func startAt42Percent(_ manager: DownloadManager, itemId: String) async throws -> URLSessionDownloadTask {
  manager.startDownload(itemId: itemId, title: "Film \(itemId)", year: nil, videoURL: pauseDeadURL,
                        posterURL: nil, token: nil, durationSeconds: 6000, ageLevel: 1,
                        playbackSessionID: "sid-\(itemId)")
  let task = try #require(manager.activeDownloads[itemId]?.task)
  manager.urlSession(URLSession.shared, downloadTask: task, didWriteData: 420,
                     totalBytesWritten: 420, totalBytesExpectedToWrite: 1000)
  #expect(await pauseEventually { manager.downloadBytes[itemId] != nil }, "the bytes were recorded")
  return task
}

private func systemPause(_ manager: DownloadManager, task: URLSessionDownloadTask) {
  let stopped = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
    NSURLSessionDownloadTaskResumeData: Data("resume-blob".utf8),
  ])
  manager.urlSession(URLSession.shared, task: task, didCompleteWithError: stopped)
}

@MainActor
struct PausedDownloadProgressTests {

  /// AC: a paused row shows the percent reached when it paused. Red if `recordStop` forgets the
  /// progress before it takes the resume-data branch: the row reads `.paused(percent: 0)`.
  @Test func aPausedRowShowsThePercentItReached() async throws {
    let container = try pauseContainer("pause")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    let task = try await startAt42Percent(manager, itemId: "mv-p1")

    systemPause(manager, task: task)

    #expect(await pauseEventually { manager.isPaused(itemId: "mv-p1") })
    #expect(manager.rowState(for: "mv-p1") == .paused(percent: 42))
    #expect(manager.rowState(for: "mv-p1").detail == "42%")
    #expect(abs((manager.downloadProgress["mv-p1"] ?? 0) - 0.42) < 0.0001, "the bar keeps its length")
  }

  /// The same row after the app is relaunched: the percent is part of what is persisted for an
  /// unfinished download. Red if the progress is not written with the metadata.
  @Test func aPausedRowStillShowsItsPercentAfterARelaunch() async throws {
    let container = try pauseContainer("relaunch")
    defer { try? FileManager.default.removeItem(at: container) }
    let first = DownloadManager(containerForTesting: container)
    let task = try await startAt42Percent(first, itemId: "mv-p2")
    systemPause(first, task: task)
    #expect(await pauseEventually { first.isPaused(itemId: "mv-p2") })

    let again = DownloadManager(containerForTesting: container)

    #expect(again.isPaused(itemId: "mv-p2"))
    #expect(again.rowState(for: "mv-p2") == .paused(percent: 42))
  }

  /// AC: cancelling a paused row clears its progress and bytes. Red if `cancelDownload` clears
  /// progress only for an ACTIVE download, which a paused one is not.
  @Test func cancellingAPausedRowClearsItsProgress() async throws {
    let container = try pauseContainer("cancel")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    let task = try await startAt42Percent(manager, itemId: "mv-p3")
    systemPause(manager, task: task)
    #expect(await pauseEventually { manager.isPaused(itemId: "mv-p3") })

    manager.cancelDownload(itemId: "mv-p3")

    #expect(manager.downloadProgress["mv-p3"] == nil)
    #expect(manager.downloadBytes["mv-p3"] == nil)
    #expect(!manager.isPaused(itemId: "mv-p3"))
    #expect(DownloadManager(containerForTesting: container).rowState(for: "mv-p3") != .paused(percent: 42),
            "nothing of it is persisted either")
  }

  /// AC: a stop that leaves nothing to resume is a failure and clears progress and bytes.
  @Test func aStopWithNothingToResumeClearsItsProgress() async throws {
    let container = try pauseContainer("fail")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    let task = try await startAt42Percent(manager, itemId: "mv-p4")

    manager.urlSession(URLSession.shared, task: task, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))

    #expect(await pauseEventually { manager.failedDownloads["mv-p4"] != nil })
    #expect(manager.downloadProgress["mv-p4"] == nil)
    #expect(manager.downloadBytes["mv-p4"] == nil)
  }

  /// AC: sign-out (clearAll) clears a paused row's progress and bytes along with everything else.
  @Test func signOutClearsAPausedRowsProgress() async throws {
    let container = try pauseContainer("signout")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    let task = try await startAt42Percent(manager, itemId: "mv-p5")
    systemPause(manager, task: task)
    #expect(await pauseEventually { manager.isPaused(itemId: "mv-p5") })

    manager.clearAll()

    #expect(manager.downloadProgress.isEmpty)
    #expect(manager.downloadBytes.isEmpty)
    #expect(DownloadManager(containerForTesting: container).downloadProgress.isEmpty)
  }

  /// AC: a completed download clears its progress and bytes.
  @Test func completionClearsProgress() async throws {
    let container = try pauseContainer("done")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    let task = try await startAt42Percent(manager, itemId: "mv-p6")
    let delivered = container.appendingPathComponent("delivered.tmp")
    try Data("finished-movie-bytes".utf8).write(to: delivered)

    manager.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: delivered)

    #expect(await pauseEventually { manager.isDownloaded(itemId: "mv-p6") })
    #expect(manager.downloadProgress["mv-p6"] == nil)
    #expect(manager.downloadBytes["mv-p6"] == nil)
  }
}
