import Testing
import Foundation
@testable import DSM_Video

// TASK-1012 (FR-005, FR-015): AppState.localStoreUnavailableMessage was set from
// LocalStore.unavailableReason and documented as a banner, but no view read it. It was also
// set only after the first progress write, so a store that could not open said nothing until
// a position had already been lost. And its text promised a later sync that cannot happen:
// with no store there is no outbox for a failed server write to wait in.

@Suite("Local store banner (TASK-1012)")
@MainActor
struct LocalStoreBannerTests {

  /// Red if: the launch check is missing or reads the wrong thing, so a store that could not
  /// open shows no banner until something is played.
  @Test func aStoreThatCannotOpenIsNamedAtLaunch() async throws {
    let suite = "LocalStoreBannerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = await LocalStore.makeUnopenableForTesting()
    let state = AppState(profileStore: ActiveProfileStore(defaults: defaults), localStore: store)
    #expect(state.localStoreUnavailableMessage == nil, "nothing is claimed before the check runs")

    await state.checkLocalStoreHealth()

    let message = try #require(state.localStoreUnavailableMessage)
    #expect(message == (await store.unavailableReason), "the banner shows the store's own reason")
  }

  /// Red if: the check reports a healthy store as broken.
  @Test func aStoreThatOpensShowsNoBanner() async {
    await withIsolatedAppState { state in
      await state.checkLocalStoreHealth()
      #expect(state.localStoreUnavailableMessage == nil)
    }
  }

  /// Red if: the text promises that positions sync later. With no store, a position the NAS
  /// does not take at once is not kept anywhere (recordProgress has no outbox to queue it in).
  @Test func theReasonNeverPromisesALaterSync() async throws {
    let reason = try #require(await LocalStore.makeUnopenableForTesting().unavailableReason)
    #expect(!reason.localizedCaseInsensitiveContains("will sync"))
    #expect(!reason.localizedCaseInsensitiveContains("when it's reachable"))
    #expect(reason.contains("only while your NAS is reachable"))
  }

  /// Red if: either platform's signed-in root stops showing the banner, or the app stops
  /// running the launch check.
  @Test func bothPlatformsShowTheBannerAndTheAppChecksAtLaunch() throws {
    let appRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("DSM Video")
    func source(_ path: String) throws -> String {
      try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }
    let banner = "LocalStoreBanner(message: appState.localStoreUnavailableMessage)"
    #expect(try source("DSM Video/Views/MainView.swift").contains(banner), "iPhone and iPad")
    #expect(try source("DSM Video/Views/TVMainView.swift").contains(banner), "Apple TV")
    #expect(try source("DS_Video_cloneApp.swift").contains("await state.checkLocalStoreHealth()"))
  }
}
