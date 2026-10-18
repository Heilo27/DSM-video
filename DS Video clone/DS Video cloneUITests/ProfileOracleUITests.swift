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

  /// Finds an element by identifier whatever its accessibility type, so a row does not depend on
  /// how SwiftUI happened to surface it.
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// OC-2168 / FR-260. Given the app remembers an active profile (Dana) that the server later
  /// stops listing, when it cold-launches, then the picker returns offering exactly the profiles
  /// that still exist, and Dana is not offered or entered.
  /// Red if: ProfileGate.shouldShowPicker stops checking the remembered id against the list.
  func testRememberedProfileMissingFromServerListBringsBackThePicker() throws {
    server = try StubServer.withProfiles([
      StubProfile(id: "p-owner", name: "Dana", isOwner: true),
      StubProfile(id: "p-kid", name: "Robin", maxAgeLevel: 1, kids: true),
    ])
    let first = UITest.launchAgainst(server)
    requireExists(first.buttons[UIID.Profile.Picker.profileTile(named: "Dana")],
                  "Dana's tile on the first-launch picker", timeout: UITest.launchTimeout)
    first.buttons[UIID.Profile.Picker.profileTile(named: "Dana")].tap()
    requireExists(element(first, UIID.Profile.activeProfileChip),
                  "the active-profile chip after choosing Dana (Dana is now remembered)",
                  timeout: UITest.launchTimeout)
    first.terminate()

    server.setProfiles([
      StubProfile(id: "p-robin", name: "Robin2", maxAgeLevel: 1, kids: true),
      StubProfile(id: "p-casey", name: "Casey"),
    ])
    let second = UITest.launchAgainst(server, resetState: false)

    requireExists(second.buttons[UIID.Profile.Picker.profileTile(named: "Robin2")],
                  "Robin2's tile on the picker after Dana vanished", timeout: UITest.launchTimeout)
    requireExists(second.buttons[UIID.Profile.Picker.profileTile(named: "Casey")],
                  "Casey's tile on the picker after Dana vanished")
    XCTAssertFalse(second.buttons[UIID.Profile.Picker.profileTile(named: "Dana")].exists,
                   "The picker still offers Dana although the server no longer lists her.")
    XCTAssertFalse(element(second, UIID.Profile.activeProfileChip).exists,
                   "The app entered a profile (chip showing) instead of showing the picker.")
  }

  /// OC-2134 / OC-2186 / FR-265. Given a Little Kids profile and a library with nothing the
  /// profile may see, when Home loads, then it says "No Little Kids titles in your library yet."
  /// under the restricted empty state (not the NAS-is-empty copy).
  /// Red if: Home's empty branch stops routing a restricted profile to RestrictedEmptyState, or
  /// ProfileText.restrictedEmpty changes its wording.
  func testRestrictedProfileWithNothingVisibleSaysSoInItsLevelsWords() throws {
    server = try StubServer.withProfiles([
      StubProfile(id: "p-kid", name: "Robin", maxAgeLevel: 1, kids: true),
    ])
    server.emptyLibrary()
    let app = UITest.launchAgainst(server)

    requireExists(element(app, UIID.Profile.restrictedEmptyState),
                  "the restricted empty state on Home", timeout: UITest.launchTimeout)
    requireExists(app.staticTexts["No Little Kids titles in your library yet."],
                  "the level-and-place sentence")
    XCTAssertFalse(app.staticTexts["Add videos to your NAS to get started."].exists,
                   "The NAS-is-empty copy is showing for an age-limited profile.")
  }

  /// OC-2134 negative. Given an Adult (unrestricted) profile and the same empty library, when Home
  /// loads, then the generic empty state shows and the restricted one does not.
  /// Red if: the restricted empty state starts showing for unrestricted profiles.
  func testUnrestrictedProfileWithEmptyLibraryGetsTheGenericEmptyState() throws {
    server = try StubServer.withProfiles([
      StubProfile(id: "p-owner", name: "Dana", isOwner: true),
    ])
    server.emptyLibrary()
    let app = UITest.launchAgainst(server)

    requireExists(app.staticTexts["Add videos to your NAS to get started."],
                  "the generic empty-library copy", timeout: UITest.launchTimeout)
    XCTAssertFalse(element(app, UIID.Profile.restrictedEmptyState).exists,
                   "The restricted empty state is showing for an unrestricted profile.")
  }

  // MARK: - PIN copy when the NAS cannot answer (FR-263 / FR-266)

  private func tapPin(_ app: XCUIApplication, _ digits: String) {
    for d in digits {
      requireExists(app.buttons[UIID.Profile.PinPad.key(String(d))], "PIN pad key \(d)")
      app.buttons[UIID.Profile.PinPad.key(String(d))].tap()
    }
  }

  /// Polls the PIN pad's message line until it reads exactly `expected` (nil on timeout: returns
  /// the last text seen so the failure names it).
  private func pinMessage(_ app: XCUIApplication, becomes expected: String,
                          timeout: TimeInterval = UITest.timeout) -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var last = element(app, UIID.Profile.PinPad.message).label
    while Date() < deadline, last != expected {
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
      last = element(app, UIID.Profile.PinPad.message).label
    }
    return last
  }

  /// OC-2114 / FR-263 / FR-266. Given a PIN-protected profile and a NAS that stops answering,
  /// when the user enters a PIN, then the pad says the NAS must be reachable, and it does NOT
  /// call the PIN wrong.
  /// Red if: ProfileText.pinFailure maps an unreachable server to anything but pinNeedsNAS.
  func testPinCheckWithTheNASUnreachableNamesTheNASNotTheCode() throws {
    server = try StubServer.withProfiles([
      StubProfile(id: "p-owner", name: "Dana", isOwner: true),
      StubProfile(id: "p-casey", name: "Casey", hasPin: true),
    ])
    let app = UITest.launchAgainst(server)
    requireExists(app.buttons[UIID.Profile.Picker.profileTile(named: "Casey")],
                  "Casey's tile on the picker", timeout: UITest.launchTimeout)
    server.stop()

    app.buttons[UIID.Profile.Picker.profileTile(named: "Casey")].tap()
    tapPin(app, "1234")

    let shown = pinMessage(app, becomes: "Your NAS needs to be reachable to check this PIN.")
    XCTAssertEqual(shown, "Your NAS needs to be reachable to check this PIN.",
                   "The PIN pad did not name the unreachable NAS.")
    assertMessage(shown, avoids: ["Incorrect"], context: "unreachable-NAS PIN message")
  }

  /// OC-2114 negative control. Given the same profile and a NAS that ANSWERS "wrong PIN with 2
  /// tries left", when the user enters a PIN, then the pad shows the server's reason, not the
  /// unreachable-NAS line (the two causes must stay distinct).
  /// Red if: pinFailure reports every failure as unreachable, or drops the server's reason.
  func testPinCheckWithTheNASAnsweringWrongPinShowsTheTriesLeft() throws {
    server = try StubServer.withProfiles([
      StubProfile(id: "p-owner", name: "Dana", isOwner: true),
      StubProfile(id: "p-casey", name: "Casey", hasPin: true),
    ])
    server.setRoute("/api/v1/profiles/p-casey/pin/verify",
                    .init(#"{"error":"pin_incorrect","attemptsRemaining":2}"#, status: 403))
    let app = UITest.launchAgainst(server)
    requireExists(app.buttons[UIID.Profile.Picker.profileTile(named: "Casey")],
                  "Casey's tile on the picker", timeout: UITest.launchTimeout)

    app.buttons[UIID.Profile.Picker.profileTile(named: "Casey")].tap()
    tapPin(app, "1234")

    let shown = pinMessage(app, becomes: "Incorrect PIN. 2 tries left before this profile locks.")
    XCTAssertEqual(shown, "Incorrect PIN. 2 tries left before this profile locks.")
    XCTAssertEqual(server.requests(path: "/api/v1/profiles/p-casey/pin/verify").count, 1,
                   "Exactly one verify call should have reached the NAS.")
  }

  // NOT AUTOMATED: ProfileText.saveNeedsNAS via the owner's first-PIN pad (OC-2111).
  // NewPinView sets `first = nil` inside its submit closure before returning `.reject`, which
  // flips `.id(first == nil ? "first" : "confirm")` and rebuilds PinPadView, discarding the
  // `error` @State the reject was about to set. The pad ends on "Choose 4 digits." and neither
  // the save-failure copy nor "Those PINs didn't match" is ever visible. App bug, reported on
  // TASK-969; a test for it would fail until the app is fixed.
}
