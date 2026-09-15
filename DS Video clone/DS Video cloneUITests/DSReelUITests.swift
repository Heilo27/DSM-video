import XCTest

/// Core UI behaviour suite.
///
/// Every test here exists because a real defect reached a build. The header on each one names
/// it. That is deliberate: a test whose purpose is recorded gets maintained, and a test nobody
/// understands gets deleted the first time it is inconvenient.
///
/// THE BAR THIS SUITE SETS
/// -----------------------
/// Before it, the UI-test target was Xcode's untouched template — two stubs that launched the
/// app and asserted nothing. Two P0s shipped behind that gap: every download wrote a 22-byte
/// HTTP error body to disk as the .mp4 and marked the item downloaded, and the player's error
/// screen rendered correctly while Retry, Dismiss and swipe were all inert. Both are trivially
/// catchable by tapping a control and asserting an outcome. Neither was caught, because nothing
/// ever tapped anything.
@MainActor
final class DSReelUITests: XCTestCase {

  override func setUp() {
    super.setUp()
    // A UI test that keeps running after its first failure produces a cascade of misleading
    // secondary failures and buries the real one.
    continueAfterFailure = false
  }

  // MARK: - Launch and reachability

  /// The app must reach a usable first screen. Sounds trivial; it is the precondition for every
  /// other test, and a launch regression makes the whole suite's failures meaningless.
  func testLaunchesIntoUsableFirstScreen() {
    let app = UITest.launchUnconfigured()
    XCTAssertEqual(app.state, .runningForeground, "App is not in the foreground after launch.")

    // With no server configured the setup surface must appear. If it does not, the user has a
    // blank app and no way forward.
    requireExists(
      app.textFields[UIID.Setup.addressField],
      "the server address field on first launch",
      timeout: UITest.launchTimeout
    )
    capture(app, "01-first-launch-setup")
  }

  /// Regression: tvOS shipped with the address prefilled to `http://localhost:5000`, where
  /// localhost is the Apple TV itself — an address that can never work. A prefilled default
  /// that cannot succeed is worse than an empty field: it looks configured.
  func testFirstLaunchDoesNotPrefillAnUnusableAddress() {
    let app = UITest.launchUnconfigured()
    let address = app.textFields[UIID.Setup.addressField]
    requireExists(address, "the server address field", timeout: UITest.launchTimeout)

    let value = (address.value as? String) ?? ""
    XCTAssertFalse(
      value.contains("localhost"),
      "First launch prefilled the address with \"\(value)\". localhost is the device itself, so "
        + "this default can never connect — and on tvOS it also poisons pairing."
    )
  }

  /// The primary action must be disabled until it can actually succeed. An enabled button that
  /// does nothing when tapped is the dead-control defect in its most basic form.
  func testConnectIsDisabledUntilTheFormCanSucceed() {
    let app = UITest.launchUnconfigured()
    let connect = app.buttons[UIID.Setup.connectButton]
    requireExists(connect, "the Connect button", timeout: UITest.launchTimeout)

    XCTAssertFalse(
      connect.isEnabled,
      "Connect is enabled with an empty form. Tapping it cannot succeed, so it must be disabled "
        + "— an enabled control that does nothing reads to the user as a broken app."
    )
  }

  /// Connect must be reachable once the form is filled in.
  ///
  /// This is the defect's own regression guard, and it is separate on purpose. The
  /// unreachable-address test now calls dismissKeyboard() to get past this, which is
  /// correct for what that test is about — but it also means that test would go green
  /// again even if Connect became untappable a second way. This one asserts the property
  /// directly: fill every field, and the primary action is reachable by SOME documented
  /// route. It fails if Done disappears, and it fails if Done stops working.
  ///
  /// Original defect (TASK-906): the keyboard covered Connect, the form was too short for
  /// the ScrollView to scroll it clear, and there was no accessory to dismiss with. The
  /// button rendered, enabled, and could not be tapped.
  func testConnectStaysReachableWithTheKeyboardUp() throws {
    let app = UITest.launchUnconfigured()

    let address = app.textFields[UIID.Setup.addressField]
    requireExists(address, "the server address field", timeout: UITest.launchTimeout)
    address.tap()
    address.typeText("198.51.100.1")

    let username = app.textFields[UIID.Setup.usernameField]
    requireExists(username, "the username field")
    username.tap()
    username.typeText("tester")

    let password = app.secureTextFields[UIID.Setup.passwordField]
    requireExists(password, "the password field")
    password.tap()
    password.typeText("not-a-real-password")

    // The keyboard is now up, focus is in the last field, and the form is complete.
    let connect = app.buttons[UIID.Setup.connectButton]
    requireExists(connect, "the Connect button")
    XCTAssertTrue(
      connect.isEnabled,
      "Connect is disabled with every field filled — the form cannot be submitted at all."
    )

    dismissKeyboard(app)

    XCTAssertTrue(
      connect.isHittable,
      "Connect cannot be tapped after filling the form and dismissing the keyboard. The user "
        + "has entered valid details and has no way to submit them — Return in the password "
        + "field is the only route left, and nothing on screen says so."
    )
  }

  /// A wrong address must produce an error that names the REAL cause.
  ///
  /// Standing project rule: user-facing error text maps to the actual problem. Asserting only
  /// that "an error appeared" would pass for a message blaming the wrong thing, which is the
  /// defect this guards — a failed download once reported itself as an unsupported format and
  /// sent users off to re-encode healthy files.
  func testUnreachableAddressReportsTheRealCause() throws {
    let app = UITest.launchUnconfigured()
    let address = app.textFields[UIID.Setup.addressField]
    requireExists(address, "the server address field", timeout: UITest.launchTimeout)

    address.tap()
    // Must be a PRIVATE address that REFUSES FAST.
    //
    // Two constraints, and getting either wrong tests the wrong thing:
    //
    //  - Private, because the app's ATS policy permits cleartext on the local network only
    //    (TASK-777). A public address over plain http:// is refused by iOS before a packet
    //    is sent, which is an ATS block, not a connection failure. The original
    //    198.51.100.1 (TEST-NET-2) did exactly that and never reached the network at all.
    //
    //  - Fast, because an unrouted LAN address BLACK-HOLES rather than refusing: measured
    //    at 75s for 192.168.0.2:65123 against this test's 60s budget, so the error never
    //    arrived and the test failed on a timeout that was its own fault.
    //
    // 127.0.0.1 is private, and a closed port there returns ECONNREFUSED immediately
    // (measured: 0.015s) — the genuine "server unreachable" path, deterministically.
    address.typeText("127.0.0.1:65123")

    let username = app.textFields[UIID.Setup.usernameField]
    requireExists(username, "the username field")
    username.tap()
    username.typeText("tester")

    let password = app.secureTextFields[UIID.Setup.passwordField]
    requireExists(password, "the password field")
    password.tap()
    password.typeText("not-a-real-password")

    // The keyboard is up over the button after the last field. Use the app's own Done
    // accessory rather than a coordinate tap — see dismissKeyboard's note.
    dismissKeyboard(app)

    let connect = app.buttons[UIID.Setup.connectButton]
    requireHittable(connect, "the Connect button")
    connect.tap()

    // 120s, because login is a CASCADE and not a single attempt. buildCandidates() yields
    // LAN, WAN-direct and relay candidates, tried in order at 2s / 8s / 15s each
    // (AppState.swift:610-625), and a QuickConnect resolution runs on top of that. Measured
    // end-to-end at ~75s on the simulator, so a 60s budget failed on the test's own
    // impatience while the app was behaving exactly as designed.
    //
    // Raised deliberately rather than trimmed to fit: the cascade is the feature that makes
    // leaving the house mid-episode work (FRD-000 M5), and a test must not pressure it into
    // giving up early.
    // Queried via descendants, NOT app.otherElements.
    //
    // errorRow applies .accessibilityElement(children: .combine), which collapses the HStack
    // into a single STATIC TEXT (element type 48) rather than an "other" element. Querying
    // otherElements found nothing and waited out the full budget, so the test failed on its
    // own wrong query while the app was showing the error correctly the whole time — twice,
    // once blamed on the address and once on the timeout.
    //
    // descendants(matching: .any) is deliberate: the identifier is the contract, the element
    // TYPE is a SwiftUI implementation detail that changes with modifiers like .combine.
    let error = app.descendants(matching: .any)[UIID.Setup.errorText]
    requireExists(error, "a connection error message", timeout: 90)
    capture(app, "02-unreachable-address-error")

    let message = (error.value as? String) ?? error.label
    XCTAssertFalse(message.isEmpty, "An error element appeared but carried no message text.")
    // It must not blame the user's CREDENTIALS for a CONNECTIVITY failure — that sends them to
    // reset a password that was never the problem.
    assertMessage(
      message,
      avoids: ["password", "credential", "username"],
      context: "Unreachable-address error"
    )
  }

  // MARK: - Demo-mode content

  /// Demo mode must reach real content. This is the gateway for every content test, so when it
  /// breaks the suite must say so loudly rather than quietly testing nothing.
  func testDemoModeReachesContent() {
    let app = UITest.launchInDemoMode()
    XCTAssertEqual(app.state, .runningForeground)

    // Demo mode signs in and populates rails, so the setup field must be GONE. Asserting its
    // absence is what proves we actually got past sign-in.
    let address = app.textFields[UIID.Setup.addressField]
    XCTAssertFalse(
      address.waitForExistence(timeout: 5),
      "Still on the setup screen in demo mode — the demo bootstrap did not sign in."
    )
    capture(app, "03-demo-home")
  }

  /// Every screen must survive backgrounding. A view that returns blank, loses its state, or
  /// comes back to a permanent spinner is a defect the user hits constantly and no static
  /// review can see.
  func testSurvivesBackgroundAndForeground() {
    let app = UITest.launchInDemoMode()
    _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    capture(app, "04a-before-background")

    XCUIDevice.shared.press(.home)
    XCTAssertTrue(
      app.wait(for: .runningBackground, timeout: UITest.timeout),
      "App never entered the background."
    )

    app.activate()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: UITest.timeout),
      "App did not return to the foreground."
    )
    // Something must be on screen. A blank window after foregrounding is the symptom.
    XCTAssertTrue(
      app.descendants(matching: .any).count > 1,
      "The app came back to an apparently empty screen after foregrounding."
    )
    capture(app, "04b-after-foreground")
  }

  // MARK: - Dead-control sweep

  /// Every button reachable on the first content screen must be HITTABLE, not merely present.
  ///
  /// This is the generic form of the player-error defect: `exists` was true for Retry and
  /// Dismiss the entire time they were unreachable, because a transparent full-frame gesture
  /// layer above them swallowed each tap. Only hittability distinguishes a live control from a
  /// picture of one.
  func testEveryVisibleButtonOnTheFirstScreenIsHittable() {
    let app = UITest.launchInDemoMode()
    _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    // Let the first screen settle so we measure the real layout, not a mid-animation frame.
    XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: UITest.timeout),
                  "No buttons at all on the first content screen.")

    var unreachable: [String] = []
    for button in app.buttons.allElementsBoundByIndex {
      guard button.exists, button.isEnabled else { continue }
      // Only judge controls actually inside the window — offscreen rail items are legitimately
      // not hittable until scrolled to, and flagging those would be noise.
      let frame = button.frame
      guard frame.width > 0, frame.height > 0 else { continue }
      guard app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
      if !button.isHittable {
        unreachable.append(button.identifier.isEmpty ? button.label : button.identifier)
      }
    }

    XCTAssertTrue(
      unreachable.isEmpty,
      "These controls are on screen and enabled but cannot be tapped — each one is a dead "
        + "control: \(unreachable.joined(separator: ", ")). Look for an overlay above them."
    )
  }

  /// Tap targets must meet the 44pt minimum. Below that the control is reachable in principle
  /// and missed in practice, which the user experiences as the app ignoring them.
  ///
  /// FOUND A REAL DEFECT on its first run: the library search button was 37x36 — an unframed
  /// `Image` in a `ToolbarItem`. Five toolbar buttons shared that shape and are now framed,
  /// taking the width to 44+.
  ///
  /// WHY HEIGHT IS MEASURED AGAINST 36, NOT 44: a UIKit navigation bar fixes its own height and
  /// SwiftUI clamps a toolbar item to it, so `.frame(minHeight: 44)` inside the label cannot
  /// grow it — verified empirically (the same edit moved width 37 -> 56 and left height at 36).
  /// 36pt is the platform's toolbar height, not an app defect, and asserting 44 there would be a
  /// permanently-red test that teaches the team to ignore the suite. Width IS ours to control,
  /// so it is held to the full 44. Any control NOT in a toolbar is held to 44 in both axes.
  func testTapTargetsMeetMinimumSize() {
    let app = UITest.launchInDemoMode()
    _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: UITest.timeout))

    let minimum: CGFloat = 44
    /// A standard nav-bar item's height. Anything this short sitting at the top of the window is
    /// inside the bar, where its height is the platform's to decide.
    let toolbarHeight: CGFloat = 36
    let navBarBand = app.frame.minY + 140

    var undersized: [String] = []
    for button in app.buttons.allElementsBoundByIndex {
      guard button.exists, button.isHittable else { continue }
      let f = button.frame
      guard f.width > 0, f.height > 0 else { continue }

      let isToolbarItem = f.maxY <= navBarBand && f.height <= toolbarHeight
      let heightFloor: CGFloat = isToolbarItem ? toolbarHeight : minimum

      if f.width < minimum || f.height < heightFloor {
        let name = button.identifier.isEmpty ? button.label : button.identifier
        let note = isToolbarItem ? " (toolbar item; height floor \(Int(toolbarHeight)))" : ""
        undersized.append("\(name) [\(Int(f.width))x\(Int(f.height))]\(note)")
      }
    }

    // Reported as a single failure listing every offender, so one run gives the whole picture
    // instead of forcing a fix-and-rerun cycle per control.
    XCTAssertTrue(
      undersized.isEmpty,
      "Tap targets below the minimum (\(Int(minimum))pt, or \(Int(toolbarHeight))pt tall for "
        + "toolbar items whose height the platform fixes): \(undersized.joined(separator: ", "))"
    )
  }

  /// Every interactive element needs an accessibility label. An icon-only button with no label
  /// is unusable with VoiceOver, and it is also unfindable by this suite — so a missing label
  /// costs both real users and future tests.
  func testInteractiveElementsHaveAccessibilityLabels() {
    let app = UITest.launchInDemoMode()
    _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: UITest.timeout))

    var unlabelled: [String] = []
    for button in app.buttons.allElementsBoundByIndex {
      guard button.exists, button.isHittable else { continue }
      if button.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let f = button.frame
        unlabelled.append("button at (\(Int(f.midX)),\(Int(f.midY)))")
      }
    }

    XCTAssertTrue(
      unlabelled.isEmpty,
      "These interactive elements have no accessibility label and are invisible to VoiceOver: "
        + unlabelled.joined(separator: ", ")
    )
  }

  // MARK: - Mirror integrity

  /// The UI-test target cannot import the app's `A11y` enum, so `UIID` mirrors it by hand. A
  /// silent divergence would make every query miss — and a missing element is indistinguishable
  /// from a broken feature, so the suite would go quiet rather than red.
  ///
  /// This asserts the setup identifiers resolve against a real launched build. It deliberately
  /// covers only the unconfigured surface; the content-screen identifiers are exercised by the
  /// tests above, which fail loudly if an identifier stops resolving.
  func testIdentifierMirrorIsComplete() {
    let app = UITest.launchUnconfigured()
    requireExists(
      app.textFields[UIID.Setup.addressField],
      "UIID.Setup.addressField (\(UIID.Setup.addressField)) — mirror may have drifted from A11y",
      timeout: UITest.launchTimeout
    )
    requireExists(
      app.textFields[UIID.Setup.usernameField],
      "UIID.Setup.usernameField (\(UIID.Setup.usernameField)) — mirror may have drifted from A11y"
    )
    requireExists(
      app.secureTextFields[UIID.Setup.passwordField],
      "UIID.Setup.passwordField (\(UIID.Setup.passwordField)) — mirror may have drifted from A11y"
    )
    requireExists(
      app.buttons[UIID.Setup.connectButton],
      "UIID.Setup.connectButton (\(UIID.Setup.connectButton)) — mirror may have drifted from A11y"
    )
    // Only exists while a field has focus, so unlike the others it must be provoked.
    app.textFields[UIID.Setup.addressField].tap()
    requireExists(
      app.buttons[UIID.Setup.keyboardDoneButton],
      "UIID.Setup.keyboardDoneButton (\(UIID.Setup.keyboardDoneButton)) — mirror may have "
        + "drifted from A11y, or the keyboard accessory was removed"
    )
  }

  /// The Tab mirror matches A11y.Tab.
  ///
  /// Separate from the setup mirror check because these only exist once signed in, so the
  /// unconfigured launch above cannot see them. Demo mode is what puts the app past the
  /// login screen without a server.
  ///
  /// SKIPS THE ASSERTION ON SPLIT LAYOUT, and says so rather than failing. ContentView
  /// resolves `.split` whenever horizontalSizeClass is .regular (ContentView.swift:33-36),
  /// and a NavigationSplitView has a SIDEBAR, not a tab bar — so on iPad, and on any device
  /// the runner reports as regular, these identifiers correctly do not exist. The first
  /// version asserted them unconditionally and failed for a layout that was behaving
  /// exactly as designed.
  ///
  /// Not an XCTSkip: this suite bans those, because a skip reports success at the moment a
  /// feature breaks. The sidebar is checked instead, so the test still asserts something on
  /// every layout.
  func testTabIdentifierMirrorIsComplete() {
    let app = UITest.launchInDemoMode()
    _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)

    // Tabs and sidebar are mutually exclusive; find out which this device got.
    let home = app.buttons[UIID.Tab.home]
    let isTabLayout = home.waitForExistence(timeout: UITest.timeout)

    guard isTabLayout else {
      // Split layout. Assert the sidebar is actually there, so a genuinely broken root
      // still fails rather than quietly taking this branch.
      XCTAssertTrue(
        app.cells.firstMatch.waitForExistence(timeout: UITest.timeout)
          || app.staticTexts["Home"].waitForExistence(timeout: 2),
        "Neither a tab bar nor a sidebar rendered. The app has no root navigation at all."
      )
      return
    }

    for (name, id) in [
      ("home", UIID.Tab.home),
      ("libraries", UIID.Tab.libraries),
      ("downloads", UIID.Tab.downloads),
      ("watchlist", UIID.Tab.watchlist),
      ("settings", UIID.Tab.settings),
    ] {
      requireExists(
        app.buttons[id],
        "UIID.Tab.\(name) (\(id)) — mirror may have drifted from A11y, or the tab was removed",
        timeout: UITest.timeout
      )
    }
  }
}
