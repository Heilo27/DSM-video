import Testing
import Foundation
@testable import DSM_Video

// MARK: - Oracle core · Continue Watching (FRD-001 FR-016, FR-017, FR-018, FR-021)
//
// OC-1029  membership is exactly the in-progress set, most recently watched first
// OC-1030  nothing in progress -> the rail's data is empty (the views draw no rail for an empty list)
// OC-1031  Mark as Watched / Unwatched take a title out of the rail
// OC-1035  a show contributes one entry, naming the episode that is partly watched
//
// Observed at the layer the user reads: the rail the on-device store hands the Home screen
// (LocalStore.queryRails().continueWatching), read from rows a separate write path stored.
// Every expected value is a literal written from the FRD, never computed from the rule.

@MainActor
private func cwTempDir() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-cw-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private let cwProfile = "pf_cw"
private let cwOther = "pf_other"

private func cwItem(_ id: String, show: String? = nil, folder: String? = nil,
                    season: Int? = nil, episode: Int? = nil) -> ItemSummary {
  ItemSummary(
    id: id, type: show == nil && folder == nil ? "movie" : "episode", title: "Title \(id)",
    year: 2020, durationSeconds: 7200, addedAt: "2026-01-01T00:00:00Z",
    showName: show, showFolderId: folder, seasonNumber: season, episodeNumber: episode,
    libraryId: "lib_cw", changeSeq: 1, ageLevel: 1)
}

/// The duration every row uses: 7200s. 5% = 360s. 95% = 6840s. 90s from the end = 7110s.
private func cwProgress(_ pos: Int, at updatedAt: String) -> ItemProgress {
  ItemProgress(positionSeconds: pos, durationSeconds: 7200, updatedAt: updatedAt)
}

@MainActor
private func cwStore(dir: URL, items: [ItemSummary],
                     progress: [String: ItemProgress],
                     profile: String = cwProfile) async -> LocalStore {
  let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
  await store.upsertItems(items)
  await store.upsertProgress(progress, profileID: profile)
  await store.setActiveProfile(ProfileScope(id: profile, maxAgeLevel: ProfileScope.unrestrictedLevel))
  return store
}

@MainActor
@Suite("FR-016/017/018/021 · Continue Watching rail")
struct ContinueWatchingRailTests {

  // OC-1029 · given titles at 0%, in progress (several, watched at different times) and complete,
  // when Continue Watching is read, then it holds exactly the in-progress titles, newest watch first.
  // Red if: the rail's ORDER BY p.updated_at DESC becomes ASC or is dropped (order assertion), the
  // WHERE sqlIsInProgress filter is dropped (a finished or untouched title joins), or the rail is
  // cut to fewer than all in-progress titles (set equality).
  @Test func membershipIsExactlyTheInProgressTitlesNewestWatchFirst() async throws {
    let dir = try cwTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = await cwStore(
      dir: dir,
      items: ["unwatched", "early", "latest", "middle", "finished"].map { cwItem($0) },
      progress: [
        // "unwatched" has no row at all.
        "early":    cwProgress(1800, at: "2026-10-01T09:00:00Z"),
        "latest":   cwProgress(3600, at: "2026-10-03T09:00:00Z"),
        "middle":   cwProgress(900,  at: "2026-10-02T09:00:00Z"),
        "finished": cwProgress(7000, at: "2026-10-04T09:00:00Z"),  // newest write, but complete
      ])

    let rail = await store.queryRails().continueWatching

    #expect(rail.map(\.id) == ["latest", "middle", "early"])
  }

  // OC-1029 boundaries · 0 / 1 / max / max+1 of the in-progress band, from PlaybackProgress:
  // started at 5% (360s of 7200), finished above 95% (6840s is still in progress, 6841s is not),
  // and the last 90 seconds count as finished whatever the ratio.
  // Red if: either threshold moves by one second, or the rail and the playback rule disagree.
  @Test(arguments: [
    (0,    false), // never started
    (359,  false), // 4.99%: below the started threshold
    (360,  true),  // exactly 5%
    (6840, true),  // exactly 95%: not yet finished
    (6841, false), // one second past 95%: finished
  ])
  func theEdgesOfTheInProgressBand(position: Int, inRail: Bool) async throws {
    let dir = try cwTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = await cwStore(
      dir: dir, items: [cwItem("edge")],
      progress: ["edge": cwProgress(position, at: "2026-10-01T09:00:00Z")])

    let rail = await store.queryRails().continueWatching

    #expect(rail.map(\.id) == (inRail ? ["edge"] : []))
  }

  // OC-1030 · given a profile with zero in-progress titles, when Home is read, then the rail's
  // content is empty: no placeholder entry, no error. (LibrariesView and TVMainView draw the rail
  // only under `if !homeContinueWatching.isEmpty`; that guard is a view-level fact this unit test
  // cannot see, see the ticket.) Titles that are only finished or untouched must not leak in.
  // Red if: a finished or untouched title is let into the rail.
  @Test func withNothingInProgressTheRailIsEmpty() async throws {
    let dir = try cwTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = await cwStore(
      dir: dir, items: [cwItem("fresh"), cwItem("done")],
      progress: ["done": cwProgress(7200, at: "2026-10-01T09:00:00Z")])

    let rail = await store.queryRails().continueWatching

    #expect(rail.isEmpty)
  }

  // OC-1031 · given T in progress at 40%, when it is marked watched (position = duration, how
  // AppState.setWatched writes it) then T leaves Continue Watching and reads as finished; marked
  // unwatched (position 0) it is not in the rail either; the neighbour is untouched.
  // Red if: setWatched's two writes stop being read as finished / cleared by the rail query.
  @Test func markingWatchedOrUnwatchedTakesTheTitleOutOfTheRail() async throws {
    let dir = try cwTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = await cwStore(
      dir: dir, items: [cwItem("t"), cwItem("neighbour")],
      progress: [
        "t":         cwProgress(2880, at: "2026-10-01T09:00:00Z"),  // 40%
        "neighbour": cwProgress(1800, at: "2026-10-01T08:00:00Z"),
      ])
    #expect(await store.queryRails().continueWatching.map(\.id) == ["t", "neighbour"])

    await store.upsertSingleProgress(itemId: "t", positionSeconds: 7200, durationSeconds: 7200)

    let afterWatched = await store.queryRails()
    #expect(afterWatched.continueWatching.map(\.id) == ["neighbour"])
    #expect(afterWatched.recentlyWatched.map(\.id) == ["t"])
    #expect(await store.getProgressSeconds(itemId: "t") == 0, "a finished title has no resume point")

    await store.upsertSingleProgress(itemId: "t", positionSeconds: 0, durationSeconds: 7200)

    let afterUnwatched = await store.queryRails()
    #expect(afterUnwatched.continueWatching.map(\.id) == ["neighbour"])
    #expect(afterUnwatched.recentlyWatched.isEmpty)
  }

  // OC-1035 · given a show with S2E3 partially watched and other episodes watched, when Continue
  // Watching is read, then there is exactly one entry for the show and it is S2E3.
  // Red if: dedup-by-show is removed from queryContinueWatching (the finished S2E2 is already
  // excluded, so only the second in-progress episode would add a row), or the dedup keeps the
  // OLDER episode instead of the most recently watched.
  @Test func aShowContributesOneEntryNamingTheEpisodeBeingWatched() async throws {
    let dir = try cwTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = await cwStore(
      dir: dir,
      items: [
        cwItem("s2e1", show: "Severance", season: 2, episode: 1),
        cwItem("s2e2", show: "Severance", season: 2, episode: 2),
        cwItem("s2e3", show: "Severance", season: 2, episode: 3),
        cwItem("s2e4", show: "Severance", season: 2, episode: 4),
        cwItem("other-show-ep", show: "Andor", season: 1, episode: 1),
        cwItem("film"),
      ],
      progress: [
        "s2e1": cwProgress(7200, at: "2026-10-01T09:00:00Z"),  // watched
        "s2e2": cwProgress(7200, at: "2026-10-02T09:00:00Z"),  // watched
        "s2e3": cwProgress(2400, at: "2026-10-05T09:00:00Z"),  // partly watched, most recent
        "s2e4": cwProgress(1200, at: "2026-10-03T09:00:00Z"),  // also partly watched, earlier
        "other-show-ep": cwProgress(1000, at: "2026-10-04T09:00:00Z"),
        "film": cwProgress(500, at: "2026-10-02T12:00:00Z"),
      ])

    let rail = await store.queryRails().continueWatching

    #expect(rail.map(\.id) == ["s2e3", "other-show-ep", "film"])
  }

  // OC-1035 · a show whose episodes carry no show name (metadata never fetched) is one show by its
  // folder; two shows that merely share a prefix stay two entries; the match ignores case.
  // Red if: the showFolderId fallback or the case-fold in the dedup key is removed.
  @Test func showsWithoutANameDedupByFolderAndDistinctShowsStaySeparate() async throws {
    let dir = try cwTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = await cwStore(
      dir: dir,
      items: [
        cwItem("a1", folder: "folder-a", season: 1, episode: 1),
        cwItem("a2", folder: "folder-a", season: 1, episode: 2),
        cwItem("b1", folder: "folder-b", season: 1, episode: 1),
        cwItem("c1", show: "Lost", season: 1, episode: 1),
        cwItem("c2", show: "LOST", season: 1, episode: 2),
        cwItem("d1", show: "Lost Girl", season: 1, episode: 1),
      ],
      progress: [
        "a1": cwProgress(1000, at: "2026-10-01T01:00:00Z"),
        "a2": cwProgress(1000, at: "2026-10-01T02:00:00Z"),
        "b1": cwProgress(1000, at: "2026-10-01T03:00:00Z"),
        "c1": cwProgress(1000, at: "2026-10-01T04:00:00Z"),
        "c2": cwProgress(1000, at: "2026-10-01T05:00:00Z"),
        "d1": cwProgress(1000, at: "2026-10-01T06:00:00Z"),
      ])

    let rail = await store.queryRails().continueWatching

    #expect(rail.map(\.id) == ["d1", "c2", "b1", "a2"])
  }

  // FR-013 + FR-016 · another profile's in-progress titles never appear in this profile's rail.
  // Red if: the progress join loses `p.profile_id = ?1`.
  @Test func anotherProfilesProgressNeverAppears() async throws {
    let dir = try cwTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = await cwStore(
      dir: dir, items: [cwItem("mine"), cwItem("theirs")],
      progress: ["mine": cwProgress(1000, at: "2026-10-01T09:00:00Z")])
    await store.upsertProgress(["theirs": cwProgress(1000, at: "2026-10-02T09:00:00Z")], profileID: cwOther)

    let rail = await store.queryRails().continueWatching

    #expect(rail.map(\.id) == ["mine"])
  }
}
