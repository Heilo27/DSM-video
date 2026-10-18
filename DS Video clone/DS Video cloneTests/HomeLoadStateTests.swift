import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-696 · the home load is one state, and every exit leaves it somewhere sane
//
// AppState used to keep three Bools (loading, cache-decoding, background-refreshing) that
// formed an implicit state machine. A path that missed its reset latched `homeLoad`'s busy
// guard and the rails stayed empty for the session. These tests pin the observable behaviour
// of the replacement (`HomeLoadState`): what each path leaves behind when it ends, that a
// finished or cancelled path never turns the next `homeLoad` away, and that a stale owner
// finishing cannot knock a newer owner back to idle.

// MARK: Helpers

/// A server that answers nothing until the test says so, so a test can look at AppState while
/// a request is in flight. Once `releaseAll()` runs, every request (held or later) fails with
/// "cannot connect", which ends the sync it belongs to.
nonisolated final class HomeLoadGateStub: URLProtocol, @unchecked Sendable {
  static let host = "homeload-gate.stub.test"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var held: [HomeLoadGateStub] = []
  nonisolated(unsafe) private static var arrived = 0
  nonisolated(unsafe) private static var open = false
  static let registered: Bool = {
    URLProtocol.registerClass(HomeLoadGateStub.self)
    return true
  }()

  static func reset() {
    _ = registered
    lock.lock(); defer { lock.unlock() }
    held = []
    arrived = 0
    open = false
  }
  /// How many requests have reached the server since `reset()`.
  static var arrivedCount: Int {
    lock.lock(); defer { lock.unlock() }
    return arrived
  }
  /// Fails every held request now and every later one on arrival.
  static func releaseAll() {
    lock.lock()
    open = true
    let toFail = held
    held = []
    lock.unlock()
    for protocolInstance in toFail {
      protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: URLError(.cannotConnectToHost))
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.arrived += 1
    let isOpen = Self.open
    if !isOpen { Self.held.append(self) }
    Self.lock.unlock()
    if isOpen {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
  }
  override func stopLoading() {
    Self.lock.lock(); defer { Self.lock.unlock() }
    Self.held.removeAll { $0 === self }
  }
}

/// Records the home load state each time the QuickConnect resolver is asked.
@MainActor
private final class StateProbe {
  var statesSeen: [HomeLoadState] = []
}

/// Polls (on the main actor, 10 ms apart, up to 5 s) until `condition` holds.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<500 where !condition() {
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// A signed-in-looking AppState over its own stores, pointed at `host`, with the stub
/// servers reset. Runs inside ProfileStateGate: the stubs' route tables are process-wide.
@MainActor
private func homeLoadAccount(
  host: String = ProfileStubServer.host,
  routes: [String: ProfileStubServer.Reply] = [:],
  _ body: (AppState) async -> Void
) async {
  await ProfileStateGate.shared.run {
    ProfileStubServer.reset(routes)
    HomeLoadGateStub.reset()
    await withIsolatedAppState(stubHost: host, body)
  }
}

private func cachedMovie() -> ItemSummary {
  ItemSummary(id: "heat", type: "movie", title: "Heat", addedAt: "2026-01-01T00:00:00Z",
              libraryId: "lib_696", changeSeq: 1, ageLevel: 1)
}

private let noContentMessage = "No content found. If your library has videos, try signing out and back in."

// MARK: - The state itself

@Suite("TASK-696 · HomeLoadState", .serialized)
@MainActor
struct HomeLoadStateTests {

  // MARK: after(leaving:)

  /// Only the owner of the current state may clear it.
  /// Red if: a path finishing can reset a state that something else took over.
  @Test func leavingYourOwnStateGoesIdleAndLeavingSomeoneElsesChangesNothing() {
    let all: [HomeLoadState] = [.idle, .loading, .cacheDecoding, .backgroundRefreshing]
    for current in all {
      for owner in all {
        let expected: HomeLoadState = current == owner ? .idle : current
        #expect(current.after(leaving: owner) == expected,
                "\(current) after \(owner) finishes should be \(expected)")
      }
    }
  }

  @Test func aFreshStateIsIdleAndShowsNoFlags() async {
    await withIsolatedAppState { state in
      #expect(state.homeLoadState == .idle)
      #expect(!state.homeIsLoading && !state.homeIsCacheDecoding && !state.homeIsBackgroundRefreshing)
      #expect(state.homeError == nil)
    }
  }

  // MARK: Path 1 · demo

  /// Demo mode fills the rails from bundled data and holds no state.
  /// Red if: the demo path leaves a flag set, or stops filling the libraries.
  @Test func demoLoadFillsTheRailsAndLeavesTheStateIdle() async {
    await homeLoadAccount { state in
      let saved = SavedAddresses(state)
      state.sessionToken = "demo"
      #expect(state.isDemoMode, "precondition")
      #expect(!state.needsProfilePicker, "precondition: homeLoad is not held by the picker")

      await state.homeLoad()

      #expect(state.homeLoadState == .idle)
      #expect(state.homeLibraries.map(\.id) == DemoData.libraries.map(\.id))
      state.sessionToken = nil
      saved.restore(state)
    }
  }

  // MARK: Path 2 · rails already in memory

  /// With rails on screen homeLoad only runs the heartbeat and clears a stale error.
  /// Red if: the in-memory path takes a state and leaves it, or leaves the stale banner.
  @Test func inMemoryLoadClearsTheStaleErrorAndLeavesTheStateIdle() async {
    await homeLoadAccount { state in
      await state.localStore.upsertItems([cachedMovie()])
      let rails = await state.localStore.queryRails()
      #expect(state.applyRails(rails, startedAt: state.homeStateGeneration))
      #expect(!state.homeAllRailsEmpty, "precondition: rails in memory")
      state.homeError = "stale"

      await state.homeLoad()

      #expect(state.homeLoadState == .idle)
      #expect(state.homeError == nil)
    }
  }

  // MARK: Path 3 · cold start with a cached catalog

  /// TASK-696's key case. The cache decode finishes, the device is offline, and the path
  /// returns at the offline guard: the state must be idle, not still "cache decoding", or the
  /// next homeLoad is turned away as busy for the rest of the session.
  /// Red if: the offline guard after a cache decode leaves the state at .cacheDecoding, or any
  /// later homeLoad bails at the busy guard.
  @Test func offlineGuardAfterACacheDecodeLeavesTheStateIdle() async {
    await homeLoadAccount { state in
      await state.localStore.upsertItems([cachedMovie()])
      await letNetworkMonitorSettle()
      state.isOffline = true

      await state.homeLoad()

      #expect(state.homeLoadState == .idle)
      #expect(!state.homeIsCacheDecoding)
      #expect(!state.homeAllRailsEmpty, "the cached rails are on screen")
      #expect(ProfileStubServer.count("GET /api/v1/sync/status") == 0, "offline: no network sync")

      // Not turned away as busy: the second call reaches the in-memory path, which clears this.
      state.homeError = "marker"
      await state.homeLoad()
      #expect(state.homeError == nil, "the second homeLoad got past the busy guard")
      #expect(state.homeLoadState == .idle)
    }
  }

  /// The decode is over before QuickConnect resolves, and a failed resolution still ends idle.
  /// Red if: .cacheDecoding is held across the resolver (a re-entering homeLoad would be
  /// turned away for as long as the lookup takes), or the failure path leaves a state set.
  @Test func quickConnectFailureAfterACacheDecodeLeavesTheStateIdle() async {
    await ProfileStateGate.shared.run {
      await withIsolatedAppState { state in
        let saved = SavedAddresses(state)
        state.rememberMe = false  // never write the test token to the Keychain
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.baseURL = ""
        state.baseURL = "oc696-unknown-nas"
        state.sessionToken = "oc696-token"
        await state.localStore.upsertItems([cachedMovie()])
        let probe = StateProbe()
        state.quickConnectResolve = { _ in
          probe.statesSeen.append(state.homeLoadState)
          throw URLError(.cannotFindHost)
        }
        state.reconnectRetryPolicy = .init(
          fastDelays: Array(repeating: .milliseconds(10), count: 2),
          slowInterval: .milliseconds(20))
        #expect(state.api.baseURL == AppState.fallbackURL, "precondition: the QC id is unresolved")
        #expect(!state.needsProfilePicker, "precondition: homeLoad is not held by the picker")

        await state.homeLoad()

        #expect(state.homeLoadState == .idle)
        #expect(probe.statesSeen.first == .idle, "the lookup ran after the decode was over")
        #expect(!state.homeAllRailsEmpty, "the cached rails stay on screen")

        state.reconnectRetryTask?.cancel()
        state.sessionToken = nil
        saved.restore(state)
      }
    }
  }

  // MARK: Path 4 · cold start with nothing cached

  /// Offline with nothing on disk: a message, no spinner, and not stuck.
  /// Red if: the offline guard in the no-cache path leaves a state set, picks the wrong
  /// message for the cause, or the second attempt is turned away.
  @Test func offlineWithNoCacheSetsTheMessageForTheCauseAndLeavesTheStateIdle() async {
    await homeLoadAccount { state in
      await letNetworkMonitorSettle()
      state.isOffline = true
      await state.homeLoad()
      #expect(state.homeError == "No internet connection.")
      #expect(state.homeLoadState == .idle)

      state.isOffline = false
      state.serverUnreachable = true
      state.homeError = "marker"
      await state.homeLoad()
      #expect(state.homeError == "Can't reach your server.", "the retry was not turned away")
      #expect(state.homeLoadState == .idle)
      #expect(ProfileStubServer.count("GET /api/v1/sync/status") == 0, "unavailable: no network sync")
    }
  }

  /// An unresolvable QuickConnect id with nothing cached: the message, and idle.
  /// Red if: the resolver runs with the decode state still held, or the failure leaves a state.
  @Test func quickConnectFailureWithNoCacheSetsTheMessageAndLeavesTheStateIdle() async {
    await ProfileStateGate.shared.run {
      await withIsolatedAppState { state in
        let saved = SavedAddresses(state)
        state.rememberMe = false
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.baseURL = ""
        state.baseURL = "oc696-unknown-nas"
        state.sessionToken = "oc696-token"
        let probe = StateProbe()
        state.quickConnectResolve = { _ in
          probe.statesSeen.append(state.homeLoadState)
          throw URLError(.cannotFindHost)
        }
        state.reconnectRetryPolicy = .init(
          fastDelays: Array(repeating: .milliseconds(10), count: 2),
          slowInterval: .milliseconds(20))
        #expect(state.api.baseURL == AppState.fallbackURL, "precondition: the QC id is unresolved")
        #expect(!state.needsProfilePicker, "precondition: homeLoad is not held by the picker")

        await state.homeLoad()

        #expect(state.homeError == "Can't reach your server. Check that DSVideoServer is running.")
        #expect(state.homeLoadState == .idle)
        #expect(probe.statesSeen.first == .idle, "the lookup ran after the decode was over")

        state.reconnectRetryTask?.cancel()
        state.sessionToken = nil
        saved.restore(state)
      }
    }
  }

  /// A sync that cannot reach the server ends with a message and an idle state.
  /// Red if: the foreground sync's failure leaves .loading set.
  @Test func foregroundSyncFailureWithNoCacheLeavesTheStateIdleWithAMessage() async {
    await homeLoadAccount(routes: ["GET /api/v1/sync/status": .unreachable]) { state in
      await state.homeLoad()

      #expect(state.homeLoadState == .idle)
      #expect(!state.homeIsLoading)
      #expect(state.homeError != nil, "the user is told the load failed")
      #expect(ProfileStubServer.count("GET /api/v1/sync/status") >= 1, "the sync really ran")
    }
  }

  /// While the foreground sync is in flight the state is .loading, a second homeLoad is turned
  /// away without disturbing it, and when the sync ends the state is idle.
  /// Red if: the sync does not hold .loading, the busy guard lets a second load through, or the
  /// end of the sync leaves the state set.
  @Test func foregroundSyncHoldsLoadingAndReleasesItWhenItEnds() async {
    await homeLoadAccount(host: HomeLoadGateStub.host) { state in
      let load = Task { await state.homeLoad() }
      #expect(await waitUntil { state.homeLoadState == .loading }, "the foreground sync took .loading")
      #expect(state.homeIsLoading && !state.homeIsCacheDecoding && !state.homeIsBackgroundRefreshing)

      state.homeError = "marker"
      await state.homeLoad()
      #expect(state.homeError == "marker", "a second homeLoad was turned away")
      #expect(state.homeLoadState == .loading, "and did not disturb the one in flight")

      HomeLoadGateStub.releaseAll()
      await load.value
      #expect(state.homeLoadState == .idle)
      #expect(state.homeError != nil)
    }
  }

  /// The tvOS pairing case: the load is cancelled mid-sync (the token changed), and the next
  /// homeLoad must run rather than find a latched state.
  /// Red if: cancellation leaves .loading set (the original latch), so the retry bails.
  @Test func cancellingAForegroundSyncDoesNotLatchTheState() async {
    await homeLoadAccount(host: HomeLoadGateStub.host) { state in
      let load = Task { await state.homeLoad() }
      #expect(await waitUntil { state.homeLoadState == .loading })

      load.cancel()
      await load.value
      #expect(state.homeLoadState == .idle, "the cancelled load released its state")

      HomeLoadGateStub.releaseAll()  // later requests fail fast instead of hanging
      state.homeError = "marker"
      let before = HomeLoadGateStub.arrivedCount
      await state.homeLoad()
      #expect(state.homeError != "marker", "the next homeLoad ran")
      #expect(HomeLoadGateStub.arrivedCount > before, "and reached the server")
      #expect(state.homeLoadState == .idle)
    }
  }

  // MARK: Background refresh, foreground refresh, force refresh

  /// A background sync ends idle even when it fails.
  /// Red if: the background sync's failure leaves .backgroundRefreshing set.
  @Test func foregroundRefreshFailureLeavesTheStateIdle() async {
    await homeLoadAccount(routes: ["GET /api/v1/sync/status": .unreachable]) { state in
      await state.foregroundRefresh()

      #expect(ProfileStubServer.count("GET /api/v1/sync/status") >= 1, "the sync really ran")
      #expect(state.homeLoadState == .idle)
      #expect(!state.homeIsBackgroundRefreshing)
    }
  }

  /// While a background sync runs the state is .backgroundRefreshing; homeLoad and a second
  /// foregroundRefresh are turned away; the end of the sync releases it.
  /// Red if: the background sync does not hold the state, a second load or refresh starts
  /// another sync on top of it, or the end of the sync leaves the state set.
  @Test func backgroundSyncHoldsItsStateAndTurnsAwayOtherLoads() async {
    await homeLoadAccount(host: HomeLoadGateStub.host) { state in
      let refresh = Task { await state.foregroundRefresh() }
      #expect(await waitUntil { state.homeLoadState == .backgroundRefreshing })
      #expect(state.homeIsBackgroundRefreshing && !state.homeIsLoading && !state.homeIsCacheDecoding)
      #expect(await waitUntil { HomeLoadGateStub.arrivedCount >= 1 })
      let arrived = HomeLoadGateStub.arrivedCount

      state.homeError = "marker"
      await state.homeLoad()
      #expect(state.homeError == "marker", "homeLoad was turned away")
      await state.foregroundRefresh()
      #expect(HomeLoadGateStub.arrivedCount == arrived, "a second foregroundRefresh did not start a sync")
      #expect(state.homeLoadState == .backgroundRefreshing)

      HomeLoadGateStub.releaseAll()
      await refresh.value
      #expect(state.homeLoadState == .idle)
    }
  }

  /// A force refresh takes over from a running background sync. The background sync finishing
  /// afterwards (here: cancelled) must not knock the force refresh's spinner back to idle.
  /// Red if: a stale background sync's release clears a state it no longer owns.
  @Test func aStaleBackgroundSyncEndingDoesNotClearTheForceRefreshThatReplacedIt() async {
    await homeLoadAccount(host: HomeLoadGateStub.host) { state in
      let background = Task { await state.foregroundRefresh() }
      #expect(await waitUntil { state.homeLoadState == .backgroundRefreshing })

      let force = Task { await state.homeForceRefresh() }
      #expect(await waitUntil { state.homeLoadState == .loading }, "the force refresh took over")

      background.cancel()
      await background.value
      #expect(state.homeLoadState == .loading, "the stale owner leaving did not clear the new one")
      #expect(state.homeIsLoading)

      HomeLoadGateStub.releaseAll()
      await force.value
      #expect(state.homeLoadState == .idle)
    }
  }

  /// A force refresh that cannot reach the server ends idle, and the version bump that tells
  /// the TV rails to re-fetch still happens.
  /// Red if: the force refresh's failure leaves .loading set.
  @Test func forceRefreshFailureLeavesTheStateIdle() async {
    await homeLoadAccount(routes: ["GET /api/v1/sync/status": .unreachable]) { state in
      let versionBefore = state.libraryRailsVersion

      await state.homeForceRefresh()

      #expect(ProfileStubServer.count("GET /api/v1/sync/status") >= 1, "the sync really ran")
      #expect(state.homeLoadState == .idle)
      #expect(state.libraryRailsVersion != versionBefore)
    }
  }

  // MARK: Heartbeat (TASK-1062)

  /// A heartbeat that fires while the home load is decoding the local catalog does nothing: it
  /// does not even ask the server, so it cannot start a sync mid-decode. The next beat (30 s on)
  /// re-reads both cursors, so skipping loses no change. The control half shows the same state
  /// object beats normally once the decode is over, so the skip is the decode's doing.
  /// Red if: runHeartbeat stops checking .cacheDecoding (the beat reaches the server while the
  /// decode is running), or the guard also swallows beats in the idle state.
  @Test func heartbeatSkipsWhileTheCacheIsDecodingAndRunsOnceItIsOver() async {
    let beat = "GET /api/v1/sync/heartbeat"
    await homeLoadAccount(routes: [
      beat: .json(200, #"{"itemSeq":0,"progressSeq":0,"serverTimeMs":0}"#)
    ]) { state in
      state.setHomeLoadStateForTesting(.cacheDecoding)

      await state.runHeartbeat()

      #expect(ProfileStubServer.count(beat) == 0, "no heartbeat request while the decode runs")
      #expect(state.homeLoadState == .cacheDecoding, "and the skip left the decode's state alone")

      state.setHomeLoadStateForTesting(.idle)
      await state.runHeartbeat()

      #expect(ProfileStubServer.count(beat) == 1, "control: idle again, the beat reaches the server")
    }
  }

  // MARK: clearHomeState

  /// Signing out or switching profile clears the home state back to idle with no error.
  /// Red if: clearHomeState leaves a state set or a stale error.
  @Test func clearHomeStateReturnsToIdleWithNoError() async {
    await homeLoadAccount(host: HomeLoadGateStub.host) { state in
      let load = Task { await state.homeLoad() }
      #expect(await waitUntil { state.homeLoadState == .loading })
      state.homeError = "stale"

      state.clearHomeState()
      #expect(state.homeLoadState == .idle)
      #expect(state.homeError == nil)

      HomeLoadGateStub.releaseAll()
      await load.value
    }
  }
}
