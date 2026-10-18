import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-974 · a QuickConnect ID that resolves to nothing says why
//
// FR-115 (FRD-001): an unresolvable QuickConnect ID, an unreachable server and a malformed address
// are different failures. Before this, an unknown ID and a failed lookup both came back from the
// resolver as an empty list, and sign-in reported both as "Invalid server address".
//
// The resolver runs for real in every test below; only its Serv.php round trip is stubbed.

@Suite("QuickConnect failure messages", .serialized)
@MainActor
struct QuickConnectFailureTests {

  /// Points `state` at `address` with no saved LAN/WAN fallbacks, routes QuickConnect lookups
  /// through `query`, runs `action`, and returns the message the user is shown.
  private func message(
    for address: String,
    query: @escaping QuickConnectResolver.Query = { _, _ in
      Issue.record("QuickConnect was queried for an address that is not a QuickConnect ID")
      return [:]
    },
    via action: (AppState) async -> Void = { await $0.login() }
  ) async -> String? {
    var shown: String?
    await ProfileStateGate.shared.run {
      await withIsolatedAppState { state in
        let saved = SavedAddresses(state)
        state.rememberMe = false
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.baseURL = address
        state.quickConnectResolve = { try await QuickConnectResolver.resolveCandidates(id: $0, query: query) }
        await action(state)
        shown = state.loginError
        state.sessionToken = nil
        saved.restore(state)
      }
    }
    return shown
  }

  /// OC: TASK-974 AC · QuickConnect answers errno != 0 for an ID nobody registered.
  /// Red if: the resolver returns [] and sign-in says "Invalid server address".
  @Test func unknownIDIsNamedAsNotFound() async {
    let shown = await message(for: "oc974-typo", query: { _, _ in ["errno": 4, "suberrno": 2] })
    #expect(shown?.contains("\"oc974-typo\"") == true, "names the ID the user typed: \(shown ?? "nil")")
    #expect(shown?.contains("wasn't found") == true, "says it was not found: \(shown ?? "nil")")
    #expect(shown != AppState.invalidServerAddressMessage)
  }

  /// OC: TASK-974 AC · the lookup never reached Synology.
  /// Red if: a thrown URLError is swallowed into "Invalid server address".
  @Test func failedLookupSaysQuickConnectWasNotReached() async {
    let shown = await message(for: "oc974-nas", query: { _, _ in throw URLError(.notConnectedToInternet) })
    #expect(shown?.contains("Couldn't reach QuickConnect") == true, "names the lookup as the failure: \(shown ?? "nil")")
    #expect(shown != AppState.invalidServerAddressMessage)
  }

  /// OC: TASK-974 AC · "Invalid server address" is kept for input that does not parse.
  @Test func malformedAddressIsTheOnlyInvalidAddress() async {
    let shown = await message(for: "http://[nas")
    #expect(shown == AppState.invalidServerAddressMessage)
  }

  /// OC: TASK-974 AC · the three failures read as three different messages.
  @Test func theThreeFailuresAreDistinct() async {
    let unknown = await message(for: "oc974-a", query: { _, _ in ["errno": 4] })
    let lookup = await message(for: "oc974-b", query: { _, _ in throw URLError(.timedOut) })
    let malformed = await message(for: "http://[nas")
    #expect(Set([unknown, lookup, malformed].compactMap { $0 }).count == 3,
            "unknown: \(unknown ?? "nil") | lookup: \(lookup ?? "nil") | malformed: \(malformed ?? "nil")")
  }

  /// OC: TASK-974 sweep · a registered ID whose NAS publishes no address is neither a typo nor a
  /// network fault. Red if: the empty server record surfaces as "Invalid server address".
  @Test func registeredIDWithNoAddressSaysSo() async {
    let shown = await message(for: "oc974-quiet", query: { _, _ in ["errno": 0, "server": [String: Any]()] })
    #expect(shown == QuickConnectError.noAddress(id: "oc974-quiet").userMessage, "\(shown ?? "nil")")
  }

  /// OC: TASK-974 sweep · pairing a device by QuickConnect ID reports the same reasons as sign-in.
  /// Red if: pairing still calls every failure "Couldn't reach … Check your connection".
  @Test func pairingWithAnUnknownIDSaysNotFound() async {
    let shown = await message(for: "oc974-pair", query: { _, _ in ["errno": 4] },
                              via: { await $0.exchangePairingCode("123456") })
    #expect(shown?.contains("wasn't found") == true, "\(shown ?? "nil")")
  }
}
