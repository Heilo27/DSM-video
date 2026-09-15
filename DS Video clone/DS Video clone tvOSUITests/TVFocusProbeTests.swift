import XCTest

/// Does XCUIRemote actually drive the tvOS focus engine on this host?
///
/// TASK-885 concluded that no focus navigation was possible here, and the evidence was
/// real — but it was evidence about the wrong mechanism. That investigation drove
/// `idb_companion`, a 2022 build whose `HIDButtonType` enumerates only APPLE_PAY, HOME,
/// LOCK, SIDE_BUTTON and SIRI. It predates Siri Remote support entirely, so its directional
/// events had nowhere to go: the companion accepted them, returned success, and nothing
/// moved. That is a dead end, and it is still a dead end.
///
/// XCUIRemote is a different thing. It is not external HID injection — the test bundle runs
/// INSIDE the simulator and talks to the focus engine directly, the same way the iOS UI
/// suite already drives taps on this machine. XCUIRemote.h ships in the AppleTVSimulator
/// SDK, so the capability was present the whole time; nobody had tried it.
///
/// This file exists to establish that as fact before any test depends on it. If these fail,
/// tvOS UI automation genuinely is unavailable here and TASK-885 stands as written.
final class TVFocusProbeTests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// The app launches and something holds focus.
  ///
  /// On tvOS, "nothing has focus" is not a cosmetic problem — the Siri Remote has no
  /// pointer, so an interface with no focused element cannot be operated at all.
  func testAppLaunchesAndSomethingHasFocus() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 60),
      "The tvOS app never reached the foreground."
    )

    // hasFocus is the real question; `exists` would pass on a screen nobody can use.
    let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
    XCTAssertGreaterThan(
      focused.count, 0,
      "No element has focus after launch. On tvOS that is an unusable screen — the remote "
        + "has no pointer, so focus is the only way in."
    )
  }

  /// A remote press MOVES focus — the claim TASK-885 says is impossible on this host.
  ///
  /// Asserts by IDENTITY, not by count: `press` returning without throwing proves nothing,
  /// which is precisely how the idb investigation was misled. The focused element must be a
  /// DIFFERENT element afterwards.
  func testRemotePressMovesFocusToADifferentElement() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "app did not launch")

    func focusedIdentity() -> String? {
      let focused = app.descendants(matching: .any)
        .matching(NSPredicate(format: "hasFocus == true"))
      guard focused.count > 0 else { return nil }
      let el = focused.element(boundBy: 0)
      // identifier alone is often empty; combine with label and frame so two genuinely
      // different controls cannot read as the same element.
      return "\(el.identifier)|\(el.label)|\(el.frame)"
    }

    let before = focusedIdentity()
    XCTAssertNotNil(before, "nothing was focused to move FROM")

    // Try each direction: the first screen's layout decides which one is meaningful, and
    // this probe must not encode an assumption about that layout.
    var moved = false
    for direction in [XCUIRemote.Button.down, .right, .up, .left] {
      XCUIRemote.shared.press(direction)
      // Focus changes are animated; give the engine a beat to settle.
      Thread.sleep(forTimeInterval: 1.0)
      if let now = focusedIdentity(), now != before {
        moved = true
        break
      }
    }

    XCTAssertTrue(
      moved,
      "Focus did not move after pressing down, right, up and left. Either every direction "
        + "is genuinely a dead end from the launch screen (a real defect), or XCUIRemote "
        + "cannot drive the focus engine on this host — in which case TASK-885 stands and "
        + "tvOS interaction coverage is unavailable here."
    )
  }
}
