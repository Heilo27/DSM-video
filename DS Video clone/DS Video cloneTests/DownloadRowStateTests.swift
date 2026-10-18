import Foundation
import Testing
@testable import DSM_Video

// MARK: - In-flight row state (TASK-979 · FR-030)

@MainActor
struct DownloadRowStateTests {

  /// A download accepted but not transferring must not read as one that is. Red if `make`
  /// maps zero received bytes to `.downloading` (the old row showed "0%" for both).
  @Test func queuedDoesNotRenderLikeDownloading() {
    let queued = DownloadRowState.make(isActive: true, isPaused: false, progress: 0,
                                       bytes: TransferBytes(written: 0, expected: 0))
    let noBytesYet = DownloadRowState.make(isActive: true, isPaused: false, progress: 0, bytes: nil)
    let running = DownloadRowState.make(isActive: true, isPaused: false, progress: 0.25,
                                        bytes: TransferBytes(written: 250_000_000, expected: 1_000_000_000))

    #expect(queued == .queued && noBytesYet == .queued)
    #expect(queued != running)
    #expect(queued.detail == "Queued")
    #expect(queued.detail != running.detail)
    #expect(running.detail.hasPrefix("25%"), "percent leads: \(running.detail)")
    #expect(running.detail.contains(" of "), "bytes against the total: \(running.detail)")
  }

  /// FR-030: a total that was never announced still shows what has arrived, and a paused row
  /// keeps its Paused state rather than reading as queued.
  @Test func unknownTotalShowsBytesAndPausedStaysPaused() {
    let unknownTotal = DownloadRowState.make(isActive: true, isPaused: false, progress: 0,
                                             bytes: TransferBytes(written: 5_000_000, expected: -1))
    #expect(unknownTotal.detail != "Queued" && !unknownTotal.detail.contains("%"))

    let paused = DownloadRowState.make(isActive: false, isPaused: true, progress: 0.5, bytes: nil)
    #expect(paused == .paused(percent: 50) && paused.isPaused && !paused.isQueued)
  }

  /// The manager feeds the mapping from the real transfer: queued at enqueue, downloading once
  /// bytes arrive. Red if the byte callback is not recorded.
  @Test func managerMovesFromQueuedToDownloading() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel-rowstate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    manager.startDownload(itemId: "mv-rs", title: "Row Film", year: nil,
                          videoURL: URL(string: "http://127.0.0.1:9/stream.mp4")!,
                          posterURL: nil, token: nil, durationSeconds: 60)
    #expect(manager.rowState(for: "mv-rs") == .queued)

    let task = try #require(manager.activeDownloads["mv-rs"]?.task)
    manager.urlSession(URLSession.shared, downloadTask: task, didWriteData: 100,
                       totalBytesWritten: 100, totalBytesExpectedToWrite: 1000)
    for _ in 0..<200 where manager.rowState(for: "mv-rs") == .queued {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(manager.rowState(for: "mv-rs") == .downloading(percent: 10, bytes: TransferBytes(written: 100, expected: 1000)))
  }
}
