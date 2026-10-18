import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-977 · a one-character search runs when asked for (FRD-001 FR-089, FR-100)

private let srHit = #"{"total":1,"items":[{"id":"m1","type":"movie","title":"M","year":1931,"durationSeconds":7000,"addedAt":"2026-01-01T00:00:00Z","libraryId":"lib_sr","changeSeq":1}]}"#

@Suite("TASK-977 · short search queries", .serialized)
@MainActor
struct SearchRulesTests {

  @MainActor
  private func onStub(_ body: (AppState) async -> Void) async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/search": .json(200, srHit)])
      await withIsolatedAppState(stubHost: ProfileStubServer.host, body)
    }
  }

  /// An explicit submit of "M" reaches the server and returns its result.
  /// Red if the one-character guard returns before the request (nil result, zero requests).
  @Test func anExplicitOneCharacterQueryIsSent() async {
    await onStub { state in
      let outcome = await SearchRules.fetch("M", explicit: true, api: state.api)
      guard case .success(let items)? = outcome else {
        Issue.record("expected a result, got \(String(describing: outcome))")
        return
      }
      #expect(items.map(\.title) == ["M"])
      #expect(ProfileStubServer.count("GET /api/v1/search") == 1)
    }
  }

  /// Live (as-you-type) search keeps its two-character floor: no request per keystroke.
  /// Red if the floor is removed from the live path.
  @Test func aLiveOneCharacterQuerySendsNothing() async {
    await onStub { state in
      let outcome = await SearchRules.fetch("M", explicit: false, api: state.api)
      #expect(outcome == nil)
      #expect(ProfileStubServer.count("GET /api/v1/search") == 0)

      let two = await SearchRules.fetch("Mo", explicit: false, api: state.api)
      #expect(two != nil)
      #expect(ProfileStubServer.count("GET /api/v1/search") == 1)
    }
  }

  @Test func blankQueriesNeverSearch() {
    #expect(SearchRules.queryToSend("", explicit: true) == nil)
    #expect(SearchRules.queryToSend("   ", explicit: true) == nil)
    #expect(SearchRules.queryToSend("  M  ", explicit: true) == "M")
  }

  /// The hint shows for a lone character and nothing else, so the screen is never blank.
  /// Red if the hint predicate is dropped or widened to empty or longer text.
  @Test func theHintShowsOnlyForOneCharacter() {
    #expect(SearchRules.needsExplicitSubmit("M"))
    #expect(SearchRules.needsExplicitSubmit(" 1 "))
    #expect(!SearchRules.needsExplicitSubmit(""))
    #expect(!SearchRules.needsExplicitSubmit("  "))
    #expect(!SearchRules.needsExplicitSubmit("Up"))
    #expect(SearchRules.shortQueryHint(for: " M ").contains("\"M\""))
  }

  @Test func aServerFailureIsReportedNotSwallowed() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/search": .unreachable])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        let outcome = await SearchRules.fetch("M", explicit: true, api: state.api)
        guard case .failure? = outcome else {
          Issue.record("expected a failure, got \(String(describing: outcome))")
          return
        }
      }
    }
  }
}
