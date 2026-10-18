import XCTest

/// FRD-002 profile oracle rows that only a running UI can answer (TASK-969), driven against the
/// loopback `StubServer` so the SERVER's answer is deterministic and what the app SENT is
/// readable back.
@MainActor
final class ProfileOracleUITests: XCTestCase {

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

  /// Polls the stub's request log for a request on a library-data route that carries the
  /// `X-DSVideo-Profile` header; returns its value (nil on timeout).
  private func profileHeaderOnLibraryRequest(timeout: TimeInterval = UITest.timeout) -> String? {
    let dataRoutes: Set<String> = ["/api/v1/libraries", "/api/v1/items", "/api/v1/just-added",
                                   "/api/v1/sync/items", "/api/v1/suggested"]
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let hit = server.requests.first(where: {
        dataRoutes.contains($0.path) && $0.header("X-DSVideo-Profile") != nil
      }) { return hit.header("X-DSVideo-Profile") }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return nil
  }

  /// OC-2165 / FR-260 / AC-002-40. Given an account with two profiles and no active profile id,
  /// when the app cold-launches signed in, then the picker lists BOTH profiles by identity and the
  /// app has not silently picked one (no library request carries a profile header).
  /// Red if: the cold-launch trigger stops showing the picker (ProfileGate.shouldShowPicker).
  func testMultiProfileAccountWithNoActiveProfileShowsThePicker() throws {
    server = try StubServer.withProfiles([
      StubProfile(id: "p-owner", name: "Dana", isOwner: true),
      StubProfile(id: "p-kid", name: "Robin", maxAgeLevel: 1, kids: true),
    ])
    let app = UITest.launchAgainst(server)

    requireExists(app.buttons[UIID.Profile.Picker.profileTile(named: "Dana")],
                  "Dana's tile on the profile picker", timeout: UITest.launchTimeout)
    requireExists(app.buttons[UIID.Profile.Picker.profileTile(named: "Robin")],
                  "Robin's tile on the profile picker")
    XCTAssertNil(
      server.requests.first(where: {
        $0.path == "/api/v1/items" && $0.header("X-DSVideo-Profile") != nil
      }),
      "A library request carried a profile header while no profile had been chosen."
    )
    XCTAssertFalse(app.buttons[UIID.Profile.activeProfileChip].exists,
                   "The home screen's active-profile chip is showing although no profile was chosen.")
  }

  /// OC-2032 / FR-260. Given an account with exactly one profile, when the app launches signed in,
  /// then it enters that profile without a picker, and library requests carry that profile's id.
  /// Red if: the single-profile auto-enter in refreshProfiles stops setting the active profile.
  func testSingleProfileAccountAutoEntersAndSendsItsProfileHeader() throws {
    server = try StubServer.withProfiles([
      StubProfile(id: "p-only", name: "Dana", isOwner: true),
    ])
    let app = UITest.launchAgainst(server)

    let header = profileHeaderOnLibraryRequest(timeout: UITest.launchTimeout)
    XCTAssertEqual(header, "p-only",
                   "No library request carried X-DSVideo-Profile: p-only; the app did not enter the only profile.")
    XCTAssertFalse(app.buttons[UIID.Profile.Picker.profileTile(named: "Dana")].exists,
                   "The picker is showing for a single-profile account.")
    XCTAssertFalse(app.buttons[UIID.Profile.Picker.manageButton].exists,
                   "The picker's Manage button is showing for a single-profile account.")
  }
}
