import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-1030 · the QuickConnect ID a device signed in or paired through keeps being tried
//
// FR-111 (FRD-001), M5 (FRD-000): QuickConnect is a remote-access path, relay included. A
// successful sign-in replaced baseURL with the URL that answered, and the cascade asked
// QuickConnect only when baseURL itself was an ID, so after the first success the ID was never
// tried again. Away from home the device had its LAN address or nothing, and no relay.
//
// Sign-in and pairing go through the real APIClient to ProfileStubServer; QuickConnect is the
// injected resolver, which records every ID it is asked for.

@MainActor
final class QuickConnectLookups {
  var ids: [String] = []
}

@Suite("QuickConnect ID retention (TASK-1030)", .serialized)
@MainActor
struct QuickConnectRetentionTests {
  private let stubURL = URL(string: "http://\(ProfileStubServer.host)")!
  private let loginKey = "POST /api/v1/auth/login"
  private let exchangeKey = "POST /api/v1/auth/pairing/exchange"
  /// Left open so pairing can append its `"server"` object; a login body closes it with "}".
  private let signedIn = #"{"token":"qc-session","user":{"id":"u1","username":"ryan","displayName":"Ryan"}"#
  private let version = #"{"serverVersion":"1.0.0","minClientVersion":"1.0.0","capabilities":[]}"#

  /// Signed out, no address of any kind; QuickConnect "ryans-nas" resolves to the stub.
  private func onBlankDevice(_ body: (AppState, QuickConnectLookups) async -> Void) async {
    await ProfileStateGate.shared.run {
      await withIsolatedAppState { state in
        let saved = SavedAddresses(state)
        state.rememberMe = false        // never write a test token to the Keychain
        state.useHTTPS = false
        state.sessionToken = nil
        state.baseURL = ""
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.quickConnectID = ""
        state.username = "ryan"
        state.setPassword("")           // an empty password is never saved to the Keychain
        let lookups = QuickConnectLookups()
        let stub = stubURL
        state.quickConnectResolve = { id in
          lookups.ids.append(id)
          return [.init(url: stub, requiresTunnelCookie: false)]
        }
        state.discoverPairingServers = { ([stub], false) }
        await body(state, lookups)
        state.sessionToken = nil
        saved.restore(state)
      }
    }
  }

  /// What the next connection attempt asks QuickConnect for.
  private func idsAskedOnNextAttempt(_ state: AppState, _ lookups: QuickConnectLookups) async
    -> (ids: [String], candidates: [QuickConnectResolver.Candidate]) {
    lookups.ids = []
    let set = await state.resolveCandidateSet()
    return (lookups.ids, set.candidates)
  }

  /// OC: AC-1, AC-3 · an iOS QuickConnect sign-in (ServerSetupView.connect stores the ID as the
  /// address and in the WAN slot) succeeds; the next attempt still asks QuickConnect for it, and
  /// the sign-in screen offers the ID again.
  /// Red if: the cascade reads the ID only from baseURL, which the sign-in replaced.
  @Test func iOSQuickConnectSignInKeepsAskingQuickConnect() async {
    ProfileStubServer.reset([loginKey: .json(200, signedIn + "}")])
    await onBlankDevice { state, lookups in
      state.useSignInAddress("ryans-nas")
      state.wanAddress = "ryans-nas"
      await state.login()
      #expect(state.sessionToken == "qc-session", "\(state.loginError ?? "")")
      #expect(state.baseURL == "http://profiles.stub.test", "precondition: the winner replaced the ID")

      let next = await idsAskedOnNextAttempt(state, lookups)
      #expect(next.ids == ["ryans-nas"])
      #expect(next.candidates.contains { $0.url.host == ProfileStubServer.host })
      #expect(state.signInAddress == "ryans-nas")
    }
  }

  /// OC: AC-1, AC-3 · a tvOS QuickConnect sign-in stores the ID only as the address.
  /// Red if: a successful sign-in does not keep the ID before the winner replaces baseURL.
  @Test func tvOSQuickConnectSignInKeepsAskingQuickConnect() async {
    ProfileStubServer.reset([loginKey: .json(200, signedIn + "}")])
    await onBlankDevice { state, lookups in
      state.baseURL = "ryans-nas"
      await state.login()
      #expect(state.sessionToken == "qc-session", "\(state.loginError ?? "")")
      #expect(state.baseURL == "http://profiles.stub.test", "precondition: the winner replaced the ID")

      let next = await idsAskedOnNextAttempt(state, lookups)
      #expect(next.ids == ["ryans-nas"])
      #expect(state.signInAddress == "ryans-nas")
    }
  }

  /// OC: AC-2 · pairing whose server info carries a WAN address AND a QuickConnect ID.
  /// Red if: the ID is dropped because the WAN slot was filled by the WAN address.
  @Test func pairingKeepsTheQuickConnectIDBesideAWANAddress() async {
    ProfileStubServer.reset([
      exchangeKey: .json(200, signedIn + #","server":{"quickConnectId":"ryans-nas","wanAddress":"nas.example.org:8091"}}"#),
    ])
    await onBlankDevice { state, lookups in
      await state.exchangePairingCode("123456")
      #expect(state.sessionToken == "qc-session", "\(state.loginError ?? "")")

      let next = await idsAskedOnNextAttempt(state, lookups)
      #expect(next.ids == ["ryans-nas"])
      #expect(next.candidates.contains { $0.url.host == "nas.example.org" }, "the WAN address is still tried")
    }
  }

  /// OC: AC-2 · pairing whose server info carries only the QuickConnect ID.
  /// Red if: an ID kept in the WAN slot is skipped as "not a direct address" and never resolved.
  @Test func pairingWithOnlyAQuickConnectIDAsksQuickConnect() async {
    ProfileStubServer.reset([
      exchangeKey: .json(200, signedIn + #","server":{"quickConnectId":"ryans-nas"}}"#),
    ])
    await onBlankDevice { state, lookups in
      await state.exchangePairingCode("123456")
      #expect(state.sessionToken == "qc-session", "\(state.loginError ?? "")")

      let next = await idsAskedOnNextAttempt(state, lookups)
      #expect(next.ids == ["ryans-nas"])
    }
  }

  /// OC: AC-4 · after a QuickConnect sign-in the user signs in with a direct address instead.
  /// Red if: the old ID is still asked for, or still offered on the sign-in screen.
  @Test func signingInWithADirectAddressStopsAskingTheOldID() async {
    ProfileStubServer.reset([loginKey: .json(200, signedIn + "}")])
    await onBlankDevice { state, lookups in
      state.baseURL = "ryans-nas"
      await state.login()
      #expect(state.sessionToken == "qc-session", "precondition: \(state.loginError ?? "")")

      state.useSignInAddress("http://192.168.1.20:5000")
      state.lanAddress = ""
      state.wanAddress = ""
      let next = await idsAskedOnNextAttempt(state, lookups)
      #expect(next.ids.isEmpty)
      #expect(next.candidates.map(\.url.absoluteString) == ["http://192.168.1.20:5000"])
      #expect(state.signInAddress == "http://192.168.1.20:5000")
    }
  }

  /// OC: AC-1 · the away-from-home case end to end: the LAN address the device learned does not
  /// answer, and reconnect reaches the server through QuickConnect.
  /// Red if: reconnect's cascade is LAN-only after a QuickConnect sign-in.
  @Test func awayFromHomeReconnectReachesTheServerThroughQuickConnect() async {
    ProfileStubServer.reset([
      "GET /api/v1/version": .json(200, version),
      "GET /api/v1/sync/status": .json(200, #"{"itemSeq":1,"progressSeq":1}"#),
    ])
    await onBlankDevice { state, lookups in
      // Where a QuickConnect sign-in at home leaves a device: the winning LAN URL as baseURL and
      // the LAN slot, and the ID kept. 127.0.0.1:9 refuses at once, as a home LAN does away.
      state.quickConnectID = "ryans-nas"
      state.baseURL = "http://127.0.0.1:9"
      state.lanAddress = "http://127.0.0.1:9"
      state.sessionToken = "qc-session"
      state.serverUnreachable = true

      let ok = await state.reconnect()

      #expect(lookups.ids.contains("ryans-nas"))
      #expect(ok, "QuickConnect's address answered")
      #expect(state.api.baseURL.host == ProfileStubServer.host)
      #expect(state.quickConnectID == "ryans-nas", "reconnect keeps the ID")
    }
  }
}
