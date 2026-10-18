import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-1017 · every progress decision reads PlaybackProgress (FRD-001 FR-011, FR-016, FR-020)
//
// The show-page rows, the downloaded-item resume bar and the iOS landscape card each kept a
// threshold of their own, and the show-page scan skipped an episode under 5% altogether. Expected
// values are literals from the FRD: "started" is 5% and up; complete is past 95% or within the last
// 90 seconds; a bar draws for anything above zero that is not complete.

struct ShowResumeScanTests {

  /// An episode sampled for a few seconds (3%) was neither a resume point nor unwatched, so the
  /// scan walked past it and offered the NEXT episode. It is unwatched: it is the pick.
  /// Red before the fix: the pick is index 1.
  @Test func anEpisodeUnderFivePercentIsTheFirstUnwatched() {
    let sampled = ItemProgress(positionSeconds: 40, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")

    #expect(PlaybackProgress.showResumePick(progress: [sampled, nil])
            == PlaybackProgress.ShowResumePick(index: 0, isResume: false))
  }

  /// After a finished episode, a sampled one is still the next thing to play, and a later
  /// episode with no record does not displace it.
  @Test func aSampledEpisodeAfterAFinishedOneIsThePick() {
    let done = ItemProgress(positionSeconds: 1320, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")
    let sampled = ItemProgress(positionSeconds: 10, durationSeconds: 1320, updatedAt: "2026-10-02T09:00:00Z")

    #expect(PlaybackProgress.showResumePick(progress: [done, sampled, nil])
            == PlaybackProgress.ShowResumePick(index: 1, isResume: false))
  }

  /// A real resume point still wins over a sampled episode, wherever the sampled one sits.
  @Test func aRealResumePointStillWins() {
    let sampled = ItemProgress(positionSeconds: 40, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")
    let half = ItemProgress(positionSeconds: 660, durationSeconds: 1320, updatedAt: "2026-10-02T09:00:00Z")

    #expect(PlaybackProgress.showResumePick(progress: [sampled, half, nil])
            == PlaybackProgress.ShowResumePick(index: 1, isResume: true))
  }

  /// Exactly 5% is started (resume), one second under is not.
  @Test func theFivePercentBoundaryIsInclusive() {
    let at = ItemProgress(positionSeconds: 66, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")
    let under = ItemProgress(positionSeconds: 65, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")

    #expect(PlaybackProgress.showResumePick(progress: [at, nil])
            == PlaybackProgress.ShowResumePick(index: 0, isResume: true))
    #expect(PlaybackProgress.showResumePick(progress: [under, nil])
            == PlaybackProgress.ShowResumePick(index: 0, isResume: false))
  }
}

/// The views cannot be rendered in a unit test, so this reads their source: it fails if the show-page
/// rows, the downloaded-item resume bar or the iOS landscape card go back to a fraction and
/// threshold of their own.
struct ProgressSingleSourceTests {

  private static let viewsDirectory: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()           // DS Video cloneTests
    .deletingLastPathComponent()           // DS Video clone
    .appendingPathComponent("DSM Video/DSM Video/Views", isDirectory: true)

  private func source(_ name: String) throws -> String {
    try String(contentsOf: Self.viewsDirectory.appendingPathComponent(name), encoding: .utf8)
  }

  private func count(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
  }

  /// tvOS and iOS episode rows: one cardIndicator each, no watchedThreshold, no private fraction.
  @Test func theEpisodeRowsAskTheSharedFunction() throws {
    let text = try source("TVShowDetailView.swift")
    #expect(count(of: "PlaybackProgress.cardIndicator(for: ep.progress)", in: text) == 2)
    #expect(!text.contains("watchedThreshold"))
    #expect(!text.contains("Double(prog.positionSeconds) / Double(prog.durationSeconds)"))
    #expect(!text.contains("2%"), "the stale 2%-95% scan comments are gone")
  }

  /// The downloaded-item resume bar.
  @Test func theDownloadedResumeBarAsksTheSharedFunction() throws {
    let text = try source("MainView.swift")
    #expect(count(of: "PlaybackProgress.cardIndicator(\n            positionSeconds: resumeSeconds", in: text) == 1)
    #expect(!text.contains("PlaybackProgress.watchedThreshold"))
    #expect(!text.contains("Double(resumeSeconds) / Double(item.durationSeconds)"))
  }

  /// The iOS landscape card's bar.
  @Test func theLandscapeCardBarAsksTheSharedFunction() throws {
    let text = try source("LibrariesView.swift")
    #expect(count(of: "PlaybackProgress.cardIndicator(for: item.progress)", in: text) == 1)
    #expect(!text.contains("if frac < 1.0"))
  }
}
