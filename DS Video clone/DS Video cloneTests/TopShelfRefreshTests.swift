import Foundation
import Testing
@testable import DSM_Video

// TASK-992 · FRD-001 FR-146. The Top Shelf refreshes when Continue Watching changes. tvOS reloads
// the shelf only when the app calls topShelfContentDidChange, and nothing did. The call is behind
// `TopShelfRefresh.notify`; these tests count it while the real writer writes into a file they own.
//
// Every test is synchronous on the main actor, so no other suite can interleave a shelf write while
// `notify` is replaced. Whether the real tvOS call reaches the Home Screen is a device check.

@Suite("Top Shelf refresh", .serialized)
@MainActor
struct TopShelfRefreshTests {

  private func item(_ id: String) -> ItemSummary {
    ItemSummary(id: id, type: "movie", title: "Title \(id)", year: 2024,
                addedAt: "2026-01-01T00:00:00Z", backdropImageId: "img-\(id)",
                progress: ItemProgress(positionSeconds: 1500, durationSeconds: 6000,
                                       updatedAt: "2026-01-01T00:00:00Z"),
                ageLevel: 1)
  }

  private func makeState() -> (AppState, URL) {
    let suite = "TopShelfRefreshTests.\(UUID().uuidString)"
    let store = ActiveProfileStore(defaults: UserDefaults(suiteName: suite)!)
    store.setCachedProfiles([Profile(id: "p-owner", name: "owner", avatar: "fox", maxAgeLevel: 4,
                                     hasPin: false, isOwner: true)])
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TopShelfRefreshTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("topshelf.json")
    let state = AppState(profileStore: store)
    state.topShelfSnapshotURL = url
    return (state, url)
  }

  /// Runs `body` with `notify` counting, and restores the real one.
  private func counting(_ body: (_ calls: () -> Int) -> Void) {
    var calls = 0
    let original = TopShelfRefresh.notify
    TopShelfRefresh.notify = { calls += 1 }
    defer { TopShelfRefresh.notify = original }
    body { calls }
  }

  /// A rail change that changes the shelf tells tvOS once. Red with no call in the writer (0 calls).
  @Test func aChangedShelfIsAnnounced() {
    let (state, url) = makeState()
    counting { calls in
      state.homeContinueWatching = [item("a")]
      #expect(FileManager.default.fileExists(atPath: url.path))
      #expect(calls() == 1)

      state.homeContinueWatching = [item("a"), item("b")]
      #expect(calls() == 2, "new content is announced again")
    }
  }

  /// Rewriting the same shelf neither rewrites the file nor reloads tvOS.
  @Test func anUnchangedShelfIsNotAnnouncedAgain() {
    let (state, _) = makeState()
    counting { calls in
      state.homeContinueWatching = [item("a")]
      #expect(calls() == 1)
      state.writeTopShelfSnapshot()
      state.writeTopShelfSnapshot()
      #expect(calls() == 1)
    }
  }

  /// Emptying the shelf (sign-out, a failed load) removes the file and tells tvOS, so a finished
  /// title does not linger. Removing nothing announces nothing.
  @Test func clearingTheShelfIsAnnouncedOnlyWhenThereWasOne() {
    let (state, url) = makeState()
    counting { calls in
      state.deleteTopShelfSnapshot()
      #expect(calls() == 0, "no file, nothing changed")

      state.homeContinueWatching = [item("a")]
      #expect(calls() == 1)
      state.deleteTopShelfSnapshot()
      #expect(!FileManager.default.fileExists(atPath: url.path))
      #expect(calls() == 2)
    }
  }

  /// Finishing the only title in progress empties the rails; the shelf must be cleared AND announced.
  @Test func finishingTheLastTitleClearsAndAnnouncesTheShelf() {
    let (state, url) = makeState()
    counting { calls in
      state.homeContinueWatching = [item("a")]
      #expect(calls() == 1)
      state.homeContinueWatching = []
      #expect(!FileManager.default.fileExists(atPath: url.path))
      #expect(calls() == 2)
    }
  }
}
