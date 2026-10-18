import Foundation
import Testing
@testable import DSM_Video

// MARK: - A revoked session is a session problem, not an offline one (TASK-967 · OC-1123 · FR-121)
//
// The server revokes the token (401 token_revoked). The user must be told it is a session problem
// with a way back in (the sign-in screen with the expired-session sentence), must NOT be shown the
// offline / server-unreachable banners, and a refresh that works must keep them signed in without
// any interruption. Every request goes through the real APIClient to ProfileStubServer; expected
// values are literals only.

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<300 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@Suite("OC-1123 · revoked session", .serialized)
@MainActor
struct RevokedSessionTests {

  private let revoked = ProfileStubServer.Reply.json(401, #"{"error":"token_revoked"}"#)

  /// Runs `body` with the app pointed at the stub, holding a token and no saved password.
  private func signedIn(routes: [String: ProfileStubServer.Reply],
                        _ body: @escaping (AppState) async -> Void) async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(routes)
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        state.savedPassword = ""
        state.loginError = nil
        state.isOffline = false
        state.serverUnreachable = false
        await body(state)
      }
    }
  }

  /// Makes a real request that the stub refuses, and hands the error to the app the way every
  /// view's catch block does.
  private func useTheApp(_ state: AppState) async {
    do { _ = try await state.api.itemDetail(id: "any-title") } catch { state.handleConnectionFailure(error) }
  }

  /// OC-1123 · given a session token revoked server-side and nothing to re-authenticate with
  /// silently (refresh is refused too, no saved password), when the user uses the app, then the
  /// session is ended with the expired-session sentence on the sign-in screen, and the app does
  /// NOT claim to be offline or the server unreachable; exactly one refresh attempt was made.
  /// Red if: a 401 revocation is classed as a connectivity problem, the dead token is kept so
  /// the user stays on an authenticated-looking screen, or the sentence is not the session one.
  @Test func aRevokedTokenEndsTheSessionWithASignInPathAndNeverReadsAsOffline() async {
    await signedIn(routes: [
      "GET /api/v1/items/any-title": revoked,
      "POST /api/v1/auth/refresh": revoked,
    ]) { state in
      #expect(state.sessionToken == "stub-token", "precondition: signed in")

      await useTheApp(state)

      #expect(await eventually { state.sessionToken == nil }, "the dead token is dropped")
      #expect(state.loginError == "Your session expired. Please sign in again.")
      #expect(!state.isOffline)
      #expect(!state.serverUnreachable)
      #expect(ProfileStubServer.count("POST /api/v1/auth/refresh") == 1)
    }
  }

  /// OC-1123 (re-authenticate path) · given a revoked token but a server that still accepts a
  /// refresh, when three requests fail together with 401, then the user is never interrupted:
  /// still signed in, on the NEW token, with no sign-in message, and the burst made ONE refresh.
  /// Red if: recovery is skipped (the user is bounced to sign-in for a recoverable expiry), the
  /// new token is not adopted, or each of the three failures fires its own refresh.
  @Test func aRefreshThatWorksKeepsTheUserSignedInOnTheNewToken() async {
    let fresh = ProfileStubServer.Reply.json(
      200, #"{"token":"fresh-token","user":{"id":"u1","username":"ryan","displayName":"Ryan"}}"#)
    await signedIn(routes: [
      "GET /api/v1/items/any-title": revoked,
      "POST /api/v1/auth/refresh": fresh,
    ]) { state in
      var refusal: Error?
      do { _ = try await state.api.itemDetail(id: "any-title") } catch { refusal = error }
      guard let error = refusal else { Issue.record("the stub's 401 did not surface as an error"); return }
      // Three views fail in the same instant, as they do when a token dies mid-screen.
      state.handleConnectionFailure(error)
      state.handleConnectionFailure(error)
      state.handleConnectionFailure(error)

      #expect(await eventually { state.sessionToken == "fresh-token" }, "the new token is adopted")
      #expect(state.loginError == nil)
      #expect(!state.isOffline)
      #expect(!state.serverUnreachable)
      #expect(ProfileStubServer.count("POST /api/v1/auth/refresh") == 1, "one refresh for the burst")
    }
  }

  /// OC-1123 / M5 · given a 401 whose refresh then cannot reach the server at all (NAS off), when
  /// the user uses the app, then the session is NOT ended: same token, no sign-in message.
  /// Red if: a failed refresh is treated as a refused one, so an outage signs the user out.
  @Test func aRefreshThatCannotReachTheServerKeepsTheSession() async {
    await signedIn(routes: [
      "GET /api/v1/items/any-title": revoked,
      "POST /api/v1/auth/refresh": .unreachable,
    ]) { state in
      await useTheApp(state)
      #expect(await eventually { ProfileStubServer.count("POST /api/v1/auth/refresh") == 1 },
              "precondition: the refresh was attempted")
      try? await Task.sleep(for: .milliseconds(300))

      #expect(state.sessionToken == "stub-token")
      #expect(state.loginError == nil)
    }
  }

  /// OC-1123 boundary · given a refusal that is NOT a session problem (403 admin_required: this
  /// user lacks a privilege), when the user uses the app, then the session is untouched: same
  /// token, no sign-in message, no refresh attempted.
  /// Red if: any 403 is treated as a revoked session.
  @Test func aPrivilegeRefusalIsNotASessionProblem() async {
    await signedIn(routes: [
      "GET /api/v1/items/any-title": .json(403, #"{"error":"admin_required"}"#),
      "POST /api/v1/auth/refresh": revoked,
    ]) { state in
      await useTheApp(state)
      try? await Task.sleep(for: .milliseconds(300))

      #expect(state.sessionToken == "stub-token")
      #expect(state.loginError == nil)
      #expect(ProfileStubServer.count("POST /api/v1/auth/refresh") == 0)
    }
  }
}
