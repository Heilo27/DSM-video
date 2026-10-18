import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-1005 · reconnect() only adopts a server it actually reached
//
// reconnect() probes each candidate twice: /version (unauthenticated) and then /sync/status.
// A transport failure on the second probe came back as APIError.connection, which fell into
// the "returned API error but is reachable — using" branch: the candidate was adopted, the
// offline banner cleared and reconnect reported success for a server that never answered.

@Suite("reconnect adopts only a reached server (TASK-1005)", .serialized)
@MainActor
struct ReconnectAdoptionTests {
  private let version = #"{"serverVersion":"1.0.0","minClientVersion":"1.0.0","capabilities":[]}"#

  /// Points the state at the stub as a direct address with nothing else in the cascade.
  private func directOnly(_ state: AppState) {
    state.lanAddress = ""
    state.wanAddress = ""
    state.lastGoodAddress = ""
  }

  /// Red if: a /sync/status that never reached the server still adopts the candidate.
  @Test func statusProbeThatNeverReachedTheServerIsNotAdopted() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset([
        "GET /api/v1/version": .json(200, version),
        "GET /api/v1/sync/status": .unreachable,
      ])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        let saved = SavedAddresses(state)
        directOnly(state)
        state.serverUnreachable = true

        let ok = await state.reconnect()

        #expect(ProfileStubServer.count("GET /api/v1/sync/status") == 1, "precondition: the second probe ran")
        #expect(!ok, "the server never answered /sync/status")
        #expect(state.serverUnreachable, "the offline banner stays up")
        #expect(state.lastGoodAddress.isEmpty, "an unreached address is not remembered as good")
        state.sessionToken = nil
        saved.restore(state)
      }
    }
  }

  /// The server answering /sync/status with its own non-auth error IS reached; keep adopting.
  /// Red if: the fix over-corrects and refuses every API error.
  @Test func statusProbeTheServerAnsweredIsAdopted() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset([
        "GET /api/v1/version": .json(200, version),
        "GET /api/v1/sync/status": .json(500, #"{"error":"internal"}"#),
      ])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        let saved = SavedAddresses(state)
        directOnly(state)
        state.serverUnreachable = true

        let ok = await state.reconnect()

        #expect(ok, "the server answered, so it is reachable")
        #expect(!state.serverUnreachable)
        state.sessionToken = nil
        saved.restore(state)
      }
    }
  }
}
