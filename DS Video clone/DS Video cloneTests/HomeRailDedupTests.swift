import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-963 · one "one entry per show" rule (FRD-001 FR-021)
//
// The live Continue Watching rail (LocalStore.fetchItems) and the demo-mode rails
// (AppState.computeHomeRails) each carried their own show-dedup rule, and they had drifted: the demo
// one keyed on title|type, so two in-progress episodes of one show both appeared. Both now read
// ItemSummary.showDedupKey. These tests run the SAME two episodes through both paths.

private func episode(_ id: String, title: String, show: String?, folder: String?, updatedAt: String)
  -> ItemSummary
{
  ItemSummary(
    id: id, type: "episode", title: title, durationSeconds: 1320, addedAt: "2026-01-01T00:00:00Z",
    progress: ItemProgress(positionSeconds: 600, durationSeconds: 1320, updatedAt: updatedAt),
    showName: show, showFolderId: folder, seasonNumber: 1, episodeNumber: 1,
    libraryId: "lib_dd", changeSeq: 1, ageLevel: 1)
}

@MainActor
struct HomeRailDedupTests {

  /// Red before the fix: computeHomeRails returned both episodes (distinct titles).
  @Test func demoContinueWatchingKeepsOnlyTheNewestEpisodeOfAShow() {
    let older = episode("e1", title: "Pilot", show: "Foundation", folder: "f1", updatedAt: "2026-10-01T09:00:00Z")
    let newer = episode("e2", title: "The Mathematician's Ghost", show: "Foundation", folder: "f1",
                        updatedAt: "2026-10-02T09:00:00Z")
    let other = episode("e3", title: "Pilot", show: "Severance", folder: "f2", updatedAt: "2026-09-30T09:00:00Z")

    let rails = AppState.computeHomeRails([older, newer, other])

    #expect(rails.continueWatching.map(\.id) == ["e2", "e3"])
  }

  /// A show whose name is missing falls back to its folder id, case-insensitively, in both paths.
  @Test func folderIdAloneIdentifiesTheShow() {
    let a = episode("e1", title: "A", show: nil, folder: "Folder-1", updatedAt: "2026-10-01T09:00:00Z")
    let b = episode("e2", title: "B", show: "", folder: "folder-1", updatedAt: "2026-10-02T09:00:00Z")

    #expect(a.showDedupKey == "folder-1")
    #expect(b.showDedupKey == "folder-1")
    #expect(AppState.computeHomeRails([a, b]).continueWatching.map(\.id) == ["e2"])
  }

  /// Movies are not shows: two different movies stay two entries.
  @Test func moviesAreNeverMergedByShow() {
    func movie(_ id: String, _ title: String) -> ItemSummary {
      ItemSummary(
        id: id, type: "movie", title: title, durationSeconds: 7200, addedAt: "2026-01-01T00:00:00Z",
        progress: ItemProgress(positionSeconds: 3600, durationSeconds: 7200, updatedAt: "2026-10-01T09:00:00Z"))
    }
    #expect(movie("m1", "Alien").showDedupKey == nil)
    #expect(AppState.computeHomeRails([movie("m1", "Alien"), movie("m2", "Aliens")]).continueWatching.count == 2)
  }

  /// The two paths agree: the same items give the same Continue Watching ids from the live
  /// LocalStore query and from the demo computation. Red if either grows its own key again.
  @Test func liveRailAndDemoRailPickTheSameEpisodes() async throws {
    let items = [
      episode("e1", title: "Pilot", show: "Foundation", folder: "f1", updatedAt: "2026-10-01T09:00:00Z"),
      episode("e2", title: "Second", show: "foundation", folder: "f1", updatedAt: "2026-10-02T09:00:00Z"),
      episode("e3", title: "Pilot", show: nil, folder: "F2", updatedAt: "2026-09-30T09:00:00Z"),
      episode("e4", title: "Other", show: "", folder: "f2", updatedAt: "2026-09-29T09:00:00Z"),
    ]
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel-dd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
    await store.upsertItems(items.map { item in
      ItemSummary(id: item.id, type: item.type, title: item.title, durationSeconds: item.durationSeconds,
                  addedAt: item.addedAt, showName: item.showName, showFolderId: item.showFolderId,
                  seasonNumber: item.seasonNumber, episodeNumber: item.episodeNumber,
                  libraryId: item.libraryId, changeSeq: item.changeSeq, ageLevel: item.ageLevel)
    })
    var progress: [String: ItemProgress] = [:]
    for item in items { progress[item.id] = item.progress }
    await store.upsertProgress(progress, profileID: "pf_dd")
    await store.setActiveProfile(ProfileScope(id: "pf_dd", maxAgeLevel: ProfileScope.unrestrictedLevel))

    let live = await store.queryRails().continueWatching.map(\.id)
    let demo = AppState.computeHomeRails(items).continueWatching.map(\.id)

    #expect(live == ["e2", "e3"])
    #expect(demo == live)
  }
}
