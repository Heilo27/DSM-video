import Testing
import Foundation
@testable import DSM_Video

// TASK-1013 (FR-120, FR-121): at launch, a token whose `exp` had passed was deleted on the
// spot with "Your session expired", no request made. The device was ending the session on its
// own clock, and a NAS that was off at launch cost the user their sign-in. Only the server
// rejecting the session may end it.
//
// The sibling: when the server DID reject the token and the fallback login failed too, the old
// token was still in place, so the 401 path read that as a recovery and kept a dead session.

@Suite("Session expiry (TASK-1013)", .serialized)
@MainActor
struct SessionExpiryTests {
  private static let refresh = "POST /api/v1/auth/refresh"
  private static let login = "POST /api/v1/auth/login"

  /// A JWT whose only claim is `exp`, `offset` seconds from now. The app never checks the
  /// signature, so the third part is a placeholder.
  private func jwt(expiresIn offset: TimeInterval) -> String {
    let exp = Int(Date().timeIntervalSince1970 + offset)
    let payload = Data(#"{"exp":\#(exp)}"#.utf8).base64EncodedString()
      .replacingOccurrences(of: "=", with: "")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
    return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
  }

  /// A signed-in AppState on the stub server, with a saved password so the fallback login
  /// runs too, and no other address it could try.
  private func withSession(
    token: String, routes: [String: ProfileStubServer.Reply], _ body: (AppState) async -> Void
  ) async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(routes)
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        let saved = SavedAddresses(state)
        let savedUsername = state.username
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.quickConnectID = ""
        state.username = "tester"
        state.savedPassword = "pw"
        state.sessionToken = token
        await body(state)
        state.sessionToken = nil
        state.savedPassword = ""
        state.username = savedUsername
        saved.restore(state)
      }
    }
  }

  /// OC: AC-1 · with the NAS unreachable and a token that looks expired or close to it, the
  /// launch check keeps the token and raises no sign-in message, after asking the server.
  /// Red if: the expired branch signs out locally again, or a failed fallback login leaves its
  /// "couldn't reach" text in loginError, or the check never asks the server.
  @Test(arguments: [-3600.0, 3600.0])
  func anUnreachableServerKeepsTheSessionAtLaunch(expiresIn: TimeInterval) async {
    let token = jwt(expiresIn: expiresIn)
    await withSession(token: token, routes: [Self.refresh: .unreachable, Self.login: .unreachable]) { state in
      await state.checkTokenExpiryOnLaunch(settleDelay: .zero)
      #expect(state.sessionToken == token, "the session survives the outage")
      #expect(state.loginError == nil, "no sign-in message for a session nobody rejected")
      #expect(ProfileStubServer.count(Self.refresh) == 1, "the server was asked")
    }
  }

  /// A token the server renews is replaced, and the user stays signed in.
  /// Red if: the launch check stops renewing an expired-looking token.
  @Test func anExpiredLookingTokenTheServerAcceptsIsRenewed() async {
    let reply = #"{"token":"fresh-token","user":{"id":"u1","username":"tester","displayName":"Tester"}}"#
    await withSession(token: jwt(expiresIn: -60), routes: [Self.refresh: .json(200, reply)]) { state in
      await state.checkTokenExpiryOnLaunch(settleDelay: .zero)
      #expect(state.sessionToken == "fresh-token")
      #expect(state.loginError == nil)
      #expect(ProfileStubServer.count(Self.login) == 0, "no password was re-sent")
    }
  }

  /// OC: AC-2 · the server rejecting the session ends it, as a session problem, even with a
  /// saved password whose login is rejected too.
  /// Red if: a failed fallback login is read as a recovery because the old token is still there.
  @Test func aServerRejectionEndsTheSessionAtLaunch() async {
    await withSession(token: jwt(expiresIn: 3600), routes: [
      Self.refresh: .json(401, #"{"error":"invalid_token"}"#),
      Self.login: .json(401, #"{"error":"invalid_credentials"}"#),
    ]) { state in
      await state.checkTokenExpiryOnLaunch(settleDelay: .zero)
      #expect(state.sessionToken == nil)
      #expect(state.loginError == "Your session expired. Please sign in again.")
    }
  }

  /// The same rule for a 401 mid-use: handleConnectionFailure's silent re-auth ends a session
  /// the server rejects, and keeps one it merely cannot reach.
  /// Red if: the 401 path reads a failed fallback login as a recovery, or ends a session when
  /// the renewal never reached the server.
  @Test func aRejectionMidUseEndsTheSessionAndAnOutageDoesNot() async {
    let rejected = APIError.server("invalid_token", status: 401)
    await withSession(token: "mid-use-token", routes: [
      Self.refresh: .json(401, #"{"error":"invalid_token"}"#),
      Self.login: .json(401, #"{"error":"invalid_credentials"}"#),
    ]) { state in
      state.handleConnectionFailure(rejected)
      for _ in 0..<300 where state.sessionToken != nil { try? await Task.sleep(for: .milliseconds(10)) }
      #expect(state.sessionToken == nil, "the server refused it")
      #expect(state.loginError == "Your session expired. Please sign in again.")
    }
    await withSession(token: "mid-use-token", routes: [Self.refresh: .unreachable, Self.login: .unreachable]) { state in
      state.handleConnectionFailure(rejected)
      for _ in 0..<300 where ProfileStubServer.count(Self.login) == 0 { try? await Task.sleep(for: .milliseconds(10)) }
      try? await Task.sleep(for: .milliseconds(100))
      #expect(ProfileStubServer.count(Self.login) >= 1, "the renewal ran through its fallback")
      #expect(state.sessionToken == "mid-use-token", "an outage during renewal keeps the session")
      #expect(state.loginError == nil)
    }
  }
}
