import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-978 · poster-card bar and badge (FRD-001 FR-020)
//
// FR-020: a card shows a progress indicator only when progress is above zero and below complete, and
// a watched badge when complete. tvOS drew a bar for anything under 100%, so a record at position
// zero drew an empty track and a finished title drew a bar next to its badge. Expected values are
// literals from the ticket; "complete" is the TASK-962 rule (past 95%, or within 90 seconds).

struct CardProgressIndicatorTests {

  /// No bar, no track, no badge at position zero. Red if zero reaches the bar branch again.
  @Test func zeroProgressDrawsNothing() {
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 0, durationSeconds: 6000) == .none)
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 0, durationSeconds: 0) == .none)
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 100, durationSeconds: 0) == .none)
    #expect(PlaybackProgress.cardIndicator(for: nil) == .none)
  }

  /// Complete titles get the badge and never a bar, including the 95-100% band where the old tvOS
  /// test (`frac < 1.0`) still drew one, and the last-90-seconds case of a long film.
  @Test func completeTitlesGetTheBadgeAndNoBar() {
    // 96% of 6000s.
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 5760, durationSeconds: 6000) == .watchedBadge)
    // The whole runtime, and past it.
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 6000, durationSeconds: 6000) == .watchedBadge)
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 6100, durationSeconds: 6000) == .watchedBadge)
    // 3-hour film with 80s left (99.3%): complete by the 90-second cap.
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 10720, durationSeconds: 10800) == .watchedBadge)
    // 22-minute episode, 80s left (93.9%): complete by the time cap, as on the rail.
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 1240, durationSeconds: 1320) == .watchedBadge)
  }

  /// Between zero and complete the bar's width is exactly the fraction: no hidden cutoff (iOS used
  /// 2% and 98%), no rounding.
  @Test func inProgressTitlesGetABarOfExactlyTheirFraction() {
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 1, durationSeconds: 100)
            == .bar(fraction: 0.01))
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 3000, durationSeconds: 6000)
            == .bar(fraction: 0.5))
    // 95.000% exactly of 6000s with 300s left: not past 95% and well over 90s remain.
    #expect(PlaybackProgress.cardIndicator(positionSeconds: 5700, durationSeconds: 6000)
            == .bar(fraction: 0.95))
  }

  /// The convenience overload reads the same record the same way.
  @Test func theProgressRecordOverloadAgrees() {
    let record = ItemProgress(positionSeconds: 1500, durationSeconds: 6000, updatedAt: "2026-10-01T09:00:00Z")
    #expect(PlaybackProgress.cardIndicator(for: record) == .bar(fraction: 0.25))
  }

  /// Bar, badge and nothing are exclusive and total over the sweep: a card never shows both, and
  /// the badge comes exactly when `isFinished` says so.
  @Test func theIndicatorAgreesWithTheFinishedRuleEverywhere() {
    for duration in [60, 1320, 6000, 10800] {
      for position in stride(from: 0, through: duration + 10, by: 7) {
        let indicator = PlaybackProgress.cardIndicator(positionSeconds: position, durationSeconds: duration)
        let finished = PlaybackProgress.isFinished(positionSeconds: position, durationSeconds: duration)
        #expect((indicator == .watchedBadge) == finished, "position \(position) of \(duration)")
        if case .bar(let fraction) = indicator {
          #expect(position > 0 && fraction > 0 && fraction < 1 && !finished, "position \(position) of \(duration)")
        }
        if position == 0 { #expect(indicator == .none) }
      }
    }
  }
}

/// The three card views must get their answer from `PlaybackProgress.cardIndicator` and not from a
/// fraction of their own. A view cannot be rendered in a unit test here, so this reads the source:
/// it fails if any card goes back to its own `Double(position) / Double(duration)` bar or badge test.
struct CardIndicatorSingleSourceTests {

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

  /// iOS poster cell: one bar, one badge, and the VoiceOver label.
  @Test func theIOSPosterCellAsksTheSharedFunction() throws {
    let text = try source("ItemsGridView.swift")
    #expect(count(of: "PlaybackProgress.cardIndicator(for: item.progress)", in: text) == 3)
    #expect(!text.contains("frac >= 0.02"), "the iOS card has no private bar cutoff")
    #expect(!text.contains("frac >= PlaybackProgress.watchedThreshold"))
  }

  /// tvOS landscape bar, landscape badge, portrait bar, portrait badge.
  @Test func theTVOSCardsAskTheSharedFunction() throws {
    let text = try source("TVMainView.swift")
    #expect(count(of: "PlaybackProgress.cardIndicator(for: item.progress)", in: text) == 4)
    #expect(!text.contains("if frac < 1.0"), "a tvOS card drew a bar for anything under 100%")
    #expect(!text.contains("frac >= PlaybackProgress.watchedThreshold"))
  }

  /// TASK-1018: the landscape card used to draw a bar and never a badge, so a finished title on a
  /// landscape rail looked untouched. Both tvOS cards draw the one shared badge view.
  @Test func bothTVOSCardsDrawTheWatchedBadge() throws {
    let text = try source("TVMainView.swift")
    let landscapeStart = try #require(text.range(of: "private struct TVLandscapeCard"))
    let portraitStart = try #require(text.range(of: "private struct TVPortraitCard"))
    let landscape = String(text[landscapeStart.lowerBound..<portraitStart.lowerBound])
    let portrait = String(text[portraitStart.lowerBound...])
    #expect(landscape.contains("== .watchedBadge"))
    #expect(landscape.contains("TVCardWatchedBadge("))
    #expect(portrait.contains("TVCardWatchedBadge("))
    #expect(count(of: "private struct TVCardWatchedBadge", in: text) == 1, "one badge view, not one per card")
  }
}
