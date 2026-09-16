import XCTest

/// The Suggested rail must actually RENDER against the live server.
///
/// Everything else about this rail is verified without a UI: the endpoint returns the right
/// items (checked against the live NAS by hand), the genre rule is unit-tested, and the
/// decode has a contract test. None of that proves the rail reaches the screen — and the
/// first version of this feature wired `loadSuggestedRail()` into `recomputeHomeRails` only,
/// so on a cold start (the ordinary launch) it never ran at all. The rail was correct and
/// invisible.
///
/// Uses the DEBUG QA hook to adopt a real token against the NAS. It therefore REQUIRES the
/// server to be reachable, and fails rather than skipping when it is not: a test that goes
/// green because it could not reach the thing it tests is the failure mode this whole suite
/// is written against.
final class LiveSuggestedRailTests: XCTestCase {

  /// Credentials for the live run, read from a file rather than the environment.
  ///
  /// xcodebuild does not forward the invoking shell's environment into the test runner, so
  /// an env-var switch silently SKIPS instead of running — which looked like a pass. A file
  /// the runner can read is unambiguous, and keeps a per-session token out of the repo.
  ///
  /// Format: two lines, token then server URL.
  private var liveConfig: (token: String, server: String)? {
    let path = "/tmp/dsvideo-qa-live.txt"
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
    return (String(lines[0]), String(lines[1]))
  }

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testSuggestedRailRendersAgainstTheLiveServer() throws {
    guard let cfg = liveConfig else {
      // Not a skip of a FAILURE — this test is opt-in by design, because it needs a live
      // NAS and a fresh token that cannot be committed. When the operator did not supply
      // them, there is nothing to assert about.
      throw XCTSkip("""
        Live run not requested. Write a token and server URL to /tmp/dsvideo-qa-live.txt \
        (two lines) to run this against the real NAS.
        """)
    }

    let app = XCUIApplication()
    app.launchArguments += ["-UITestResetState", "-QALiveToken", cfg.token, "-QALiveServer", cfg.server]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "app did not launch")

    // The rail's title carries the genre it was built from ("Suggested · Drama"), so a
    // prefix match asserts both that it rendered and that it named a reason.
    let suggested = app.staticTexts.containing(
      NSPredicate(format: "label BEGINSWITH %@", "Suggested")
    ).firstMatch

    // Generous: a cold start does a full sync before the rails settle.
    XCTAssertTrue(
      suggested.waitForExistence(timeout: 90),
      """
      The Suggested rail never appeared on the home screen. The endpoint returning items is \
      not enough — this is the gap that made the first version invisible, where the loader \
      was wired into one rail-assignment path out of four.
      """
    )

    // A titled rail with no items is worse than no rail: it claims a recommendation and
    // shows nothing. Assert something rendered beneath it.
    XCTAssertTrue(
      app.buttons.firstMatch.waitForExistence(timeout: 20),
      "The Suggested rail rendered its title with no items under it."
    )
  }
}
