import Foundation
import Testing
@testable import DSM_Video

// TASK-1010 (FR-070): an autoPlay entry (Home hero Play, a Continue Watching movie, an episode
// opened to play) opened the player from the detail screen's onAppear. onAppear fires again
// every time the screen comes back into view: the player cover closing, a pushed screen popping,
// a tab switch returning. Each return reopened the player the user had just closed.

@Suite("Auto-play once per presentation (TASK-1010)")
@MainActor
struct AutoPlayOnceTests {
  typealias Latch = ItemDetailView.AutoPlayLatch

  /// AC 1. Red if: a second appearance of the same presentation opens the player again.
  @Test func aSecondAppearanceDoesNotReopenThePlayer() {
    var latch = Latch()
    let arrival = latch.shouldOpen(eligible: true)
    let coverClosed = latch.shouldOpen(eligible: true)
    let tabReturn = latch.shouldOpen(eligible: true)
    #expect(arrival, "arrival opens the player")
    #expect(!coverClosed, "the player closed and the screen re-appeared")
    #expect(!tabReturn, "a tab switch back")
  }

  /// AC 2. A new presentation is a new screen with its own state, and auto-plays.
  @Test func aNewPresentationAutoPlays() {
    var first = Latch()
    _ = first.shouldOpen(eligible: true)
    var next = Latch()
    let opened = next.shouldOpen(eligible: true)
    #expect(opened)
  }

  /// Offline on arrival (FR-071): the user lands on the screen with Play disabled. Back online,
  /// returning to that screen must not spring the player on them.
  /// Red if: the latch is only consumed when the player actually opens.
  @Test func arrivingWhilePlaybackIsUnavailableDecidesForThePresentation() {
    var latch = Latch()
    let offlineArrival = latch.shouldOpen(eligible: false)
    let backOnlineReturn = latch.shouldOpen(eligible: true)
    #expect(!offlineArrival)
    #expect(!backOnlineReturn)
  }

  /// Both platform bodies open the player on appear through the latch.
  /// Red if: either onAppear still opens it on `autoPlayOnAppear` alone.
  @Test func bothPlatformBodiesUseTheLatch() throws {
    let file = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("DSM Video/DSM Video/Views/ItemDetailView.swift")
    let source = try String(contentsOf: file, encoding: .utf8)
    #expect(source.components(separatedBy: "autoPlayLatch.shouldOpen(eligible: autoPlayOnAppear)").count - 1 == 2)
    #expect(!source.contains("if autoPlayOnAppear { showPlayer = true }"))
  }
}
