import Testing
import Foundation
@testable import DSM_Video

// TASK-1014 (FRD-002 FR-216): an owner PIN reset the server refuses because DSM cannot be
// reached comes back as 503 `dsm_unavailable`. The app had no copy for the code, so it fell to
// the readable-identifier default and the owner read "Dsm unavailable." The FRD's point is that
// an unreachable DSM is not a wrong password; the message must say so in words.

@Suite("DSM unavailable message (TASK-1014)", .serialized)
@MainActor
struct DsmUnavailableMessageTests {
  private static let reset = "POST /api/v1/profiles/owner/pin/reset"
  private static let wrongPassword = "Incorrect DSM password or verification code."

  /// OC: AC-1 · the server's 503 dsm_unavailable for an owner PIN reset, through the real
  /// APIClient, reads as DSM being unreachable: never a wrong password, never a session problem.
  /// Red if: the code has no copy of its own (the default gives "Dsm unavailable."), or its copy
  /// blames the password or asks the user to sign in.
  @Test func anUnreachableDsmIsNamedNotBlamedOnThePassword() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset([Self.reset: .json(503, #"{"error":"dsm_unavailable"}"#)])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        var thrown: Error?
        do { try await state.api.resetOwnerPin(password: "pw", otp: nil, newPin: "1234") }
        catch { thrown = error }
        #expect(ProfileStubServer.count(Self.reset) == 1, "the reset reached the stub")
        guard let api = thrown as? APIError else {
          Issue.record("expected an APIError, got \(String(describing: thrown))")
          return
        }
        let message = api.userMessage
        #expect(message != "Dsm unavailable.", "the code has copy of its own")
        #expect(message.contains("DSM"), "names DSM: \(message)")
        #expect(message.localizedCaseInsensitiveContains("reach"), "says it couldn't be reached: \(message)")
        #expect(message != Self.wrongPassword)
        #expect(!message.localizedCaseInsensitiveContains("incorrect"), "not a wrong password: \(message)")
        #expect(!message.localizedCaseInsensitiveContains("sign in"), "not a session problem: \(message)")
        #expect(!message.localizedCaseInsensitiveContains("session"), "not a session problem: \(message)")
        #expect(!api.isAuthFailure, "a 503 never ends the session")
        // The screens read profile errors through ProfileText, which forwards a reached
        // server's answer: the same words, from the one home.
        #expect(ProfileText.pinFailure(api) == message)
        #expect(ProfileText.saveFailure(api) == message)
      }
    }
  }
}
