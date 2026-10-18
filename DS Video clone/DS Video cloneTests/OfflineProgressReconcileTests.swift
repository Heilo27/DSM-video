import Foundation
import Testing
@testable import DSM_Video

// MARK: - Progress recorded with the NAS down reaches the server on reconnect (TASK-967 · OC-1012, OC-1028, OC-1135)
//
// The user watches to 700 seconds with the NAS unreachable. Nothing may be lost: the position
// stays readable on the device, it stays owed to the server while the NAS is down, and when the
// NAS is back the flush delivers exactly that position under the ACTIVE profile and clears the
// debt. Every request goes through the real APIClient to ProfileStubServer; expected values are
// literals. Watchlist changes made offline are covered by WatchlistOfflineNoticeTests (rolled
// back with a notice at the time); mark-watched rides this same outbox as a progress row.

@Suite("OC-1012 / OC-1028 / OC-1135 · offline progress reconciles", .serialized)
@MainActor
struct OfflineProgressReconcileTests {

  private let maya = Profile(id: "pf_rec_maya", name: "Maya", avatar: "cat", maxAgeLevel: 4,
                             hasPin: false, isOwner: true)
  private let accepted = ProfileStubServer.Reply.json(200, #"{"ok":true,"applied":true}"#)

  private func online(routes: [String: ProfileStubServer.Reply],
                      _ body: @escaping (AppState) async -> Void) async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(routes)
      await withIsolatedAppState(cached: [maya], active: maya, stubHost: ProfileStubServer.host) { state in
        state.isOffline = false
        state.serverUnreachable = false
        state.profileSupport = .supported
        await body(state)
      }
    }
  }

  /// OC-1028 · given the user watched T to 700s while the NAS was unreachable, when the app
  /// tries to upload and the NAS is still down, then the 700s is still on the device and still
  /// owed to the server (exactly one try, no loss, no silent discard).
  /// Red if: a failed upload clears the outbox row or the local position.
  @Test func aFailedUploadLosesNothingAndKeepsTheDebt() async {
    await online(routes: ["POST /api/v1/items/mv-dune/progress": .unreachable]) { state in
      await state.localStore.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 700, durationSeconds: 7200)
      #expect(await state.localStore.pendingProgressCount() == 1, "precondition: the write is owed")

      await state.flushPendingProgress()

      #expect(ProfileStubServer.count("POST /api/v1/items/mv-dune/progress") == 1)
      #expect(await state.localStore.getProgressSeconds(itemId: "mv-dune") == 700)
      #expect(await state.localStore.pendingProgressCount() == 1, "still owed to the server")
    }
  }

  /// OC-1028 / OC-1135 · given the same 700s and the NAS back, when the flush runs, then the
  /// server receives T at 700s of 7200s under the ACTIVE profile, the debt clears, and the
  /// local position is still 700.
  /// Red if: the upload is attributed to no profile or another one, sends a different
  /// position, or never runs after reconnect.
  @Test func reconnectDeliversTheSavedPositionUnderTheActiveProfile() async {
    await online(routes: ["POST /api/v1/items/mv-dune/progress": accepted]) { state in
      await state.localStore.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 700, durationSeconds: 7200)

      await state.flushPendingProgress()

      let sent = ProfileStubServer.requests.filter { $0.path == "/api/v1/items/mv-dune/progress" }
      #expect(sent.count == 1)
      #expect(sent.first?.profileHeader == "pf_rec_maya")
      #expect(sent.first?.body.contains("\"positionSeconds\":700") == true, "body: \(sent.first?.body ?? "")")
      #expect(sent.first?.body.contains("\"durationSeconds\":7200") == true)
      #expect(await state.localStore.pendingProgressCount() == 0, "debt cleared")
      #expect(await state.localStore.getProgressSeconds(itemId: "mv-dune") == 700)
    }
  }

  /// OC-1012 boundary · given two titles watched offline and the server refusing the first for
  /// good (the title was deleted: 404), when the flush runs, then the dead row is dropped, the
  /// second title still reaches the server at its position, and nothing stays owed.
  /// Red if: one permanently-rejected row blocks the queue behind it, or both are dropped.
  @Test func aDeletedTitleDoesNotBlockTheWatchedOneBehindIt() async {
    await online(routes: [
      "POST /api/v1/items/mv-deleted/progress": .json(404, #"{"error":"not_found"}"#),
      "POST /api/v1/items/mv-dune/progress": accepted,
    ]) { state in
      await state.localStore.upsertSingleProgress(itemId: "mv-deleted", positionSeconds: 90, durationSeconds: 5400)
      // The outbox stamps whole seconds and drains oldest first; wait one so the dead row is
      // strictly the oldest and is always the first one sent.
      try? await Task.sleep(for: .milliseconds(1100))
      await state.localStore.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 700, durationSeconds: 7200)
      #expect(await state.localStore.pendingProgressCount() == 2, "precondition: both owed")

      await state.flushPendingProgress()

      #expect(ProfileStubServer.count("POST /api/v1/items/mv-deleted/progress") == 1)
      #expect(ProfileStubServer.count("POST /api/v1/items/mv-dune/progress") == 1)
      #expect(await state.localStore.pendingProgressCount() == 0)
    }
  }

  /// OC-1135 boundary · given nothing was watched offline, when the flush runs, then no
  /// request is made at all.
  /// Red if: the flush posts rows that do not exist.
  @Test func anEmptyOutboxSendsNothing() async {
    await online(routes: ["POST /api/v1/items/mv-dune/progress": accepted]) { state in
      await state.flushPendingProgress()
      #expect(ProfileStubServer.requests.isEmpty)
    }
  }
}
