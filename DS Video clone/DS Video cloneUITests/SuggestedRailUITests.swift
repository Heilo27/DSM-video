import XCTest

/// The Suggested rail must actually RENDER on Home, driven against the loopback `StubServer`
/// (TASK-969; it used to need a live NAS token in /tmp and XCTSkip without one, so it never ran).
///
/// WHY a UI test: the endpoint, the genre rule and the decode are unit-tested, but the first
/// version of this feature wired `loadSuggestedRail()` into one rail-assignment path out of four,
/// so on a cold start (the ordinary launch) the rail was correct and invisible.
@MainActor
final class SuggestedRailUITests: XCTestCase {

  private var server: StubServer!

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    server?.stop()
    server = nil
    try await super.tearDown()
  }

  private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  /// FRD-001 FR-145 (Suggested is decided by the server). Given a server whose /suggested answers genre "Drama" with one
  /// item ("Rail Pick"), when a signed-in cold launch settles on Home, then a rail titled
  /// "Suggested · Drama" is on screen and the server's pick is under it.
  /// Red if: the cold-start path stops calling loadSuggestedRail, or the title stops carrying the
  /// genre, or the rail renders its title with no items.
  func testSuggestedRailRendersWithItsGenreAndItems() throws {
    server = try StubServer.withProfiles([StubProfile(id: "p-only", name: "Dana", isOwner: true)])
    let pick = #"{"id":"s1","type":"movie","title":"Rail Pick","year":2019,"durationSeconds":6000,"#
      + #""addedAt":"2026-01-02T00:00:00Z","ageLevel":1,"libraryId":"lib1","changeSeq":2}"#
    server.setRoute("/api/v1/suggested", .init(#"{"genre":"Drama","items":[\#(pick)]}"#))
    let app = UITest.launchAgainst(server)

    requireExists(app.staticTexts["Suggested · Drama"], "the Suggested rail title with its genre",
                  timeout: UITest.launchTimeout)
    requireExists(element(app, containing: "Rail Pick"), "the server's suggested item under the rail")
    XCTAssertFalse(server.requests(path: "/api/v1/suggested").isEmpty,
                   "The rail never asked the server for suggestions.")
  }

  /// Negative: an empty answer (no progress yet, the ordinary first-run case) shows NO rail.
  /// Given /suggested answers no items, when Home settles, then no "Suggested" title exists, but
  /// the rest of Home did load (the library's own movie is on screen) so absence is not a blank page.
  /// Red if: an empty suggestion starts rendering a titled, empty rail.
  func testNoSuggestionsMeansNoSuggestedRail() throws {
    server = try StubServer.withProfiles([StubProfile(id: "p-only", name: "Dana", isOwner: true)])
    let app = UITest.launchAgainst(server)

    requireExists(element(app, containing: "Stub Movie"), "Home's own content (Stub Movie)",
                  timeout: UITest.launchTimeout)
    let deadline = Date().addingTimeInterval(3)
    while server.requests(path: "/api/v1/suggested").isEmpty, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    XCTAssertFalse(server.requests(path: "/api/v1/suggested").isEmpty,
                   "Precondition: the app should have asked /suggested (else absence proves nothing).")
    XCTAssertFalse(element(app, containing: "Suggested").exists,
                   "A Suggested rail is showing although the server suggested nothing.")
  }
}
