import XCTest

/// Launch performance baseline.
///
/// This file used to hold Xcode's generated template: a `testExample` that launched the app and
/// then a comment where an assertion should have been, plus a launch-performance measurement.
/// It asserted nothing, and its presence made the project look tested — which is how two P0s
/// reached a pre-submission review (every download writing a 22-byte error body to disk, and a
/// player error screen with no way out).
///
/// The real behavioural coverage now lives in DSReelUITests and DSReelVisualTests. What stays
/// here is the one thing this file was legitimately doing: measuring cold launch.
@MainActor
final class DSReelLaunchTests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// Cold launch must reach a usable screen within a budget a user would tolerate.
  ///
  /// Unlike `measure`, this asserts. A performance metric with no threshold records a regression
  /// silently and still reports success; the app getting twice as slow to start should fail.
  func testColdLaunchReachesContentWithinBudget() {
    let started = Date()
    let app = UITest.launchInDemoMode()

    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: UITest.launchTimeout),
      "The app never reached the foreground."
    )
    XCTAssertTrue(
      app.buttons.firstMatch.waitForExistence(timeout: UITest.launchTimeout),
      "Launched, but no interactive content appeared — the user is looking at a dead screen."
    )

    let elapsed = Date().timeIntervalSince(started)
    // Deliberately loose: simulator timing varies with host load, and a tight threshold would
    // make this flaky, which gets suites disabled. This catches a serious regression, not drift.
    XCTAssertLessThan(
      elapsed, 25,
      "Cold launch to interactive content took \(String(format: "%.1f", elapsed))s. That is far "
        + "beyond the expected range — something in startup has regressed badly."
    )
  }

  /// Standard launch-performance metric, for trend tracking across runs.
  func testLaunchPerformanceMetric() {
    measure(metrics: [XCTApplicationLaunchMetric()]) {
      let app = XCUIApplication()
      app.launchArguments = ["-UITestDemoMode", "-UITestResetState"]
      app.launch()
      app.terminate()
    }
  }
}
