import XCTest

// MARK: - Launch harness

/// Shared launch + query helpers for the UI suite.
///
/// DESIGN RULES FOR THIS SUITE (read before adding a test)
/// ------------------------------------------------------
/// 1. **Never skip.** `XCTSkip` is banned here. A test that skips when its element is missing
///    reports success at exactly the moment the feature broke — the failure mode that let two
///    P0s ship in the 1.3.6 cycle. If a precondition is missing, FAIL and say what was missing.
/// 2. **Query by identifier, never by visible copy.** Identifiers live in `A11y` in the app
///    target and are API. A test keyed to a label silently stops testing when copy changes.
/// 3. **Assert on identity and count, never on position.** `cells.firstMatch` after a deletion
///    re-resolves to the NEXT row, which still exists — an assertion that cannot fail.
/// 4. **Assert the text, not just the presence.** "An error appeared" passes for a WRONG error.
///    The project rule is that user-facing error text names the real cause, so tests check it.
/// 5. **Deterministic data only.** Use `-UITestDemoMode`; never depend on the live NAS, whose
///    reachability would make the suite flaky and its failures meaningless.
enum UITest {

  /// Default timeout for an element that should appear after a user action.
  static let timeout: TimeInterval = 10
  /// Longer budget for first launch, which includes app start plus demo bootstrap.
  static let launchTimeout: TimeInterval = 30

  /// Launch into demo mode: signed in, deterministic library, no network.
  @MainActor
  static func launchInDemoMode(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestDemoMode"]
    app.launchArguments += extraArguments
    // Make every run start from the same place. Without this, a previously-saved address or
    // a stale theme leaks between tests and a failure becomes unreproducible.
    app.launchArguments += ["-UITestResetState"]
    app.launch()
    return app
  }

  /// Launch with NO session, to exercise the setup/sign-in surface.
  @MainActor
  static func launchUnconfigured(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestResetState"]
    app.launchArguments += extraArguments
    app.launch()
    return app
  }
}

// MARK: - Assertions that cannot silently pass

extension XCTestCase {

  /// Waits for an element and FAILS with a useful message if it never appears.
  ///
  /// Use this instead of a bare `waitForExistence` whose Bool is discarded — a discarded
  /// result is a test that proves nothing.
  @discardableResult
  func requireExists(
    _ element: XCUIElement,
    _ what: String,
    timeout: TimeInterval = UITest.timeout,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    let appeared = element.waitForExistence(timeout: timeout)
    XCTAssertTrue(
      appeared,
      "Expected \(what) to exist but it never appeared within \(Int(timeout))s. "
        + "If this element was renamed, update A11y — do not delete the assertion.",
      file: file, line: line
    )
    return appeared
  }

  /// Requires an element to be present AND actually hittable.
  ///
  /// The distinction matters: the player's error overlay rendered perfectly while every button
  /// on it was unreachable because a transparent full-frame gesture layer above it swallowed
  /// each tap. `exists` was true the whole time. Only hittability catches that.
  func requireHittable(
    _ element: XCUIElement,
    _ what: String,
    timeout: TimeInterval = UITest.timeout,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    requireExists(element, what, timeout: timeout, file: file, line: line)
    XCTAssertTrue(
      element.isHittable,
      "\(what) exists but is NOT hittable — it renders and cannot be tapped. "
        + "That is a dead control: check for an overlay above it swallowing touches.",
      file: file, line: line
    )
  }

  /// Taps a text field, waits until it actually holds keyboard focus, then types.
  ///
  /// A bare `tap(); typeText()` races the form: when the keyboard rises after the previous
  /// field the form scrolls, a tap on the stale position lands on nothing, and `typeText`
  /// dies with "Neither element nor any descendant has keyboard focus" (measured: a 1-in-3
  /// flake on the password field). The wait is on the real condition, focus, and re-taps
  /// once; it never relaxes what the caller asserts afterwards.
  func focusAndType(
    _ field: XCUIElement,
    _ text: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    func hasFocus() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
    for _ in 0..<3 {
      field.tap()
      let deadline = Date().addingTimeInterval(2)
      while !hasFocus() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
      if hasFocus() { break }
    }
    XCTAssertTrue(hasFocus(), "Tapping \(field) never gave it keyboard focus.", file: file, line: line)
    field.typeText(text)
  }

  /// Dismisses the keyboard via the setup screen's Done accessory, if it is up.
  ///
  /// Deliberately NOT a tap on empty space: that is a coordinate guess which passes by
  /// accident when it lands on nothing and fails confusingly when it lands on a control.
  /// Tapping the app's own documented dismissal affordance also means this helper keeps
  /// exercising the real escape route a user has (TASK-906) — if Done regresses, the
  /// tests that rely on it fail, which is the point.
  ///
  /// A no-op when the keyboard is already down, so it is safe to call unconditionally.
  func dismissKeyboard(_ app: XCUIApplication) {
    let done = app.buttons[UIID.Setup.keyboardDoneButton]
    guard done.waitForExistence(timeout: 2), done.isHittable else { return }
    done.tap()
  }

  /// Asserts an element disappears, by identity — never by position.
  func requireDisappears(
    _ element: XCUIElement,
    _ what: String,
    timeout: TimeInterval = UITest.timeout,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let gone = element.waitForNonExistence(timeout: timeout)
    XCTAssertTrue(
      gone,
      "Expected \(what) to disappear within \(Int(timeout))s but it is still present.",
      file: file, line: line
    )
  }

  /// Asserts user-facing text does NOT blame the wrong cause.
  ///
  /// The standing project rule: an error message must name the real cause. A download that
  /// failed to fetch reported itself as an unsupported format, which sent users off to
  /// re-encode perfectly good files. Presence alone would have passed that.
  func assertMessage(
    _ actual: String,
    mentions expected: [String] = [],
    avoids forbidden: [String] = [],
    context: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for term in expected {
      XCTAssertTrue(
        actual.localizedCaseInsensitiveContains(term),
        "\(context): expected the message to mention \"\(term)\" but got: \"\(actual)\"",
        file: file, line: line
      )
    }
    for term in forbidden {
      XCTAssertFalse(
        actual.localizedCaseInsensitiveContains(term),
        "\(context): message must NOT mention \"\(term)\" — it misstates the cause. Got: \"\(actual)\"",
        file: file, line: line
      )
    }
  }
}

// MARK: - Screenshot capture for the visual pass

extension XCTestCase {

  /// Attaches a named, always-kept screenshot.
  ///
  /// XCUITest can prove structure, reachability and state; it cannot judge whether a screen is
  /// beautiful. These attachments are the input to the visual review — colour, spacing,
  /// hierarchy and polish are assessed from them, by eye, against the captures from the
  /// previous run.
  @MainActor
  func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}

// MARK: - Accessibility identifiers (mirrors the app target's A11y enum)

/// The app target's `A11y` enum is not visible to the UI-test target (UI tests drive the app as
/// a black box and link nothing from it), so the identifiers are mirrored here.
///
/// These two lists MUST agree. `testIdentifierMirrorIsComplete` in DSReelUITests asserts that
/// every identifier used by a test is actually present in a launched build, which is what
/// catches drift — a mirror that silently diverges would make every query miss and, without
/// rule 1 above, would read as a pass.
enum UIID {
  enum Setup {
    static let addressField = "setup.address"
    static let usernameField = "setup.username"
    static let passwordField = "setup.password"
    static let connectButton = "setup.connect"
    static let errorText = "setup.error"
    static let keyboardDoneButton = "setup.keyboardDone"
  }

  enum Tab {
    static let home = "tab.home"
    static let libraries = "tab.libraries"
    static let downloads = "tab.downloads"
    static let watchlist = "tab.watchlist"
    static let settings = "tab.settings"
  }

  enum Detail {
    static let playButton = "detail.play"
    static let title = "detail.title"
    static let downloadButton = "detail.download"
    static let downloadError = "detail.downloadError"
    static let nextEpisodeButton = "detail.nextEpisode"
  }

  enum Player {
    static let errorOverlay = "player.errorOverlay"
    static let errorRetryButton = "player.error.retry"
    static let errorDismissButton = "player.error.dismiss"
  }

  enum Shared {
    static let emptyState = "shared.emptyState"
    static let errorState = "shared.errorState"
    static let offlineBanner = "shared.offlineBanner"
  }

  /// Mirror of A11y.Profile (App/AccessibilityIDs.swift); a drifted value makes the test queries miss.
  enum Profile {
    static let activeProfileChip = "home.activeProfile"
    static let manageProfilesRow = "settings.manageProfiles"
    static let restrictedEmptyState = "emptyState.restricted"

    enum Picker {
      static let manageButton = "profilePicker.manage"
      static let addButton = "profilePicker.add"
      static func profileTile(named name: String) -> String { "profilePicker.profile.\(name)" }
    }

    enum PinPad {
      static let message = "pinPad.message"
      static let forgotButton = "pinPad.forgot"
      static let cancelButton = "pinPad.cancel"
      static let deleteButton = "pinPad.delete"
      static func key(_ digit: String) -> String { "pinPad.key.\(digit)" }
    }

    enum Manage {
      static let addButton = "profileManage.add"
      static let doneButton = "profileManage.done"
      static func profileRow(named name: String) -> String { "profileManage.profile.\(name)" }
    }

    enum OwnerPinReset {
      static let passwordField = "ownerPinReset.password"
      static let codeField = "ownerPinReset.code"
      static let error = "ownerPinReset.error"
      static let resetButton = "ownerPinReset.reset"
      static let cancelButton = "ownerPinReset.cancel"
      static let choosePin = "ownerPinReset.choosePin"
    }

    enum Editor {
      static let nameField = "profileEditor.name"
      static let error = "profileEditor.error"
      static let saveButton = "profileEditor.save"
      static let cancelButton = "profileEditor.cancel"
      static let deleteButton = "profileEditor.delete"
      static let nameReason = "profileEditor.nameReason"
      static let nameCounter = "profileEditor.nameCounter"
      static let pinSet = "profileEditor.pinSet"
      static let pinRemove = "profileEditor.pinRemove"
      static func level(_ value: Int) -> String { "profileEditor.level.\(value)" }
    }
  }
}
