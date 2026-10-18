import Testing
import Foundation
@testable import DSM_Video

// TASK-1016 (FRD-002 FR-216): a forgotten owner PIN is reset with the account's DSM password,
// and its verification code on a two-factor account. The API call existed with no caller, so an
// owner who forgot the PIN could never manage profiles again. The owner pad now offers
// "Forgot PIN?", which sends the reset through OwnerPinReset and AppState.resetOwnerPin.
// Expected messages are literals from the FRD and ProfilesAPI.md, never recomputed.

@Suite("Owner PIN reset (TASK-1016)", .serialized)
@MainActor
struct OwnerPinResetTests {
  private static let reset = "POST /api/v1/profiles/owner/pin/reset"
  private static let list = "GET /api/v1/profiles"
  private static let ryan = #"{"id":"pf_ryan","name":"Ryan","avatar":"moon","maxAgeLevel":4,"hasPin":true,"isOwner":true}"#
  private static let maya = #"{"id":"pf_maya","name":"Maya","avatar":"cat","maxAgeLevel":2,"hasPin":false,"isOwner":false}"#
  private static let listReply = ProfileStubServer.Reply.json(
    200, #"{"maxProfiles":4,"activeProfileId":null,"profiles":[\#(ryan),\#(maya)]}"#)

  private func withAccount(_ routes: [String: ProfileStubServer.Reply],
                           _ body: (AppState) async -> Void) async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(routes)
      await withIsolatedAppState(stubHost: ProfileStubServer.host, body)
    }
  }

  private func filled(password: String = "correct horse", code: String = "",
                      newPin: String? = "0420") -> OwnerPinReset {
    var form = OwnerPinReset()
    form.password = password
    form.code = code
    form.newPin = newPin
    return form
  }

  /// OC: AC-1 · the password, the code and the new PIN reach the server, and on success the
  /// owner unlocks with the new PIN and the list is re-read.
  /// Red if: the reset is never sent, sends the wrong fields, trims the password, or skips the refresh.
  @Test func aResetSendsPasswordCodeAndNewPinThenRefreshes() async {
    await withAccount([Self.reset: .json(200, #"{"ok":true}"#), Self.list: Self.listReply]) { state in
      let outcome = await filled(password: " hunter 2 ", code: "123 456").perform(on: state)
      #expect(outcome == .reset("0420"))
      #expect(ProfileStubServer.count(Self.reset) == 1)
      let body = ProfileStubServer.requests.first { $0.method == "POST" }?.body ?? ""
      #expect(body.contains(#""password":" hunter 2 ""#), "password sent as typed: \(body)")
      #expect(body.contains(#""otp":"123456""#), "code sent without spaces: \(body)")
      #expect(body.contains(#""newPin":"0420""#), "new PIN sent: \(body)")
      #expect(ProfileStubServer.count(Self.list) == 1, "the list is re-read after the reset")
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_maya"])
    }
  }

  /// OC: AC-1 · an account without two-factor sign-in leaves the code blank; no code is sent.
  @Test func aBlankCodeSendsNoCode() async {
    await withAccount([Self.reset: .json(200, #"{"ok":true}"#), Self.list: Self.listReply]) { state in
      let outcome = await filled(code: "   ").perform(on: state)
      #expect(outcome == .reset("0420"))
      let body = ProfileStubServer.requests.first { $0.method == "POST" }?.body ?? ""
      #expect(!body.contains("otp"), "no code field for a blank code: \(body)")
    }
  }

  /// OC: AC-1 · nothing is sent until there is a password and a chosen PIN.
  @Test func anIncompleteFormSendsNothing() async {
    await withAccount([Self.reset: .json(200, #"{"ok":true}"#)]) { state in
      #expect(await filled(password: "").perform(on: state) == .incomplete)
      #expect(await filled(newPin: nil).perform(on: state) == .incomplete)
      #expect(!filled(password: "").canSubmit)
      #expect(!filled(newPin: nil).canSubmit)
      #expect(filled().canSubmit)
      #expect(ProfileStubServer.requests.isEmpty)
    }
  }

  /// OC: AC-2 · each refusal is named for its real cause, changes nothing, and never ends the
  /// session (a wrong DSM password is a 403, not a 401: FR-217).
  /// Red if: a refusal reads as success, shows a raw code or the wrong cause, refreshes the
  /// list, or signs the owner out.
  @Test(arguments: [
    (ProfileStubServer.Reply.json(403, #"{"error":"password_incorrect"}"#),
     "Incorrect DSM password or verification code."),
    (.json(403, #"{"error":"otp_required"}"#),
     "This DSM account uses two-factor sign-in. Enter your DSM verification code along with your password."),
    (.json(503, #"{"error":"dsm_unavailable"}"#),
     "Couldn't reach DSM on your NAS to check your password. Nothing was changed. Try again in a moment."),
    (.json(403, #"{"error":"permission_denied"}"#),
     "Your account isn't allowed to use this app. Ask the server owner to grant you access in DSM → Control Panel → Application Privileges."),
    (.unreachable,
     "Couldn't reach your NAS, so nothing was changed. Check your connection and try again."),
    (.offline,
     "Couldn't reach your NAS, so nothing was changed. Check your connection and try again."),
  ])
  func aRefusalIsNamedAndChangesNothing(_ reply: ProfileStubServer.Reply, _ expected: String) async {
    await withAccount([Self.reset: reply, Self.list: Self.listReply]) { state in
      let outcome = await filled().perform(on: state)
      #expect(outcome == .refused(expected))
      #expect(ProfileStubServer.count(Self.list) == 0, "no refresh after a refusal")
      #expect(state.sessionToken == "stub-token", "a refused reset never ends the session")
    }
  }

  /// OC: AC-2 · a locked owner pad names the wait; "Forgot PIN?" is the way past it.
  @Test func aLockedOwnerPadNamesTheWait() async {
    await withAccount([
      "POST /api/v1/profiles/pf_ryan/pin/verify": .json(429, #"{"error":"pin_locked","retryAfterSeconds":300}"#)
    ]) { state in
      let owner = Profile(id: "pf_ryan", name: "Ryan", avatar: "moon", maxAgeLevel: 4, hasPin: true, isOwner: true)
      guard case .failure(let error) = await state.verifyProfilePin(owner, pin: "1111") else {
        Issue.record("a locked pad reported success"); return
      }
      #expect(ProfileText.pinFailure(error) == "Too many incorrect PINs. Try again in 5 minutes.")
    }
  }

  /// OC: AC-1 · the screen says what it needs and names the owner.
  @Test func theIntroAsksForThePasswordAndTheCode() {
    #expect(ProfileText.ownerPinResetIntro(name: "Ryan")
      == "Enter this account's DSM password to choose a new PIN for Ryan. "
       + "If the account uses two-factor sign-in, also enter its DSM verification code.")
  }
}
