import XCTest

/// The Siri intents route through AppState's pending properties, which are the SAME
/// mechanism the Top Shelf deep link uses. This drives the SEARCH half — the new path —
/// end to end: set a pending term the way FindItemIntent does, and assert the app opens
/// the search screen with that term already run.
///
/// Not a mock: the app is launched for real and the term is injected by the launch
/// argument the app reads in demo mode, so this exercises the actual view wiring
/// (.onChange + .task + TVSearchView.initialTerm), which is where the cold-launch race
/// that broke the Top Shelf deep link lived.
final class SiriIntentTests: XCTestCase {
  @MainActor
  func testSiriSearchTermOpensSearchWithResults() {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestDemoMode", "-UITestResetState", "-UITestSiriSearch", "Starfall"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "app did not launch")

    // The search screen must come up on its own — nobody pressed anything.
    let field = app.textFields.firstMatch
    XCTAssertTrue(
      field.waitForExistence(timeout: 20),
      "Siri set a pending search term but the search screen never opened. The "
        + "pendingSearchTerm wiring (.onChange/.task in TVMainView) is not firing."
    )

    // And it must have run the search, not just opened an empty box.
    let result = app.staticTexts["Starfall"]
    XCTAssertTrue(
      result.waitForExistence(timeout: 20),
      "Search opened but did not run the spoken term — results for \"Starfall\" never appeared."
    )
  }
}
