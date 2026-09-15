import XCTest

/// Opening a detail screen must land focus on Play.
///
/// Reported from a real Apple TV: entering an episode focused "Next Episode" instead, and
/// that button rendered comically larger than Play. The two are the same bug seen twice.
///
/// `prefersDefaultFocus(in:)` only decides a winner WITHIN its scope, and the scope wrapped
/// the Play/Start Over/Watchlist/Watched row alone. Next Episode is rendered outside that
/// row, so it never competed against Play's preference — the engine fell back to picking by
/// geometry, and Next Episode was `maxWidth: .infinity` at 64pt tall against Play's 260x54.
/// The biggest target won. So opening an episode put focus on "skip to a DIFFERENT episode"
/// instead of "watch this one", one click away from leaving the thing you just opened.
///
/// These are UI-suite tests rather than assertions about the modifier, because the modifier
/// was already there and already correct in isolation. Only running it proves who wins.
final class TVDetailFocusTests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launched() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestDemoMode"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the tvOS app did not launch")
    return app
  }

  /// Walks into the first show's first episode, or fails saying how far it got.
  ///
  /// Deliberately not silent about giving up: a navigation helper that returns "couldn't get
  /// there" turns every test using it into a pass, which is the failure mode the iOS suite's
  /// rules exist to prevent.
  /// Navigates into an EPISODE detail screen, failing loudly if it cannot get there.
  ///
  /// It must be an episode, not a movie. A movie's detail has no Next Episode button, so a
  /// test that lands on one asserts nothing about the bug and passes vacuously — which the
  /// first version of this file did, including against the reverted code.
  private func openFirstEpisodeDetail(_ app: XCUIApplication) {
    XCTAssertTrue(
      app.buttons.firstMatch.waitForExistence(timeout: 30),
      "No controls on the first screen, so there is nothing to navigate into."
    )

    // Launch focus sits in the top chrome (Settings / Search), and the first content rail is
    // Movies. Go to the TV Shows section explicitly.
    let tvShows = app.buttons["TV Shows"]
    guard tvShows.waitForExistence(timeout: 20) else {
      XCTFail("No TV Shows entry point on the home screen.")
      return
    }
    // Walk focus onto it rather than tapping: tvOS has no pointer, and this also exercises
    // the reachability the rest of the suite cares about.
    for _ in 0..<12 where !tvShows.hasFocus {
      XCUIRemote.shared.press(.down)
      Thread.sleep(forTimeInterval: 0.5)
    }
    if !tvShows.hasFocus {
      for _ in 0..<8 where !tvShows.hasFocus {
        XCUIRemote.shared.press(.right)
        Thread.sleep(forTimeInterval: 0.5)
      }
    }
    XCTAssertTrue(tvShows.hasFocus, "Could not move focus to TV Shows.")
    XCUIRemote.shared.press(.select)
    Thread.sleep(forTimeInterval: 2.5)

    // Into the first show, then into its first episode.
    XCUIRemote.shared.press(.down)
    Thread.sleep(forTimeInterval: 1.0)
    XCUIRemote.shared.press(.select)
    Thread.sleep(forTimeInterval: 2.5)

    // A show detail lists seasons/episodes; select the first episode row.
    XCUIRemote.shared.press(.down)
    Thread.sleep(forTimeInterval: 1.0)
    XCUIRemote.shared.press(.select)
    Thread.sleep(forTimeInterval: 2.5)
  }

  /// The primary action holds focus when a detail screen opens.
  func testPlayHoldsDefaultFocusOnDetail() {
    let app = launched()
    openFirstEpisodeDetail(app)

    let play = app.buttons[UITVID.Detail.playButton]
    guard play.waitForExistence(timeout: 20) else {
      // Not every demo path reaches an item with a Play button; say so rather than passing.
      XCTFail("Never reached a detail screen with a Play button — cannot judge default focus.")
      return
    }

    let focusedNow = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
    let who = focusedNow.count > 0 ? "\(focusedNow.element(boundBy: 0).identifier)|\(focusedNow.element(boundBy: 0).label)|\(focusedNow.element(boundBy: 0).frame)" : "<nothing>"
    XCTAssertTrue(
      play.hasFocus,
      "FOCUSED=\(who) PLAYFRAME=\(play.frame) :: " +
      "Play does not hold focus on open. Whatever the remote would activate first is not "
        + "the action the user came here for — and when Next Episode wins, the first click "
        + "leaves the episode they just opened."
    )
  }

  /// Next Episode must not be the largest control on the screen.
  ///
  /// Size is not cosmetic on tvOS: the focus engine resolves ties by geometry, so an
  /// oversized secondary control does not merely look wrong, it actively competes for the
  /// default focus that belongs to the primary action. Asserting the visual relationship
  /// pins the cause, not just the symptom.
  func testNextEpisodeIsNotLargerThanPlay() {
    let app = launched()
    openFirstEpisodeDetail(app)

    let play = app.buttons[UITVID.Detail.playButton]
    let next = app.buttons[UITVID.Detail.nextEpisodeButton]

    guard play.waitForExistence(timeout: 20) else {
      XCTFail("Never reached a detail screen with a Play button.")
      return
    }
    // NOT an early return. This test exists to compare the two controls, so a screen
    // without a Next Episode button means navigation failed to reach an episode — and a
    // silent return there is exactly how the first version of this test passed against the
    // very code it was written to catch.
    guard next.waitForExistence(timeout: 10) else {
      XCTFail("Reached a detail screen with no Next Episode button, so the sizes cannot be "
              + "compared. Navigation landed on a movie rather than an episode.")
      return
    }

    XCTAssertLessThanOrEqual(
      next.frame.height, play.frame.height,
      "Next Episode (\(Int(next.frame.height))pt tall) is taller than Play "
        + "(\(Int(play.frame.height))pt). The secondary action outweighs the primary one, "
        + "and the larger target competes for default focus."
    )

    XCTAssertLessThan(
      next.frame.width, app.frame.width,
      "Next Episode spans the full screen width. It is a secondary action and should not be "
        + "the largest target on the screen."
    )
  }
}

/// Identifiers mirrored from the app target's `A11y` enum.
///
/// The tvOS UI-test target links nothing from the app, same as the iOS suite, so the values
/// are duplicated here and must agree. See UITestSupport.swift in the iOS suite for the
/// reasoning and the drift guard.
enum UITVID {
  enum Detail {
    static let playButton = "detail.play"
    static let nextEpisodeButton = "detail.nextEpisode"
  }
}
