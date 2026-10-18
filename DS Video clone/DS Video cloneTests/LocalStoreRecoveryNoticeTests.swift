import Testing
import Foundation
@testable import DSM_Video

// TASK-1034 (FR-005, FR-015): LocalStore.recoveryNotice was built for the case where a corrupt
// database is quarantined and replaced with an empty one, but nothing ever read it. The user
// saw an empty library with no explanation. These tests pin that the notice exists only after
// a real recovery, that the launch check carries it to AppState, and that both signed-in roots
// show it.

@Suite("Local store recovery notice (TASK-1034)")
@MainActor
struct LocalStoreRecoveryNoticeTests {

  /// A per-test directory holding a database file that is not a database, and its cleanup.
  private func withCorruptDatabase(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("dsreel.db")
    try Data(repeating: 0x5A, count: 8192).write(to: url)
    try await body(url)
  }

  /// Red if: a store rebuilt from a corrupt file does not report it, or reports it as
  /// unavailable (it works, it is just empty).
  @Test func aCorruptDatabaseIsRebuiltAndReported() async throws {
    try await withCorruptDatabase { url in
      let store = await LocalStore.makeForTesting(databaseURL: url)
      let notice = try #require(await store.recoveryNotice)
      #expect(notice.contains("rebuilt"))
      #expect(await store.unavailableReason == nil, "a recovered store works, so it is not 'unavailable'")
    }
  }

  /// Red if: the notice is shown for a store that opened normally.
  @Test func aHealthyStoreHasNoNotice() async {
    await withIsolatedAppState { state in
      await state.checkLocalStoreHealth()
      #expect(state.localStoreRecoveryNotice == nil)
    }
  }

  /// Red if: the launch check does not copy the store's notice to AppState, so the banner has
  /// nothing to show.
  @Test func theLaunchCheckCarriesTheNoticeToAppState() async throws {
    try await withCorruptDatabase { url in
      let suite = "LocalStoreRecoveryNoticeTests.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let store = await LocalStore.makeForTesting(databaseURL: url)
      let state = AppState(profileStore: ActiveProfileStore(defaults: defaults), localStore: store)
      #expect(state.localStoreRecoveryNotice == nil, "nothing is claimed before the check runs")

      await state.checkLocalStoreHealth()

      #expect(state.localStoreRecoveryNotice == (await store.recoveryNotice))
      #expect(state.localStoreRecoveryNotice != nil)
      #expect(state.localStoreUnavailableMessage == nil, "recovered is not the same as unavailable")
    }
  }

  /// Red if: the notice would never go away, which on Apple TV (nothing to tap) is a bar the
  /// user cannot dismiss.
  @Test func theBannerClearsItself() {
    #expect(LocalStoreRecoveryBanner.displaySeconds > TransientNoticeBanner.displaySeconds,
            "two sentences need longer than a one-line confirmation")
    #expect(LocalStoreRecoveryBanner.displaySeconds <= 30)
  }

  /// Red if: either signed-in root stops mounting the banner.
  @Test func bothPlatformsShowTheNotice() throws {
    let appRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("DSM Video")
    func source(_ path: String) throws -> String {
      try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }
    let banner = "LocalStoreRecoveryBanner(message: Bindable(appState).localStoreRecoveryNotice)"
    #expect(try source("DSM Video/Views/MainView.swift").contains(banner), "iPhone and iPad")
    #expect(try source("DSM Video/Views/TVMainView.swift").contains(banner), "Apple TV")
  }
}
