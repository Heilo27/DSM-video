import Testing
import Foundation
@testable import DSM_Video

// TASK-989 repro (FR-137): offline, toggling the watchlist flipped the UI, the server call
// failed, and the rollback silently put it back. The user saw the toggle undo itself with no
// reason given. The change must be reported at the time, naming the real cause.
//
// Driven through the real APIClient against ProfileStubServer, which fails the watchlist write
// the way the device would: URLError.cannotConnectToHost (NAS down) or .notConnectedToInternet.

private let maya = Profile(id: "pf_wl_maya", name: "Maya", avatar: "cat", maxAgeLevel: 2,
                           hasPin: false, isOwner: false)

private func wlItem(_ id: String) -> ItemSummary {
  ItemSummary(id: id, type: "movie", title: "Title \(id)", year: 2020, durationSeconds: 7200,
              addedAt: "2026-01-01T00:00:00Z", libraryId: "lib_wl", changeSeq: 1,
              contentRating: nil, ageLevel: nil)
}

@Suite("Watchlist change that fails offline (TASK-989)", .serialized)
@MainActor
struct WatchlistOfflineNoticeTests {

  @Test("A failed add rolls back and says the NAS can't be reached")
  func failedAddNamesUnreachableNAS() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["POST /api/v1/watchlist/wl_new": .unreachable])
      await withIsolatedAppState(cached: [maya], active: maya,
                                 stubHost: ProfileStubServer.host) { state in
        state.watchlistItems = [wlItem("wl_a"), wlItem("wl_b")]

        await state.toggleWatchlist(item: wlItem("wl_new"))

        #expect(ProfileStubServer.count("POST /api/v1/watchlist/wl_new") >= 1, "the write really ran and failed")
        #expect(state.watchlistItems.map(\.id) == ["wl_a", "wl_b"], "the optimistic add was rolled back")
        #expect(state.watchlistNotice == "Couldn't update your watchlist. Can't reach your NAS.")
      }
    }
  }

  @Test("A failed remove offline goes back to its old place and says there is no internet")
  func failedRemoveOfflineKeepsPositionAndNamesOffline() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["DELETE /api/v1/watchlist/wl_b": .offline])
      await withIsolatedAppState(cached: [maya], active: maya,
                                 stubHost: ProfileStubServer.host) { state in
        state.watchlistItems = [wlItem("wl_a"), wlItem("wl_b"), wlItem("wl_c")]

        await state.toggleWatchlist(item: wlItem("wl_b"))

        #expect(ProfileStubServer.count("DELETE /api/v1/watchlist/wl_b") >= 1, "the write really ran and failed")
        #expect(state.watchlistItems.map(\.id) == ["wl_a", "wl_b", "wl_c"], "restored at its original index")
        #expect(state.watchlistNotice == "Couldn't update your watchlist. No internet connection.")
      }
    }
  }
}
