import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-986 · the offline Just Added stand-in follows the server's rule (FRD-001 FR-088)
//
// Server rule (backend justadded.go queryJustAdded): newest by added_at, visible to the profile,
// one entry per show, at most 16, NO progress filter. LocalStore.queryJustAdded used to drop any
// title the profile had started or finished, so a film added yesterday and half watched was on the
// rail online and gone offline.

@MainActor
private func jaStore(items: [ItemSummary], progress: [String: ItemProgress]) async throws -> (LocalStore, URL) {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-ja-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
  await store.upsertItems(items)
  await store.upsertProgress(progress, profileID: "pf_ja")
  await store.setActiveProfile(ProfileScope(id: "pf_ja", maxAgeLevel: ProfileScope.unrestrictedLevel))
  return (store, dir)
}

private func jaItem(_ id: String, type: String = "movie", added: String, show: String? = nil,
                    folder: String? = nil, duration: Int = 7200) -> ItemSummary {
  ItemSummary(
    id: id, type: type, title: id, durationSeconds: duration, addedAt: added,
    showName: show, showFolderId: folder, seasonNumber: show == nil ? nil : 1,
    episodeNumber: show == nil ? nil : 1, libraryId: "lib_ja", changeSeq: 1, ageLevel: 1)
}

@MainActor
private func jaWithProgress(_ i: ItemSummary, _ p: ItemProgress) -> ItemSummary {
  ItemSummary(
    id: i.id, type: i.type, title: i.title, year: i.year, durationSeconds: i.durationSeconds,
    addedAt: i.addedAt, progress: p, showName: i.showName, showFolderId: i.showFolderId,
    seasonNumber: i.seasonNumber, episodeNumber: i.episodeNumber, libraryId: i.libraryId,
    changeSeq: i.changeSeq, ageLevel: i.ageLevel)
}

@MainActor
struct JustAddedOfflineTests {

  /// A watched title and a half-watched film are listed, a show appears once as its NEWEST episode
  /// (here a watched one), and the list is capped at 16. Red if a progress filter comes back:
  /// m_watched, m_half and e1 would all be missing.
  @Test func startedAndFinishedTitlesStayOnTheRailCappedAtSixteenOnePerShow() async throws {
    var items = [
      jaItem("m_watched", added: "2026-10-10T00:00:00Z"),
      jaItem("m_half", added: "2026-10-09T00:00:00Z"),
      jaItem("e1", type: "episode", added: "2026-10-08T00:00:00Z", show: "Foundation", folder: "f1", duration: 1320),
      jaItem("e2", type: "episode", added: "2026-10-07T00:00:00Z", show: "Foundation", folder: "f1", duration: 1320),
    ]
    for n in 0..<20 {
      items.append(jaItem(String(format: "old%02d", n), added: String(format: "2026-09-%02dT00:00:00Z", n + 1)))
    }
    let progress: [String: ItemProgress] = [
      "m_watched": ItemProgress(positionSeconds: 7200, durationSeconds: 7200, updatedAt: "2026-10-11T09:00:00Z"),
      "m_half": ItemProgress(positionSeconds: 3600, durationSeconds: 7200, updatedAt: "2026-10-11T09:00:00Z"),
      "e1": ItemProgress(positionSeconds: 1320, durationSeconds: 1320, updatedAt: "2026-10-11T09:00:00Z"),
    ]
    let (store, dir) = try await jaStore(items: items, progress: progress)
    defer { try? FileManager.default.removeItem(at: dir) }

    let ids = await store.queryRails().justAdded.map(\.id)

    #expect(Array(ids.prefix(3)) == ["m_watched", "m_half", "e1"])
    #expect(!ids.contains("e2"), "one entry per show")
    #expect(ids.count == 16)
    #expect(ids[3] == "old19", "then the newest of the rest")
  }

  /// A title with no progress row at all is unaffected, and a profile-scoped row for ANOTHER
  /// profile does not matter either way.
  @Test func anotherProfilesProgressDoesNotChangeTheRail() async throws {
    let items = [jaItem("a", added: "2026-10-10T00:00:00Z"), jaItem("b", added: "2026-10-09T00:00:00Z")]
    let (store, dir) = try await jaStore(items: items, progress: [:])
    defer { try? FileManager.default.removeItem(at: dir) }
    await store.upsertProgress(
      ["a": ItemProgress(positionSeconds: 7200, durationSeconds: 7200, updatedAt: "2026-10-11T09:00:00Z")],
      profileID: "pf_someone_else")

    #expect(await store.queryRails().justAdded.map(\.id) == ["a", "b"])
  }
}

// MARK: - TASK-1019 · the demo library's Just Added is the same rail as the offline one (FR-088)
//
// AppState.computeHomeRails (the demo library) kept a watched filter and its own dedup after
// TASK-986 took both out of LocalStore.queryJustAdded. Both now call ItemSummary.justAddedRail.

@MainActor
struct JustAddedSharedRuleTests {

  private static func library() -> (items: [ItemSummary], progress: [String: ItemProgress]) {
    var items = [
      jaItem("m_watched", added: "2026-10-10T00:00:00Z"),
      jaItem("m_half", added: "2026-10-09T00:00:00Z"),
      jaItem("e1", type: "episode", added: "2026-10-08T00:00:00Z", show: "Foundation", folder: "f1", duration: 1320),
      jaItem("e2", type: "episode", added: "2026-10-07T00:00:00Z", show: "Foundation", folder: "f1", duration: 1320),
      jaItem("fresh", added: "2026-10-06T00:00:00Z"),
    ]
    for n in 0..<20 {
      items.append(jaItem(String(format: "old%02d", n), added: String(format: "2026-09-%02dT00:00:00Z", n + 1)))
    }
    let progress: [String: ItemProgress] = [
      "m_watched": ItemProgress(positionSeconds: 7200, durationSeconds: 7200, updatedAt: "2026-10-11T09:00:00Z"),
      "m_half": ItemProgress(positionSeconds: 3600, durationSeconds: 7200, updatedAt: "2026-10-11T09:00:00Z"),
      "e1": ItemProgress(positionSeconds: 1320, durationSeconds: 1320, updatedAt: "2026-10-11T09:00:00Z"),
    ]
    return (items, progress)
  }

  /// The demo rail keeps a finished film, a half-watched film and a finished episode, one entry for
  /// the show, newest first, 16 long. Red before the fix: the watched filter dropped the first three.
  @Test func demoJustAddedHasNoWatchedFilter() {
    let (items, progress) = Self.library()
    let withProgress = items.map { item in
      progress[item.id].map { jaWithProgress(item, $0) } ?? item
    }

    let ids = AppState.computeHomeRails(withProgress).justAdded.map(\.id)

    #expect(Array(ids.prefix(4)) == ["m_watched", "m_half", "e1", "fresh"])
    #expect(!ids.contains("e2"))
    #expect(ids.count == 16)
  }

  /// The same library through the offline store and through the demo path gives the same ids.
  @Test func offlineAndDemoRailsAreTheSameList() async throws {
    let (items, progress) = Self.library()
    let (store, dir) = try await jaStore(items: items, progress: progress)
    defer { try? FileManager.default.removeItem(at: dir) }
    let offline = await store.queryRails().justAdded.map(\.id)

    let demo = AppState.computeHomeRails(items.map { item in
      progress[item.id].map { jaWithProgress(item, $0) } ?? item
    }).justAdded.map(\.id)

    #expect(demo == offline)
    #expect(!demo.isEmpty)
  }
}
