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

// MARK: - TASK-993 · Siri "Find X" reaches the iPhone/iPad search (FRD-001 FR-147)

@Suite("TASK-993 · Siri search on iOS", .serialized)
@MainActor
struct SiriSearchHandoffTests {

  /// "Find M": the intent leaves a request, the shell takes it once (trimmed, one character
  /// allowed), and the search it starts is explicit so the server is asked.
  /// Red if the request is not consumable or is searched live (a one-character term sends nothing).
  @Test func aSpokenTermIsTakenOnceAndSearchedExplicitly() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/search": .json(200, srHit)])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        AppStateHolder.register(state)
        MediaIntentRouter.openSearch(term: "  M ")

        let term = state.takePendingSearchTerm()
        #expect(term == "M")
        #expect(state.pendingSearchTerm == nil, "a request is acted on once")
        #expect(state.takePendingSearchTerm() == nil)

        let outcome = await SearchRules.fetch(term ?? "", explicit: true, api: state.api)
        guard case .success(let items)? = outcome else {
          Issue.record("expected the search to run, got \(String(describing: outcome))")
          return
        }
        #expect(items.map(\.title) == ["M"])
        #expect(ProfileStubServer.count("GET /api/v1/search") == 1)
      }
    }
  }

  @Test func aBlankRequestIsClearedAndOpensNothing() async {
    await withIsolatedAppState { state in
      state.pendingSearchTerm = "   "
      #expect(state.takePendingSearchTerm() == nil)
      #expect(state.pendingSearchTerm == nil)
      #expect(SearchRules.siriTerm(nil) == nil)
    }
  }

  /// The defect was an absent reader: only TVMainView consumed `pendingSearchTerm`. A view cannot be
  /// rendered here, so this reads the iOS shell's source and fails if the reader is removed, or if the
  /// search screen stops accepting the term.
  @Test func theIOSShellReadsTheRequest() throws {
    let views = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("DSM Video/DSM Video/Views", isDirectory: true)
    let main = try String(contentsOf: views.appendingPathComponent("MainView.swift"), encoding: .utf8)
    #expect(main.contains("appState.pendingSearchTerm"), "the iOS shell must observe the request")
    #expect(main.contains("takePendingSearchTerm()"))
    #expect(main.contains("SearchView(isEmbedded: true, initialTerm: target.term)"))
    #expect(main.contains("var initialTerm: String?"))
  }
}
