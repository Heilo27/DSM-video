import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-972 · a device that has never connected pairs with a code (FR-117)
//
// A brand-new Apple TV has no server address. Redeeming a code used to build a URL from that
// empty address and stop with "Invalid server address" before asking any server anything. The
// fresh device now finds the server on its local network (stubbed here: the discovery seam
// answers with the stub host), redeems the code there, and keeps both the address that
// answered and the connection details the generating device sent with the code.
//
// Every request goes through the real APIClient to ProfileStubServer. Expected values are
// literals from the spec and the server's wire format, never recomputed from production code.

@Suite("First-time pairing", .serialized)
@MainActor
struct PairingFirstTimeTests {
  private let stubURL = URL(string: "http://\(ProfileStubServer.host)")!
  private let exchangeKey = "POST /api/v1/auth/pairing/exchange"
  private let generateKey = "POST /api/v1/auth/pairing/generate"

  private let signedIn = #"{"token":"tv-session","user":{"id":"u1","username":"ryan","displayName":"Ryan"}"#

  /// A factory-fresh device: no address of any kind, signed out. `discover` stands in for the
  /// local-network browse.
  private func onFreshDevice(
    discover: @escaping @MainActor () async -> (urls: [URL], denied: Bool),
    _ body: (AppState) async -> Void
  ) async {
    await ProfileStateGate.shared.run {
      await withIsolatedAppState { state in
        let saved = SavedAddresses(state)
        state.rememberMe = false
        state.useHTTPS = false
        state.sessionToken = nil
        state.baseURL = ""
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.quickConnectID = ""
        state.quickConnectResolve = { id in
          Issue.record("QuickConnect was queried for \(id) on a device with nothing configured")
          return []
        }
        state.discoverPairingServers = discover
        await body(state)
        state.sessionToken = nil
        saved.restore(state)
      }
    }
  }

  /// OC: TASK-972 AC-1, AC-4 · a valid code on a device with an empty address signs it in, and
  /// the device ends with a working address plus the generator's LAN, WAN and QuickConnect.
  /// Red if: the exchange stops at "Invalid server address", or the response's `server` object
  /// is not kept (a response with no address fails the lan/wan expectations).
  @Test func freshDevicePairsAndKeepsTheServerAddress() async {
    ProfileStubServer.reset([
      exchangeKey: .json(200, signedIn + #","server":{"quickConnectId":"ryans-nas","lanAddress":"http://192.168.50.148:8090","wanAddress":"nas.example.org:8091"}}"#),
    ])
    var discoveries = 0
    await onFreshDevice(discover: { discoveries += 1; return ([stubURL], false) }) { state in
      await state.exchangePairingCode("123456")

      #expect(state.loginError == nil, "\(state.loginError ?? "")")
      #expect(state.sessionToken == "tv-session")
      #expect(discoveries == 1)
      #expect(ProfileStubServer.count(exchangeKey) == 1)
      #expect(ProfileStubServer.requests.first { "\($0.method) \($0.path)" == exchangeKey }?.body.contains("123456") == true)
      // The address that answered is the device's server from now on.
      #expect(state.baseURL == "http://profiles.stub.test")
      #expect(state.lastGoodAddress == "http://profiles.stub.test")
      #expect(state.api.baseURL.host == ProfileStubServer.host)
      // And it can reach the server away from the network it paired on.
      #expect(state.lanAddress == "http://192.168.50.148:8090")
      #expect(state.wanAddress == "nas.example.org:8091")
    }
  }

  /// OC: TASK-972 · with no WAN address from the generator, its QuickConnect ID is kept as the
  /// way in from outside, the way ServerSetupView stores a QuickConnect sign-in.
  @Test func quickConnectIDIsKeptWhenThereIsNoWANAddress() async {
    ProfileStubServer.reset([
      exchangeKey: .json(200, signedIn + #","server":{"quickConnectId":"ryans-nas"}}"#),
    ])
    await onFreshDevice(discover: { ([stubURL], false) }) { state in
      await state.exchangePairingCode("123456")
      #expect(state.sessionToken == "tv-session")
      #expect(state.wanAddress == "ryans-nas")
    }
  }

  /// OC: TASK-972 AC-3 · a wrong code on a fresh device says the code is wrong.
  /// Red if: it says "Invalid server address" (the address was never the problem).
  @Test func wrongCodeOnAFreshDeviceSaysTheCodeIsWrong() async {
    ProfileStubServer.reset([exchangeKey: .json(401, #"{"error":"invalid_or_expired_code"}"#)])
    await onFreshDevice(discover: { ([stubURL], false) }) { state in
      await state.exchangePairingCode("000000")
      #expect(state.sessionToken == nil)
      #expect(state.loginError != AppState.invalidServerAddressMessage)
      #expect(state.loginError == "That pairing code is wrong or has expired. Generate a new one and try again.",
              "\(state.loginError ?? "nil")")
      #expect(state.baseURL == "", "a refused code must not leave an address behind")
    }
  }

  /// OC: TASK-972 · once a server has refused the code, the other addresses are the same
  /// server: asking them again only spends more of its wrong-code budget.
  @Test func aRefusedCodeIsNotRetriedOnAnotherAddress() async {
    ProfileStubServer.reset([exchangeKey: .json(401, #"{"error":"invalid_or_expired_code"}"#)])
    let second = URL(string: "http://\(ProfileStubServer.host):8090")!
    await onFreshDevice(discover: { ([stubURL, second], false) }) { state in
      await state.exchangePairingCode("000000")
      #expect(ProfileStubServer.count(exchangeKey) == 1)
    }
  }

  /// OC: TASK-972 · an address that does not answer is skipped for the next one.
  @Test func anUnreachableAddressFallsThroughToTheNext() async {
    ProfileStubServer.reset([
      exchangeKey: .json(200, signedIn + #","server":{"lanAddress":"http://192.168.50.148:8090"}}"#),
    ])
    let dead = URL(string: "http://127.0.0.1:9")!
    await onFreshDevice(discover: { ([dead, stubURL], false) }) { state in
      await state.exchangePairingCode("123456")
      #expect(state.sessionToken == "tv-session", "\(state.loginError ?? "")")
      #expect(state.baseURL == "http://profiles.stub.test")
    }
  }

  /// OC: TASK-972 · nothing on the network: say so, never "Invalid server address".
  @Test func noServerOnTheNetworkSaysSo() async {
    ProfileStubServer.reset([:])
    await onFreshDevice(discover: { ([], false) }) { state in
      await state.exchangePairingCode("123456")
      #expect(state.loginError == AppState.pairingNoServerFoundMessage)
      #expect(ProfileStubServer.count(exchangeKey) == 0)
    }
  }

  /// OC: TASK-972 / TASK-949 · discovery refused for Local Network access names that.
  @Test func localNetworkRefusedSaysSo() async {
    ProfileStubServer.reset([:])
    await onFreshDevice(discover: { ([], true) }) { state in
      await state.exchangePairingCode("123456")
      #expect(state.loginError == LocalNetworkPermission.deniedMessage)
    }
  }

  /// OC: TASK-972 · a device with an address configured uses it and never browses: a typo'd
  /// address must fail as a typo, not pair with whatever answers on the network.
  @Test func aConfiguredDeviceUsesItsAddressAndDoesNotBrowse() async {
    ProfileStubServer.reset([exchangeKey: .json(200, signedIn + "}")])
    await onFreshDevice(discover: {
      Issue.record("discovery ran on a device that has an address")
      return ([], false)
    }) { state in
      state.baseURL = ProfileStubServer.host
      await state.exchangePairingCode("123456")
      #expect(state.sessionToken == "tv-session", "\(state.loginError ?? "")")
      // The cascade normalises the typed host (scheme, default port); what matters is that
      // the configured server is the one kept.
      #expect(URL(string: state.baseURL)?.host == ProfileStubServer.host, "\(state.baseURL)")
    }
  }

  /// OC: TASK-972 · the signed-in device sends its connection details with the request for a
  /// code, so the server can hand them to the device that redeems it.
  /// Red if: generate is sent with no body (the redeeming device then learns no address).
  @Test func generatingACodeSendsThisDevicesConnectionDetails() async {
    ProfileStubServer.reset([generateKey: .json(200, #"{"code":"123456","expires_in_seconds":300}"#)])
    await ProfileStateGate.shared.run {
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        let saved = SavedAddresses(state)
        state.lanAddress = "http://192.168.50.148:8090"
        state.wanAddress = "ryans-nas"
        await state.generatePairingCode()
        #expect(state.pairingError == nil, "\(state.pairingError ?? "")")
        #expect(state.pairingCode == "123456")
        let body = ProfileStubServer.requests.first { "\($0.method) \($0.path)" == generateKey }?.body ?? ""
        let sent = try? JSONDecoder().decode(PairingServerInfo.self, from: Data(body.utf8))
        #expect(sent == PairingServerInfo(quickConnectId: "ryans-nas",
                                          lanAddress: "http://192.168.50.148:8090",
                                          wanAddress: "profiles.stub.test"),
                "sent: \(body)")
        state.sessionToken = nil
        saved.restore(state)
      }
    }
  }
}
