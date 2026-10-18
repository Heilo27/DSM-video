import Foundation
import Testing
@testable import DSM_Video

// MARK: - Cancelling an in-flight download leaves nothing behind (TASK-967 · OC-1048 · FR-030..043)
//
// Cancel is the destructive path of the Downloads surface: the user stops a transfer and expects
// the title to be as if never started. Observed at the layer the user reads (the row state, the
// failure list, the downloaded list, the files on disk) and again through a FRESH manager on the
// same container, which is what the next launch reads. The expected side is literals only.

private func makeContainer(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-cancel-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Nothing listens on the discard port, so the transfer goes nowhere.
private let deadURL = URL(string: "http://127.0.0.1:9/stream.mp4")!

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<200 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// Every regular file under the container, as paths relative to it.
private func filesUnder(_ container: URL) -> [String] {
  guard let walker = FileManager.default.enumerator(
    at: container, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
  var found: [String] = []
  for case let url as URL in walker {
    if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
      found.append(String(url.path.dropFirst(container.path.count)))
    }
  }
  return found.sorted()
}

@MainActor
struct DownloadCancelTests {

  private func start(_ manager: DownloadManager, _ id: String, session: String? = nil) {
    manager.startDownload(itemId: id, title: "Film \(id)", year: 2020, videoURL: deadURL,
                          posterURL: nil, token: nil, durationSeconds: 5400, ageLevel: 2,
                          playbackSessionID: session)
  }

  /// OC-1048 · given two downloads in flight, when the user cancels one, then that title has no
  /// active row, no progress, no failure entry (a cancel is not an error), is not downloaded, and
  /// has no file or metadata on disk, while the other title is still downloading untouched; the
  /// playback session of the cancelled one is released exactly once.
  /// Red if: cancelDownload leaves the entry in activeDownloads, leaves progress or the persisted
  /// metadata behind, drops the session release, or touches the other title.
  @Test func cancellingAnActiveDownloadRemovesItAndOnlyIt() throws {
    let container = try makeContainer("active")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    var released: [String] = []
    manager.releaseSessionProvider = { released.append($0) }
    start(manager, "mv-a", session: "sid-a")
    start(manager, "mv-b", session: "sid-b")
    #expect(manager.activeDownloads.count == 2, "precondition: two transfers in flight")

    manager.cancelDownload(itemId: "mv-a")

    #expect(manager.activeDownloads.count == 1)
    #expect(manager.activeDownloads["mv-a"] == nil)
    #expect(manager.activeDownloads["mv-b"] != nil, "the survivor keeps downloading")
    #expect(manager.downloadProgress["mv-a"] == nil)
    #expect(manager.downloadProgress["mv-b"] == 0, "the survivor keeps its row")
    #expect(manager.failedDownloads.isEmpty)
    #expect(!manager.isDownloaded(itemId: "mv-a"))
    #expect(manager.getDownloadedItems().isEmpty)
    #expect(released == ["sid-a"])
    #expect(manager.rowState(for: "mv-a") == manager.rowState(for: "never-started"),
            "a cancelled title reads exactly like one never started")
  }

  /// OC-1048 · given a cancelled download, when the system delivers the transfer's cancel
  /// callback afterwards (it always does), then the callback is ignored: still no failure entry
  /// and no row. The user cancelled; "Download cancelled" must not appear as an error.
  /// Red if: the cancelled task keeps its item label or stays in the task map, so the late
  /// callback is attributed to the title and raised as a failed download.
  @Test func theLateCancelCallbackDoesNotBecomeAFailure() async throws {
    let container = try makeContainer("late")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    start(manager, "mv-late")
    let task = try #require(manager.activeDownloads["mv-late"]?.task)

    manager.cancelDownload(itemId: "mv-late")
    manager.urlSession(URLSession.shared, task: task, didCompleteWithError:
      NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
    // The callback hops to the main actor in a Task: give it every chance to run.
    try await Task.sleep(for: .milliseconds(300))

    #expect(manager.failedDownloads.isEmpty)
    #expect(manager.activeDownloads.isEmpty)
    #expect(!manager.isFailed(itemId: "mv-late"))
    #expect(manager.rowState(for: "mv-late") == manager.rowState(for: "never-started"))
  }

  /// OC-1048 (destructive path, persistence) · given a cancelled download, when the app is
  /// relaunched (a fresh manager on the same container), then the title is not active, paused,
  /// failed or downloaded, and the container holds no file for it: no resume blob, no partial
  /// video. A different title that was paused stays recoverable, so cancel did not wipe the store.
  /// Red if: cancel leaves its metadata in pausedMeta.json (the next launch would resurrect the
  /// transfer), leaves a resume blob, or clears more than the one title.
  @Test func aCancelledDownloadDoesNotComeBackAfterRelaunch() async throws {
    let container = try makeContainer("relaunch")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    start(manager, "mv-cancel", session: "sid-cancel")
    start(manager, "mv-keep", session: "sid-keep")
    let beforeCancel = filesUnder(container)
    #expect(beforeCancel.contains("/pausedMeta.json"), "precondition: in-flight metadata is persisted")

    manager.cancelDownload(itemId: "mv-cancel")

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.activeDownloads["mv-cancel"] == nil)
    #expect(relaunched.pausedDownloads["mv-cancel"] == nil)
    #expect(relaunched.failedDownloads["mv-cancel"] == nil)
    #expect(relaunched.getDownloadedItem(itemId: "mv-cancel") == nil)
    #expect(filesUnder(container).filter { $0.contains("mv-cancel") }.isEmpty,
            "no partial or resume file named for the cancelled title")

    let meta = try Data(contentsOf: container.appendingPathComponent("pausedMeta.json"))
    let text = String(decoding: meta, as: UTF8.self)
    #expect(!text.contains("mv-cancel"), "the persisted metadata no longer names the cancelled title")
    #expect(text.contains("mv-keep"), "the other in-flight title's metadata survives the cancel")
  }

  /// OC-1048 boundary · given a title that is not downloading at all, when cancel is requested
  /// (a double tap, or a row that just finished), then nothing changes and nothing throws: the
  /// downloaded title stays downloaded and the other in-flight title stays active.
  /// Red if: cancelDownload on an unknown id disturbs other titles' state.
  @Test func cancellingATitleThatIsNotDownloadingChangesNothing() throws {
    let container = try makeContainer("noop")
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    start(manager, "mv-live")

    manager.cancelDownload(itemId: "never-started")
    manager.cancelDownload(itemId: "never-started")

    #expect(manager.activeDownloads.count == 1)
    #expect(manager.activeDownloads["mv-live"] != nil)
    #expect(manager.failedDownloads.isEmpty)
  }
}
