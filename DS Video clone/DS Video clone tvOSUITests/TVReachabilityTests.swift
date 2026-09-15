import XCTest

/// Every control the tvOS app renders must be reachable by the Siri Remote.
///
/// This is the project's most-repeated defect: a Button compiles into the tvOS target,
/// renders, looks live, and can never be focused. It has shipped FIVE times. Each fix
/// addressed one button; the class kept coming back.
///
/// `scripts/check-tvos-focus.sh` guards it statically and says plainly what it cannot do:
/// it locks down the focus ENUMS, because parsing every Button in every view needs a real
/// Swift parser. So an unbound control in a view with no focus enum at all, or a control
/// bound to a case that the d-pad can never actually arrive at, passes CI.
///
/// That gap was believed unclosable here — TASK-885 concluded no focus navigation was
/// possible on this host. It was investigating `idb_companion`, a 2022 build with no Siri
/// Remote support. XCUIRemote works (see TVFocusProbeTests), so the runtime half of the
/// guard is now possible: instead of asking "is every enum case bound?", ask the question
/// that actually matters — "can the remote reach everything on screen?"
///
/// These tests are deliberately about REACHABILITY and not about layout or content. They
/// are the runtime complement to the static script, not a replacement for it.
final class TVReachabilityTests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launched() -> XCUIApplication {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the tvOS app did not launch")
    return app
  }

  /// A stable identity for whatever currently holds focus.
  ///
  /// identifier is frequently empty on tvOS, so it is combined with label and frame: two
  /// genuinely different controls must not collapse to the same string, or a focus trap
  /// would read as successful movement.
  private func focusedIdentity(_ app: XCUIApplication) -> String? {
    let focused = app.descendants(matching: .any)
      .matching(NSPredicate(format: "hasFocus == true"))
    guard focused.count > 0 else { return nil }
    let el = focused.element(boundBy: 0)
    return "\(el.elementType.rawValue)|\(el.identifier)|\(el.label)|\(el.frame)"
  }

  /// Walks the focus engine and returns every element the remote can actually reach.
  ///
  /// Bounded by `maxSteps` rather than by "until nothing new appears": a focus trap is
  /// exactly the failure being hunted, and an unbounded walk would hang inside one instead
  /// of reporting it.
  private func reachableIdentities(
    _ app: XCUIApplication,
    directions: [XCUIRemote.Button] = [.down, .right, .up, .left],
    maxSteps: Int = 60
  ) -> Set<String> {
    var seen = Set<String>()
    if let start = focusedIdentity(app) { seen.insert(start) }

    var steps = 0
    for direction in directions {
      // Press each direction repeatedly until it stops yielding anything new — that is
      // how a rail or a column is traversed — then move to the next direction.
      var idle = 0
      while steps < maxSteps && idle < 3 {
        XCUIRemote.shared.press(direction)
        Thread.sleep(forTimeInterval: 0.6)
        steps += 1
        if let now = focusedIdentity(app) {
          idle = seen.insert(now).inserted ? 0 : idle + 1
        } else {
          idle += 1
        }
      }
    }
    return seen
  }

  /// Focus is never lost while navigating.
  ///
  /// On tvOS "nothing is focused" is an unusable screen: the remote has no pointer, so
  /// there is no way to recover except relaunching. This is the failure mode a focus trap
  /// or an unfocusable container actually produces for a user.
  func testFocusIsNeverLostWhileNavigating() {
    let app = launched()
    XCTAssertNotNil(focusedIdentity(app), "nothing had focus at launch")

    for (i, direction) in [XCUIRemote.Button.down, .right, .up, .left, .down, .right].enumerated() {
      XCUIRemote.shared.press(direction)
      Thread.sleep(forTimeInterval: 0.6)
      XCTAssertNotNil(
        focusedIdentity(app),
        "Focus was lost after press #\(i + 1) (\(direction)). The screen is now unusable — "
          + "the Siri Remote has no pointer, so there is no way back without relaunching."
      )
    }
  }

  /// The remote can reach more than one control.
  ///
  /// The weakest possible statement of the recurring bug, which is why it is worth pinning
  /// separately: a screen where exactly one thing is reachable is the shape every one of
  /// the five recurrences took at its worst.
  func testMoreThanOneControlIsReachable() {
    let app = launched()
    let reachable = reachableIdentities(app)
    XCTAssertGreaterThan(
      reachable.count, 1,
      "Only \(reachable.count) element(s) could be reached with the d-pad. Everything else "
        + "on screen renders and cannot be operated — the exact defect that has shipped "
        + "five times."
    )
  }

  /// No direction is a one-way door.
  ///
  /// Moving in a direction and then reversing must return focus to where it started. When
  /// it does not, a control has become unreachable in practice even though a static check
  /// of the focus enums passes — a user who moves past it can never get back.
  func testEveryDirectionIsReversible() {
    let app = launched()

    let pairs: [(XCUIRemote.Button, XCUIRemote.Button, String)] = [
      (.down, .up, "down then up"),
      (.right, .left, "right then left"),
    ]

    for (forward, back, name) in pairs {
      guard let start = focusedIdentity(app) else {
        XCTFail("nothing focused before testing \(name)")
        return
      }

      XCUIRemote.shared.press(forward)
      Thread.sleep(forTimeInterval: 0.6)
      guard let moved = focusedIdentity(app), moved != start else {
        // Nothing in that direction is legitimate — an edge. Not a failure.
        continue
      }

      XCUIRemote.shared.press(back)
      Thread.sleep(forTimeInterval: 0.6)
      let returned = focusedIdentity(app)

      XCTAssertEqual(
        returned, start,
        "\(name) did not return focus to where it started. Moving away from a control and "
          + "back must reach it again; when it does not, that control is unreachable in "
          + "practice for anyone who navigates past it."
      )
    }
  }
}
