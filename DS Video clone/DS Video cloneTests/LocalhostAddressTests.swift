import Foundation
import Testing
@testable import DSM_Video

// TASK-1015 (FRD-001 FR-110): the address field takes an IP/host or a QuickConnect ID. A bare
// "localhost" has an ID's shape (letters, no dot, no colon), so it was sent to Synology as a
// QuickConnect ID instead of being connected to as the host it is.

@Suite("localhost is a host (TASK-1015)", .serialized)
@MainActor
struct LocalhostAddressTests {
  /// OC: AC-1 · "localhost", in any case, with a scheme, a port or a path, is not an ID.
  /// Red if: a bare "localhost" is classified as a QuickConnect ID again.
  @Test(arguments: ["localhost", "LocalHost", "  localhost  ", "http://localhost",
                    "https://LOCALHOST/", "localhost:5000", "http://localhost:8090/api"])
  func localhostIsNotAQuickConnectID(_ address: String) {
    #expect(QuickConnectResolver.extractBareID(from: address) == nil)
  }

  /// OC: AC-2 · real QuickConnect IDs, bare or as a quickconnect.to domain, still are.
  @Test(arguments: [("ryans-nas", "ryans-nas"), ("MyNAS2", "MyNAS2"), ("nas_01", "nas_01"),
                    ("localnas", "localnas"), ("localhost-nas", "localhost-nas"),
                    ("ryans-nas.quickconnect.to", "ryans-nas"),
                    ("https://ryans-nas.quickconnect.to/", "ryans-nas")])
  func realQuickConnectIDsStillAre(_ address: String, _ id: String) {
    #expect(QuickConnectResolver.extractBareID(from: address) == id)
  }

  /// OC: AC-1 · signing in with "localhost" connects to localhost directly: QuickConnect is never
  /// asked, no ID is kept, and the cascade's only candidate is localhost itself.
  /// Red if: the sign-in address is stored as a QuickConnect ID or resolved through Synology.
  @Test func signingInWithLocalhostConnectsDirectly() async {
    await ProfileStateGate.shared.run {
      await withIsolatedAppState { state in
        let saved = SavedAddresses(state)
        state.useHTTPS = false
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.quickConnectID = ""
        let lookups = QuickConnectLookups()
        state.quickConnectResolve = { id in lookups.ids.append(id); return [] }

        state.useSignInAddress("localhost")
        let set = await state.resolveCandidateSet()

        #expect(state.quickConnectID == "", "no QuickConnect ID is kept")
        #expect(state.configuredQuickConnectID == nil)
        #expect(lookups.ids.isEmpty, "QuickConnect was asked for \(lookups.ids)")
        #expect(set.quickConnectFailure == nil)
        #expect(set.candidates.map { $0.url.host } == ["localhost"])
        saved.restore(state)
      }
    }
  }
}
