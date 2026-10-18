import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-973 / TASK-953 · an unreachable server never costs the user their session
//
// FR-120 / FR-121 (FRD-001), M5 (FRD-000): only the server's own 401 may end a session. A
// NAS that is off or a QuickConnect outage must leave the user signed in on cached content
// under the "Can't reach your NAS" banner, retrying, for as long as it lasts.

/// Counts QuickConnect lookups. Main-actor so the resolver closure and the test share it.
@MainActor
final class ResolverProbe {
  var calls = 0
}

/// The address settings AppState keeps in UserDefaults.standard, put back after a test that
/// has to point the state at a QuickConnect id.
@MainActor
struct SavedAddresses {
  let base, lan, wan, lastGood, quickConnect: String
  let https, remember: Bool
  init(_ s: AppState) {
    base = s.baseURL; lan = s.lanAddress; wan = s.wanAddress; lastGood = s.lastGoodAddress
    quickConnect = s.quickConnectID
    https = s.useHTTPS; remember = s.rememberMe
  }
  func restore(_ s: AppState) {
    s.baseURL = base; s.lanAddress = lan; s.wanAddress = wan; s.lastGoodAddress = lastGood
    s.quickConnectID = quickConnect
    s.useHTTPS = https; s.rememberMe = remember
  }
}

@Suite("Connection resilience", .serialized)
@MainActor
struct ConnectionResilienceTests {

  /// OC: TASK-973 AC · given a signed-in user with a cached library whose QuickConnect id
  /// cannot be resolved, when homeLoad runs and the background reconnect spends its whole fast
  /// ladder failing, then the session token is still there, no sign-in message was raised,
  /// the server-offline banner is up, and the lookups keep going.
  /// Red if: exhausting the reconnect attempts signs out (softLogout), the cold-start path
  /// leaves the banner down, or the retry stops after the ladder.
  @Test func unreachableQuickConnectKeepsTheSessionAndKeepsRetrying() async {
    await ProfileStateGate.shared.run {
      await withIsolatedAppState { state in
        let saved = SavedAddresses(state)
        state.rememberMe = false  // never write the test token to the Keychain
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.baseURL = ""                    // the unconfigured client is the placeholder
        state.baseURL = "oc973-unknown-nas"   // a bare QuickConnect id leaves it there
        state.sessionToken = "oc973-token"
        await state.localStore.upsertItems([
          ItemSummary(id: "heat", type: "movie", title: "Heat", addedAt: "2026-01-01T00:00:00Z",
                      libraryId: "lib_973", changeSeq: 1, ageLevel: 1)])

        let probe = ResolverProbe()
        state.quickConnectResolve = { _ in
          probe.calls += 1
          throw URLError(.cannotFindHost)
        }
        let fastAttempts = 3
        state.reconnectRetryPolicy = .init(
          fastDelays: Array(repeating: .milliseconds(10), count: fastAttempts),
          slowInterval: .milliseconds(20))

        #expect(state.api.baseURL == AppState.fallbackURL, "precondition: the QC id is unresolved")
        #expect(await state.localStore.hasItems(), "precondition: a cached library")
        #expect(!state.needsProfilePicker, "precondition: homeLoad is not held by the picker")

        await state.homeLoad()

        // homeLoad's own lookup, the whole fast ladder, and a few slow-cadence attempts after it.
        let target = 1 + fastAttempts + 3
        for _ in 0..<500 where probe.calls < target {
          try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(probe.calls >= target, "the retry kept going past the fast ladder (calls: \(probe.calls))")
        #expect(state.sessionToken == "oc973-token", "an unreachable server never clears the session")
        #expect(state.loginError == nil, "nothing sent the user to sign in")
        #expect(state.serverUnreachable, "the server-offline banner is up while retrying")
        #expect(!state.homeAllRailsEmpty, "the cached library is still on screen")

        state.reconnectRetryTask?.cancel()
        state.sessionToken = nil
        saved.restore(state)
      }
    }
  }

  /// OC: TASK-953 AC · APIClient reports transport failures as APIError.connection(code); a
  /// refused connection must raise the server-offline banner exactly as a bare URLError does.
  /// Red if: handleConnectionFailure lets .connection fall to its no-op default.
  @Test func connectionErrorFromTheClientRaisesServerUnreachable() async {
    await withIsolatedAppState { state in
      #expect(!state.serverUnreachable && !state.isOffline, "precondition: healthy")
      state.handleConnectionFailure(APIError.connection(.cannotConnectToHost))
      #expect(state.serverUnreachable)
      #expect(!state.isOffline, "the device's own network is fine")
    }
    await withIsolatedAppState { state in
      state.handleConnectionFailure(APIError.connection(.timedOut))
      #expect(state.serverUnreachable)
    }
  }

  /// OC: TASK-953 AC · no internet on the device is offline, not server-unreachable.
  @Test func notConnectedToInternetFromTheClientSetsOffline() async {
    await withIsolatedAppState { state in
      state.handleConnectionFailure(APIError.connection(.notConnectedToInternet))
      #expect(state.isOffline)
      #expect(!state.serverUnreachable)
    }
  }

  /// OC: TASK-953 AC · a cancelled request (the user navigated away) changes nothing.
  @Test func cancelledConnectionChangesNothing() async {
    await withIsolatedAppState { state in
      state.handleConnectionFailure(APIError.connection(.cancelled))
      #expect(!state.serverUnreachable)
      #expect(!state.isOffline)
    }
  }

  /// OC: TASK-953 sweep · once the banner can be raised from any screen, the server answering
  /// again must take it down; homeLoad and foregroundRefresh both skip while it is up, so the
  /// heartbeat is what notices.
  /// Red if: a successful heartbeat leaves serverUnreachable set.
  @Test func answeredHeartbeatClearsAStaleServerUnreachable() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset([
        "GET /api/v1/sync/heartbeat": .json(200, #"{"itemSeq":0,"progressSeq":0,"serverTimeMs":0}"#)
      ])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        state.serverUnreachable = true
        await state.runHeartbeat()
        #expect(ProfileStubServer.count("GET /api/v1/sync/heartbeat") == 1, "precondition: the beat reached the stub")
        #expect(!state.serverUnreachable, "the server answered; the banner comes down")
        state.sessionToken = nil
      }
    }
  }
}
