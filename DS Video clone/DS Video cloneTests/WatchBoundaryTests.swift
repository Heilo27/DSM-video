import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-962 · one "finished" rule for the rail, the show page and playback
//
// FRD-001 FR-011 (resume), FR-016 (Continue Watching holds titles strictly between zero and
// complete), FR-018. Three readers of the same progress row had two answers:
//   - the Continue Watching / Recently Watched SQL in LocalStore,
//   - PlaybackProgress.resumable (playback restarts a finished title from 0),
//   - PlaybackProgress.watchState (the show page's Resume-or-advance decision).
// A 22-minute episode stopped at 1240s (93.9%, 80s left) was finished to the first two and
// "in progress" to the third. Expected values below are literals written from the FRD and the
// ticket; the table test then holds all three readers to each other on every boundary.

@MainActor
private func wbStore(position: Int, duration: Int) async throws -> (LocalStore, URL) {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-wb-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
  let item = ItemSummary(
    id: "edge", type: "movie", title: "Edge", year: 2020, durationSeconds: duration,
    addedAt: "2026-01-01T00:00:00Z", showName: nil, showFolderId: nil, seasonNumber: nil,
    episodeNumber: nil, libraryId: "lib_wb", changeSeq: 1, ageLevel: 1)
  await store.upsertItems([item])
  await store.upsertProgress(
    ["edge": ItemProgress(positionSeconds: position, durationSeconds: duration,
                          updatedAt: "2026-10-01T09:00:00Z")],
    profileID: "pf_wb")
  await store.setActiveProfile(ProfileScope(id: "pf_wb", maxAgeLevel: ProfileScope.unrestrictedLevel))
  return (store, dir)
}

@MainActor
@Suite("TASK-962 · one finished rule")
struct WatchBoundaryTests {

  /// The ticket's literal inputs. Red if watchState goes back to the fraction alone:
  /// (1240,1320) and (1254,1320) come back `.inProgress`/`.watched` inconsistently with
  /// isFinished, and the first is `.inProgress`.
  @Test(arguments: [
    (1240, 1320, PlaybackProgress.WatchState.watched),    // 93.9%, 80s left: finished by the 90s rule
    (1254, 1320, .watched),                                // 95.0%, 66s left
    (600,  1320, .inProgress),                             // 45%
    (66,   1320, .inProgress),                             // exactly 5%
    (65,   1320, .unwatched),                              // just under 5%
    (50,   1320, .unwatched),
    (0,    1320, .unwatched),
    (6840, 7200, .inProgress),                             // exactly 95% on a long film: not finished
    (6841, 7200, .watched),                                // one second past
    (1230, 1320, .inProgress),                             // 93.2%, 90s left exactly: `< 90` is not met
    (1231, 1320, .watched),                                // 93.3%, 89s left: the 90s clause alone
    (500,  0,    .unwatched),                              // unknown runtime
  ])
  func literalClassifications(position: Int, duration: Int, expected: PlaybackProgress.WatchState) {
    #expect(PlaybackProgress.watchState(positionSeconds: position, durationSeconds: duration) == expected)
  }

  /// Every boundary, every reader, one answer. For each (position, duration) the same progress
  /// row is stored and read back through the rail queries, then compared with watchState and
  /// resumable. Red if the SQL, isFinished or watchState drift apart by even one second, or if a
  /// row at position 0 on a clip under 90s lands in Recently Watched.
  @Test func railShowPageAndPlaybackAgreeOnEveryBoundary() async throws {
    let cases: [(Int, Int)] = [
      (0, 1320), (1, 1320), (65, 1320), (66, 1320), (67, 1320), (600, 1320),
      (1229, 1320), (1230, 1320), (1231, 1320), (1240, 1320), (1253, 1320), (1254, 1320),
      (1255, 1320), (1320, 1320),
      (0, 7200), (359, 7200), (360, 7200), (6840, 7200), (6841, 7200),
      (7109, 7200), (7110, 7200), (7111, 7200), (7200, 7200),
      (0, 60), (3, 60), (30, 60),
    ]
    for (position, duration) in cases {
      let (store, dir) = try await wbStore(position: position, duration: duration)
      defer { try? FileManager.default.removeItem(at: dir) }
      let rails = await store.queryRails()
      let inContinue = rails.continueWatching.contains { $0.id == "edge" }
      let inRecent = rails.recentlyWatched.contains { $0.id == "edge" }
      let state = PlaybackProgress.watchState(positionSeconds: position, durationSeconds: duration)
      let resumes = PlaybackProgress.resumable(positionSeconds: position, durationSeconds: duration)

      #expect(inContinue == (state == .inProgress), "rail vs watchState at \(position)/\(duration)")
      #expect(inRecent == (state == .watched), "recently-watched vs watchState at \(position)/\(duration)")
      #expect(!(inContinue && inRecent), "one row in both rails at \(position)/\(duration)")
      #expect((resumes == 0 && position > 0) == (state == .watched),
              "playback restart vs watchState at \(position)/\(duration)")
    }
  }

  /// The ticket's scenario on the show page: episode 1 stopped at 1240/1320 (finished), episode 2
  /// never opened. The page offers episode 2 as Play, not episode 1 as Resume.
  /// Red if showResumePick (or watchState under it) classifies 1240/1320 as in progress.
  @Test func finishedEpisodeAdvancesTheShowToTheNextOne() {
    let ep1 = ItemProgress(positionSeconds: 1240, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")

    let pick = PlaybackProgress.showResumePick(progress: [ep1, nil])

    #expect(pick == PlaybackProgress.ShowResumePick(index: 1, isResume: false))
  }

  /// The complement: 600/1320 is a real resume point, and it resumes ITSELF.
  @Test func partlyWatchedEpisodeResumesItself() {
    let ep1 = ItemProgress(positionSeconds: 600, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")

    let pick = PlaybackProgress.showResumePick(progress: [ep1, nil])

    #expect(pick == PlaybackProgress.ShowResumePick(index: 0, isResume: true))
  }

  /// A fully watched show has no pick; the callers fall back to episode 1.
  @Test func everythingWatchedHasNoPick() {
    let done = ItemProgress(positionSeconds: 1320, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")

    #expect(PlaybackProgress.showResumePick(progress: [done, done]) == nil)
    #expect(PlaybackProgress.showResumePick(progress: []) == nil)
  }
}
