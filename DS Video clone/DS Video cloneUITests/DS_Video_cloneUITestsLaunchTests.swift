import XCTest

/// Per-configuration launch screenshots, for the visual review pass.
///
/// `runsForEachTargetApplicationUIConfiguration` makes XCUITest run this once per UI
/// configuration the destination offers, so one invocation yields the launch screen across them.
/// Those attachments are the raw material for judging colour, type and spacing — the things
/// automation cannot assert on but a person can compare against the previous run in seconds.
///
/// This replaces the generated template, which launched the app with no arguments — landing on
/// the setup screen and capturing the same empty form every time.
@MainActor
final class DSReelLaunchScreenshotTests: XCTestCase {

  override class var runsForEachTargetApplicationUIConfiguration: Bool {
    true
  }

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// Captures the first CONTENT screen, not the sign-in form.
  ///
  /// The template launched unconfigured, so every screenshot was of an empty address field —
  /// worthless for reviewing the app's actual design. Demo mode lands on populated rails.
  func testCaptureLaunchScreen() {
    let app = UITest.launchInDemoMode()

    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: UITest.launchTimeout),
      "The app never reached the foreground, so there is nothing to capture."
    )
    // Wait for real content. Capturing mid-launch yields a splash or a blank frame and makes
    // the visual diff useless.
    XCTAssertTrue(
      app.buttons.firstMatch.waitForExistence(timeout: UITest.launchTimeout),
      "No interactive content appeared — capturing now would record a dead screen."
    )

    capture(app, "00-launch-content")
  }
}
