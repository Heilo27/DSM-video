import Foundation
import Security
import Testing
@testable import DSM_Video

// MARK: - A session survives a cold relaunch (TASK-967 · OC-1121, FRD-001 FR-119)
//
// "Relaunch" here is a brand-new AppState built over the same stores: it reads the Keychain and
// UserDefaults the way a freshly launched process does, so nothing is observed from the instance
// that signed in. Sign-in and pairing are driven through the real APIClient to ProfileStubServer.
// Expected values are literals. The real Keychain items for the app are snapshotted first and put
// back afterwards, so running this on a machine with a signed-in simulator does not sign it out.

private let crService = "com.heiloprojects.dsreel"  // AppState.Keys.keychainService (private to AppState)
private let crAccounts = ["sessionToken", "savedPassword"]

private func crRead(_ account: String) -> String? {
  let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                              kSecAttrService as String: crService, kSecAttrAccount as String: account,
                              kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
  var out: AnyObject?
  guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
  return String(data: d, encoding: .utf8)
}

private func crWrite(_ value: String?, account: String) {
  let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: crService, kSecAttrAccount as String: account]
  SecItemDelete(key as CFDictionary)
  guard let value else { return }
  var add = key
  add[kSecValueData as String] = Data(value.utf8)
  add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  SecItemAdd(add as CFDictionary, nil)
}

@MainActor
@Suite("OC-1121 · a session survives a cold relaunch", .serialized)
struct ColdRelaunchSessionTests {
  private let loginKey = "POST /api/v1/auth/login"
  private let exchangeKey = "POST /api/v1/auth/pairing/exchange"
  private var stubURL: URL { URL(string: "http://\(ProfileStubServer.host)")! }

  /// Runs `body` on a signed-out device pointed at the stub server, with the app's real Keychain
  /// items and Remember Me / address settings put back afterwards.
  private func onSignedOutDevice(rememberMe: Bool,
                                 _ body: (AppState, () -> AppState) async -> Void) async {
    let keychainBefore = crAccounts.map { ($0, crRead($0)) }
    let usernameBefore = UserDefaults.standard.string(forKey: "dsReel.username")
    await ProfileStateGate.shared.run {
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        let saved = SavedAddresses(state)
        state.rememberMe = rememberMe
        state.sessionToken = nil
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        for account in crAccounts { crWrite(nil, account: account) }
        // A cold launch: a new AppState over the same stores, reading Keychain + UserDefaults.
        let relaunch = { AppState(profileStore: state.profileStore, localStore: state.localStore) }
        await body(state, relaunch)
        state.sessionToken = nil
        saved.restore(state)
      }
    }
    for (account, value) in keychainBefore { crWrite(value, account: account) }
    if let usernameBefore { UserDefaults.standard.set(usernameBefore, forKey: "dsReel.username") }
    else { UserDefaults.standard.removeObject(forKey: "dsReel.username") }
  }

  private func signedIn(_ token: String) -> ProfileStubServer.Reply {
    .json(200, #"{"token":"\#(token)","user":{"id":"u1","username":"ryan","displayName":"Ryan"}}"#)
  }

  /// OC-1121 (sign-in) · given a user who signed in with Remember Me on, when the app is
  /// launched cold, then the new launch holds the same session token and the server address,
  /// shows no sign-in error, and is not in demo mode: nothing asks for credentials again.
  /// Red if: the token is no longer persisted on sign-in, the launch stops loading it, or the
  /// address the session belongs to is not restored.
  @Test func signInSurvivesAColdLaunch() async {
    ProfileStubServer.reset([loginKey: signedIn("cold-signin-token")])
    await onSignedOutDevice(rememberMe: true) { state, relaunch in
      state.username = "ryan"
      state.savedPassword = "correct-horse"
      await state.login()
      #expect(state.sessionToken == "cold-signin-token", "precondition: sign-in worked: \(state.loginError ?? "")")

      let next = relaunch()

      #expect(next.sessionToken == "cold-signin-token")
      #expect(next.isDemoMode == false)
      #expect(next.loginError == nil)
      #expect(next.baseURL == state.baseURL, "the session's server address comes back too")
      #expect(next.api.baseURL.host == ProfileStubServer.host)
    }
  }

  /// OC-1121 (pairing) · given a device paired with a code and Remember Me on, when the app is
  /// launched cold, then the new launch holds the token the pairing issued and no error.
  /// Red if: the pairing path sets the session without persisting it, or the launch drops it.
  @Test func pairingSurvivesAColdLaunch() async {
    ProfileStubServer.reset([exchangeKey: signedIn("cold-paired-token")])
    await onSignedOutDevice(rememberMe: true) { state, relaunch in
      state.discoverPairingServers = { ([stubURL], false) }
      await state.exchangePairingCode("123456")
      #expect(state.sessionToken == "cold-paired-token", "precondition: pairing worked: \(state.loginError ?? "")")

      let next = relaunch()

      #expect(next.sessionToken == "cold-paired-token")
      #expect(next.isDemoMode == false)
      #expect(next.loginError == nil)
    }
  }

  /// OC-1121 negative · given a sign-in the server rejected (wrong password), when the app is
  /// launched cold, then there is no session: a failed sign-in leaves no token behind.
  /// Red if: a rejected sign-in persists or invents a session that the next launch restores.
  @Test func aRejectedSignInLeavesNoSessionForTheNextLaunch() async {
    ProfileStubServer.reset([loginKey: .json(401, #"{"error":"invalid_credentials"}"#)])
    await onSignedOutDevice(rememberMe: true) { state, relaunch in
      state.username = "ryan"
      state.savedPassword = "wrong"
      await state.login()
      #expect(state.sessionToken == nil, "precondition: the server refused the sign-in")

      let next = relaunch()

      #expect(next.sessionToken == nil)
    }
  }

  /// OC-1121 boundary · given a user who signed in with Remember Me OFF, when the app is
  /// launched cold, then they are signed out (the opt-out is honoured) while the live instance
  /// stays signed in for the run.
  /// Red if: the token is written to the Keychain regardless of Remember Me.
  @Test func rememberMeOffDoesNotCarrySessionAcrossALaunch() async {
    ProfileStubServer.reset([loginKey: signedIn("cold-ephemeral-token")])
    await onSignedOutDevice(rememberMe: false) { state, relaunch in
      state.username = "ryan"
      state.savedPassword = "correct-horse"
      await state.login()
      #expect(state.sessionToken == "cold-ephemeral-token", "precondition: sign-in worked: \(state.loginError ?? "")")

      let next = relaunch()

      #expect(next.sessionToken == nil)
      #expect(crRead("sessionToken") == nil, "the Keychain holds no token")
    }
  }
}
