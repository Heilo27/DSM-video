import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-925 · an AppState that shares nothing with the app
//
// AppState takes its ActiveProfileStore and LocalStore by injection (production passes
// `.shared` for both). Profile tests build theirs here: a profile store on a throwaway
// UserDefaults suite and a catalog on a temp SQLite file, both deleted afterwards. Nothing
// reads or writes the app-group defaults (group.HeiloProjects.DSReel) or <Documents>/dsreel.db,
// so a profile test cannot race another suite over them and there is nothing to save and restore.

/// Runs `body` with a signed-in-looking AppState over its own stores.
///
/// - `cached` / `active`: the profile list and chosen profile the store starts with. The
///   catalog's scope is seeded from the store, as `LocalStore.shared` is at launch.
/// - `stubHost`: when set, the state is pointed at that host over plain HTTP with a stub
///   token and Remember Me off (never write the stub token to the Keychain); the address
///   settings AppState keeps in UserDefaults.standard are put back afterwards.
@MainActor
func withIsolatedAppState(
  cached: [Profile] = [], active: Profile? = nil, stubHost: String? = nil,
  _ body: (AppState) async -> Void
) async {
  let suite = "IsolatedAppState.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suite) else {
    Issue.record("could not create the throwaway UserDefaults suite \(suite)")
    return
  }
  defaults.removePersistentDomain(forName: suite)
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-isolated-\(UUID().uuidString)", isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  } catch {
    Issue.record("could not create the temp catalog directory: \(error)")
    return
  }
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: dir)
  }

  let profileStore = ActiveProfileStore(defaults: defaults)
  profileStore.setCachedProfiles(cached)
  profileStore.setActive(active)
  let localStore = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
  await localStore.setActiveProfile(profileStore.activeScope)

  let state = AppState(profileStore: profileStore, localStore: localStore,
                       serverUpdateDefaults: defaults)
  let savedBase = state.baseURL, savedHTTPS = state.useHTTPS, savedRemember = state.rememberMe
  if let stubHost {
    state.rememberMe = false
    state.useHTTPS = false
    state.baseURL = stubHost
    state.sessionToken = "stub-token"
  }
  await body(state)
  if stubHost != nil {
    state.baseURL = savedBase
    state.useHTTPS = savedHTTPS
    state.rememberMe = savedRemember
  }
}

/// TASK-925 AC-1/AC-2. An AppState built on injected stores reads and writes ONLY those; the
/// app-group store is left as it was, and every client it builds names the profile from the
/// injected store.
@MainActor
struct AppStateInjectionTests {
  private let maya = Profile(id: "pf_inj_maya", name: "Maya", avatar: "cat", maxAgeLevel: 2,
                             hasPin: false, isOwner: false)
  private let ryan = Profile(id: "pf_inj_ryan", name: "Ryan", avatar: "moon", maxAgeLevel: 4,
                             hasPin: false, isOwner: true)

  /// Red if: AppState reads `.shared` for the profile list or active profile (the injected
  /// store's values would not appear), writes the switch to `.shared` (it would change), or
  /// builds a client on `.shared` (identity check fails, so the header would name the wrong id).
  @Test func switchingProfilesTouchesOnlyTheInjectedStores() async {
    let sharedBefore = ActiveProfileStore.shared.activeProfileID
    await withIsolatedAppState(cached: [ryan, maya], active: ryan) { state in
      #expect(state.profiles.map(\.id) == ["pf_inj_ryan", "pf_inj_maya"])
      #expect(state.activeProfile?.id == "pf_inj_ryan")
      #expect(state.api.profileStore === state.profileStore, "the client reads the injected store")

      await state.switchProfile(to: maya)

      #expect(state.profileStore.activeProfileID == "pf_inj_maya")
      #expect(state.activeProfile?.id == "pf_inj_maya")
      #expect(await state.localStore.activeScope.id == "pf_inj_maya")
      #expect(state.api.profileStore === state.profileStore, "still the injected store after a switch")
    }
    #expect(ActiveProfileStore.shared.activeProfileID == sharedBefore,
            "the app-group store was never written")
  }
}
