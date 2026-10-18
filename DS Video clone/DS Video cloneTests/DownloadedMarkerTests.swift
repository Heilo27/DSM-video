import Foundation
import Observation
import Testing
@testable import DSM_Video

// MARK: - Downloaded marker on cards and rows (TASK-983 · FR-041 / FR-133 / FR-134)

/// Records that an observed value changed, from the nonisolated onChange callback.
private final class ChangeFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
  func set() { lock.lock(); value = true; lock.unlock() }
}

@MainActor
struct DownloadedMarkerTests {

  private func makeContainer() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel-marker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Completes a download of `itemId` the way the background session does.
  private func finishDownload(_ manager: DownloadManager, itemId: String, in container: URL) async throws {
    manager.startDownload(itemId: itemId, title: "Marked Film", year: nil,
                          videoURL: URL(string: "http://127.0.0.1:9/stream.mp4")!,
                          posterURL: nil, token: nil, durationSeconds: 60, ageLevel: 1)
    let task = try #require(manager.activeDownloads[itemId]?.task)
    let delivered = container.appendingPathComponent("\(itemId).tmp")
    try Data("movie".utf8).write(to: delivered)
    manager.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: delivered)
    for _ in 0..<300 where !manager.isDownloaded(itemId: itemId) {
      try? await Task.sleep(for: .milliseconds(10))
    }
    try #require(manager.isDownloaded(itemId: itemId), "the fixture download did not complete")
  }

  /// The one mapping every card uses: a local copy wins; without one, only an unreachable
  /// server changes how the card looks. Red if a card ignores the manager (always `.none`) or
  /// the offline dimming is dropped.
  @Test func aCardReflectsTheLocalCopyAndReachability() async throws {
    let container = try makeContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)

    #expect(manager.badgeState(for: "mv-m", offline: false) == .none)
    #expect(manager.badgeState(for: "mv-m", offline: true) == .unavailableOffline,
            "FR-133: offline and not downloaded reads as unavailable")

    try await finishDownload(manager, itemId: "mv-m", in: container)
    #expect(manager.badgeState(for: "mv-m", offline: false) == .downloaded)
    #expect(manager.badgeState(for: "mv-m", offline: true) == .downloaded,
            "a downloaded title is never dimmed offline")
    #expect(manager.badgeState(for: "other", offline: true) == .unavailableOffline,
            "the marker belongs to the title, not to every card")
  }

  /// FR-043: the marker leaves with the file, on the same manager, with no relaunch. Red if the
  /// state is cached outside the manager's manifest.
  @Test func theMarkerGoesWhenTheDownloadIsDeleted() async throws {
    let container = try makeContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    try await finishDownload(manager, itemId: "mv-del", in: container)
    try #require(manager.badgeState(for: "mv-del", offline: false) == .downloaded)

    manager.deleteDownload(itemId: "mv-del")

    #expect(manager.badgeState(for: "mv-del", offline: false) == .none)
    #expect(manager.badgeState(for: "mv-del", offline: true) == .unavailableOffline)
  }

  /// A card body that read the state must be told to redraw when the download is deleted
  /// (FR-134: no relaunch). Red if the manifest the state derives from stops being observed.
  @Test func aRenderedCardIsInvalidatedByTheDelete() async throws {
    let container = try makeContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    try await finishDownload(manager, itemId: "mv-obs", in: container)

    let flag = ChangeFlag()
    withObservationTracking {
      _ = manager.badgeState(for: "mv-obs", offline: false)
    } onChange: {
      flag.set()
    }
    try #require(!flag.fired, "reading the state must not itself invalidate it")

    manager.deleteDownload(itemId: "mv-obs")
    #expect(flag.fired, "the delete must invalidate a body that showed the marker")
  }

  /// A finished download invalidates a card that was showing no marker, so it appears without
  /// leaving the screen.
  @Test func aRenderedCardIsInvalidatedWhenADownloadCompletes() async throws {
    let container = try makeContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)

    let flag = ChangeFlag()
    withObservationTracking {
      _ = manager.badgeState(for: "mv-new", offline: false)
    } onChange: {
      flag.set()
    }
    try await finishDownload(manager, itemId: "mv-new", in: container)
    #expect(flag.fired)
    #expect(manager.badgeState(for: "mv-new", offline: false) == .downloaded)
  }
}
