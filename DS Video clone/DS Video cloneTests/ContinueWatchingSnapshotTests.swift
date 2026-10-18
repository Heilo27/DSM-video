import Foundation
import Testing
@testable import DSM_Video

// FR-154, TASK-743 B1. Written by the implementer at the brief's explicit instruction; a blind
// oracle pass by Worf should still follow. Expected values are literals, not derived from the
// policy under test.

private func movie(_ id: String, level: Int? = 1, year: Int? = 2020, poster: String? = nil,
                   position: Int? = nil, duration: Int = 6000) -> ItemSummary {
  ItemSummary(id: id, type: "movie", title: "Movie \(id)", year: year, addedAt: "2026-01-01T00:00:00Z",
              posterImageId: poster,
              progress: position.map { ItemProgress(positionSeconds: $0, durationSeconds: duration,
                                                     updatedAt: "2026-01-01T00:00:00Z") },
              ageLevel: level)
}

private func entry(_ id: String, thumbnail: Data? = nil) -> ContinueWatchingSnapshot.Entry {
  ContinueWatchingSnapshot.Entry(id: id, title: "T\(id)", subtitle: nil, progress: nil,
                                 posterImageID: nil, thumbnail: thumbnail)
}

private func tempDir(_ label: String) -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private let profileA = Profile(id: "pf_a", name: "A", avatar: "fox", maxAgeLevel: 4, hasPin: false, isOwner: true)
private let profileB = Profile(id: "pf_b", name: "B", avatar: "owl", maxAgeLevel: 1, hasPin: false, isOwner: false)

// MARK: - The policy (pure)

@Suite("Continue Watching snapshot policy")
struct ContinueWatchingSnapshotPolicyTests {

  @Test func aSnapshotSurvivesEncodeAndDecode() throws {
    let original = ContinueWatchingSnapshot(profileID: "pf_a", entries: [
      ContinueWatchingSnapshot.Entry(id: "m1", title: "Dune", subtitle: "2021", progress: 0.25,
                                     posterImageID: "img1", thumbnail: Data([1, 2, 3])),
      entry("m2"),
    ])
    let data = try ContinueWatchingSnapshotPolicy.encode(original)
    #expect(ContinueWatchingSnapshotPolicy.decode(data) == original)
    #expect(ContinueWatchingSnapshotPolicy.decode(Data("not json".utf8)) == nil)
  }

  /// The stored shape holds display data only (TRUTHS S4): no key names an address or a token.
  @Test func theStoredShapeCarriesNoUrlOrToken() throws {
    let data = try ContinueWatchingSnapshotPolicy.encode(
      ContinueWatchingSnapshot(profileID: "pf_a", entries: [entry("m1")]))
    let text = String(decoding: data, as: UTF8.self).lowercased()
    for forbidden in ["url", "token", "http"] { #expect(!text.contains(forbidden)) }
  }

  @Test func theRailKeepsItsOrderAndIsCappedAtFour() {
    let entries = (1...6).map { entry("m\($0)") }
    let snapshot = ContinueWatchingSnapshotPolicy.snapshot(profileID: "pf_a", entries: entries)
    #expect(snapshot?.entries.map(\.id) == ["m1", "m2", "m3", "m4"])
    let three = ContinueWatchingSnapshotPolicy.snapshot(profileID: "pf_a", entries: Array(entries.prefix(3)))
    #expect(three?.entries.map(\.id) == ["m1", "m2", "m3"])
  }

  @Test func noProfileOrNoEntriesMeansNoSnapshot() {
    #expect(ContinueWatchingSnapshotPolicy.snapshot(profileID: nil, entries: [entry("m1")]) == nil)
    #expect(ContinueWatchingSnapshotPolicy.snapshot(profileID: "", entries: [entry("m1")]) == nil)
    #expect(ContinueWatchingSnapshotPolicy.snapshot(profileID: "pf_a", entries: []) == nil)
  }

  /// Profile B never sees A's entries, and nobody sees them with no active profile.
  @Test func aReaderSeesOnlyTheProfileTheSnapshotWasWrittenFor() {
    let forA = ContinueWatchingSnapshot(profileID: "pf_a", entries: [entry("m1"), entry("m2")])
    #expect(ContinueWatchingSnapshotPolicy.visibleEntries(forA, activeProfileID: "pf_a").map(\.id) == ["m1", "m2"])
    #expect(ContinueWatchingSnapshotPolicy.visibleEntries(forA, activeProfileID: "pf_b").isEmpty)
    #expect(ContinueWatchingSnapshotPolicy.visibleEntries(forA, activeProfileID: nil).isEmpty)
    #expect(ContinueWatchingSnapshotPolicy.visibleEntries(forA, activeProfileID: "").isEmpty)
    #expect(ContinueWatchingSnapshotPolicy.visibleEntries(nil, activeProfileID: "pf_a").isEmpty)
  }

  /// The widget's whole read, through the real store: file + the group defaults' active id.
  @Test func theFileReadHonoursTheActiveProfileInTheDefaults() throws {
    let suite = "CWSnapshotRead.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ActiveProfileStore(defaults: defaults)
    let file = tempDir("cw-read").appendingPathComponent("widget-continue-watching.json")
    try ContinueWatchingSnapshotPolicy.write(
      ContinueWatchingSnapshot(profileID: "pf_a", entries: [entry("m1")]), to: file)

    #expect(ContinueWatchingSnapshotPolicy.read(from: file, defaults: defaults).isEmpty, "no profile active")
    store.setActive(profileA)
    #expect(ContinueWatchingSnapshotPolicy.read(from: file, defaults: defaults).map(\.id) == ["m1"])
    store.setActive(profileB)
    #expect(ContinueWatchingSnapshotPolicy.read(from: file, defaults: defaults).isEmpty, "B never sees A's")
    #expect(ContinueWatchingSnapshotPolicy.read(
      from: file.deletingLastPathComponent().appendingPathComponent("missing.json"),
      defaults: defaults).isEmpty)
  }

  @Test func legacyAndUnchosenScopesGetNothing() {
    let rail = [movie("m1", level: 1)]
    let legacy = ProfileScope.legacy(unrestrictedLevel: 4, unratedLevel: 4)
    let unchosen = ProfileScope.unchosen(maxAgeLevel: 4, unratedLevel: 4)
    #expect(ContinueWatchingSnapshotPolicy.entries(from: rail, scope: legacy).isEmpty)
    #expect(ContinueWatchingSnapshotPolicy.entries(from: rail, scope: unchosen).isEmpty)
    // Their ids can never name a snapshot either.
    let chosen = ProfileScope(id: "pf_a", maxAgeLevel: 4, unratedLevel: 4)
    #expect(ContinueWatchingSnapshotPolicy.entries(from: rail, scope: chosen).map(\.id) == ["m1"])
  }

  /// FR-242 through ProfileScope.allows: a title above the ceiling is dropped, an unrated one
  /// counts at the unrated level.
  @Test func theAgeCeilingDropsWhatTheProfileMayNotSee() {
    let rail = [movie("kid", level: 1), movie("teen", level: 3), movie("adult", level: 4),
                movie("unrated", level: nil)]
    let kid = ProfileScope(id: "pf_k", maxAgeLevel: 1, unratedLevel: 4)
    let teen = ProfileScope(id: "pf_t", maxAgeLevel: 3, unratedLevel: 4)
    let owner = ProfileScope(id: "pf_o", maxAgeLevel: 4, unratedLevel: 4)
    #expect(ContinueWatchingSnapshotPolicy.entries(from: rail, scope: kid).map(\.id) == ["kid"])
    #expect(ContinueWatchingSnapshotPolicy.entries(from: rail, scope: teen).map(\.id) == ["kid", "teen"])
    #expect(ContinueWatchingSnapshotPolicy.entries(from: rail, scope: owner).map(\.id)
            == ["kid", "teen", "adult", "unrated"])
  }

  @Test func anEntryCarriesTitleSubtitleAndProgress() {
    let ep = ItemSummary(id: "e1", type: "episode", title: "file_name_s02e04", year: 2019,
                         addedAt: "2026-01-01T00:00:00Z", posterImageId: "img-e1",
                         progress: ItemProgress(positionSeconds: 1500, durationSeconds: 6000, updatedAt: "x"),
                         showName: "Severance", seasonNumber: 2, episodeNumber: 4, ageLevel: 1)
    let e = ContinueWatchingSnapshotPolicy.entry(for: ep)
    #expect(e.title == "Severance")
    #expect(e.subtitle == "S2 \u{00B7} E4")
    #expect(e.progress == 0.25)
    #expect(e.posterImageID == "img-e1")
    #expect(e.thumbnail == nil)
    let m = ContinueWatchingSnapshotPolicy.entry(for: movie("m1", year: 2021))
    #expect(m.title == "Movie m1")
    #expect(m.subtitle == "2021")
    #expect(m.progress == nil)
  }

  @Test func aWriteIsSkippedWhenTheBytesAreUnchanged() throws {
    let file = tempDir("cw-write").appendingPathComponent("widget-continue-watching.json")
    let snapshot = ContinueWatchingSnapshot(profileID: "pf_a", entries: [entry("m1"), entry("m2")])
    #expect(try ContinueWatchingSnapshotPolicy.write(snapshot, to: file) == true)
    let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    #expect(try ContinueWatchingSnapshotPolicy.write(snapshot, to: file) == false, "same bytes: no write")
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)
    let changed = ContinueWatchingSnapshot(profileID: "pf_a", entries: [entry("m1")])
    #expect(try ContinueWatchingSnapshotPolicy.write(changed, to: file) == true)
  }
}

// MARK: - The app's writer

@Suite("Continue Watching snapshot writer", .serialized)
@MainActor
struct ContinueWatchingSnapshotWriterTests {

  /// An isolated AppState with `active` chosen (nil: profiles cached, none chosen), the writer
  /// pointed at a file the test owns, and a thumbnail loader that never touches the network.
  private func makeState(active: Profile?, cached: [Profile]? = nil) async -> (AppState, URL, ActiveProfileStore) {
    let suite = "CWSnapshotWriter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = ActiveProfileStore(defaults: defaults)
    if let cached { store.setCachedProfiles(cached) }
    if let active { store.setActive(active) }
    let dir = tempDir("cw-writer")
    let localStore = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
    await localStore.setActiveProfile(store.activeScope)
    let state = AppState(profileStore: store, localStore: localStore, serverUpdateDefaults: defaults,
                         firstConnectionDefaults: defaults)
    let url = dir.appendingPathComponent("widget-continue-watching.json")
    state.continueWatchingSnapshotURL = url
    state.continueWatchingThumbnailLoader = { _ in nil }
    return (state, url, store)
  }

  private func stored(_ url: URL) -> ContinueWatchingSnapshot? {
    (try? Data(contentsOf: url)).flatMap(ContinueWatchingSnapshotPolicy.decode)
  }

  private func counting(_ body: (_ calls: () -> Int) -> Void) {
    var calls = 0
    let original = ContinueWatchingWidgetRefresh.notify
    ContinueWatchingWidgetRefresh.notify = { calls += 1 }
    defer { ContinueWatchingWidgetRefresh.notify = original }
    body { calls }
  }

  @Test func theRailIsWrittenForTheActiveProfileCappedAtFour() async {
    let (state, url, _) = await makeState(active: profileA, cached: [profileA, profileB])
    state.homeContinueWatching = (1...6).map { movie("m\($0)") }
    let snapshot = stored(url)
    #expect(snapshot?.profileID == "pf_a")
    #expect(snapshot?.entries.map(\.id) == ["m1", "m2", "m3", "m4"])
  }

  @Test func theWidgetIsToldOnlyWhenTheFileChanged() async {
    let (state, _, _) = await makeState(active: profileA, cached: [profileA, profileB])
    counting { calls in
      state.homeContinueWatching = [movie("m1")]
      #expect(calls() == 1)
      state.writeContinueWatchingSnapshot()
      state.writeContinueWatchingSnapshot()
      #expect(calls() == 1, "unchanged bytes: not reloaded")
      state.homeContinueWatching = [movie("m1"), movie("m2")]
      #expect(calls() == 2)
    }
  }

  @Test func anEmptyRailRemovesTheFile() async {
    let (state, url, _) = await makeState(active: profileA, cached: [profileA, profileB])
    state.homeContinueWatching = [movie("m1")]
    #expect(FileManager.default.fileExists(atPath: url.path))
    counting { calls in
      state.homeContinueWatching = []
      #expect(!FileManager.default.fileExists(atPath: url.path))
      #expect(calls() == 1)
    }
  }

  @Test func anUnchosenProfileWritesNoFile() async {
    let (state, url, _) = await makeState(active: nil, cached: [profileA, profileB])
    #expect(state.profileStore.activeScope.isUnchosen)
    state.homeContinueWatching = [movie("m1")]
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func aServerWithoutProfilesWritesNoFile() async {
    let (state, url, _) = await makeState(active: nil)
    #expect(state.profileStore.activeScope.isLegacy)
    state.homeContinueWatching = [movie("m1")]
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  /// A restricted profile's file holds nothing above its ceiling.
  @Test func theWrittenFileHonoursTheProfilesCeiling() async {
    let (state, url, _) = await makeState(active: profileB, cached: [profileA, profileB])
    state.homeContinueWatching = [movie("adult", level: 4), movie("kid", level: 1)]
    #expect(stored(url)?.entries.map(\.id) == ["kid"])
  }

  /// Sign-out: clearHomeState empties the rail and deletes the file.
  @Test func signOutDeletesTheSnapshot() async {
    let (state, url, _) = await makeState(active: profileA, cached: [profileA, profileB])
    state.homeContinueWatching = [movie("m1")]
    #expect(FileManager.default.fileExists(atPath: url.path))
    state.clearHomeState()
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  /// Deleting is the explicit call itself, not a side effect of the rail emptying: it removes a
  /// file the rail did not write.
  @Test func deleteRemovesAFileEvenWithAnEmptyRail() async throws {
    let (state, url, _) = await makeState(active: profileA, cached: [profileA, profileB])
    try ContinueWatchingSnapshotPolicy.write(
      ContinueWatchingSnapshot(profileID: "pf_a", entries: [entry("stale")]), to: url)
    #expect(state.homeContinueWatching.isEmpty)
    state.deleteContinueWatchingSnapshot()
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  /// A profile switch deletes A's file; B's rail never lands in it under A's id.
  @Test func aProfileSwitchDeletesThePreviousProfilesSnapshot() async {
    let (state, url, _) = await makeState(active: profileA, cached: [profileA, profileB])
    state.homeContinueWatching = [movie("m1", level: 1)]
    #expect(stored(url)?.profileID == "pf_a")
    await state.switchProfile(to: profileB)
    // Nothing was loaded for B (no server), so nothing may remain, and certainly not A's.
    #expect(stored(url)?.profileID != "pf_a")
    #expect(stored(url)?.entries.map(\.id) != ["m1"])
  }

  @Test func thumbnailsAreFetchedOnceAndWrittenIntoTheFile() async {
    let (state, url, _) = await makeState(active: profileA, cached: [profileA, profileB])
    var asked: [String] = []
    state.continueWatchingThumbnailLoader = { id in
      asked.append(id)
      return Data([9, 8, 7])
    }
    state.homeContinueWatching = [movie("m1", poster: "img1")]
    #expect(stored(url)?.entries.first?.thumbnail == nil, "the first write does not wait for the picture")
    await state.waitForContinueWatchingThumbnails()
    #expect(stored(url)?.entries.first?.thumbnail == Data([9, 8, 7]))
    // A later rail change keeps the picture and does not ask again.
    state.homeContinueWatching = [movie("m1", poster: "img1"), movie("m2")]
    await state.waitForContinueWatchingThumbnails()
    #expect(stored(url)?.entries.first?.thumbnail == Data([9, 8, 7]))
    #expect(asked == ["img1"])
  }

  /// A fetch that outlives a sign-out must not resurrect the file.
  @Test func aThumbnailArrivingAfterSignOutWritesNothing() async {
    let (state, url, _) = await makeState(active: profileA, cached: [profileA, profileB])
    state.continueWatchingThumbnailLoader = { _ in
      try? await Task.sleep(for: .milliseconds(100))
      return Data([1])
    }
    state.homeContinueWatching = [movie("m1", poster: "img1")]
    state.clearHomeState()
    await state.waitForContinueWatchingThumbnails()
    try? await Task.sleep(for: .milliseconds(250))
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}

// MARK: - The upgrade copy

@Suite("Profile store upgrade copy")
struct ProfileStoreMigrationTests {

  private func makeStore() throws -> (ActiveProfileStore, UserDefaults, () -> Void) {
    let suite = "CWMigration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (ActiveProfileStore(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
  }

  /// A real plist at a temp path, the way the app-local domain is stored on disk.
  private func writePlist(_ values: [String: Any]) throws -> URL {
    let url = tempDir("cw-legacy").appendingPathComponent("group.HeiloProjects.DSReel.plist")
    let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    try data.write(to: url)
    return url
  }

  private var legacyValues: [String: Any] {
    [
      "dsReel.profile.activeID": "pf_a",
      "dsReel.profile.activeMaxAgeLevel": 3,
      "dsReel.profile.unratedLevel": 4,
      "unrelated.key": "ignored",
    ]
  }

  @Test func theLegacyPathIsInferredFromTheGroupIdentifier() {
    let url = ActiveProfileStore.legacyAppLocalStoreURL
    #expect(url?.lastPathComponent == "group.HeiloProjects.DSReel.plist")
    #expect(url?.deletingLastPathComponent().lastPathComponent == "Preferences")
  }

  @Test func readsAValidPlistAndNothingElse() throws {
    let url = try writePlist(legacyValues)
    let values = ActiveProfileStore.legacyValues(at: url)
    #expect(values?["dsReel.profile.activeID"] as? String == "pf_a")
    #expect(ActiveProfileStore.legacyValues(at: nil) == nil)
    #expect(ActiveProfileStore.legacyValues(at: url.deletingLastPathComponent().appendingPathComponent("none.plist")) == nil)
    let corrupt = tempDir("cw-corrupt").appendingPathComponent("bad.plist")
    try Data("this is not a plist".utf8).write(to: corrupt)
    #expect(ActiveProfileStore.legacyValues(at: corrupt) == nil)
    let notADictionary = tempDir("cw-array").appendingPathComponent("array.plist")
    try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0).write(to: notADictionary)
    #expect(ActiveProfileStore.legacyValues(at: notADictionary) == nil)
  }

  @Test func copiesFromTheLegacyPlistOnce() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    let url = try writePlist(legacyValues)
    let copied = store.migrateFromLegacyStore(ActiveProfileStore.legacyValues(at: url))
    #expect(Set(copied) == ["dsReel.profile.activeID", "dsReel.profile.activeMaxAgeLevel",
                            "dsReel.profile.unratedLevel"])
    #expect(store.activeProfileID == "pf_a")
    #expect(store.activeScope.maxAgeLevel == 3)
    #expect(store.unratedLevel == 4)
  }

  @Test func aSecondRunChangesNothing() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    store.migrateFromLegacyStore(legacyValues)
    let again = store.migrateFromLegacyStore(["dsReel.profile.activeID": "pf_other",
                                              "dsReel.profile.activeMaxAgeLevel": 1])
    #expect(again.isEmpty)
    #expect(store.activeProfileID == "pf_a")
    #expect(store.activeScope.maxAgeLevel == 3)
  }

  @Test func neverOverwritesWhatTheGroupAlreadyHolds() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    store.setActive(profileB)
    let copied = store.migrateFromLegacyStore(legacyValues)
    #expect(copied.isEmpty)
    #expect(store.activeProfileID == "pf_b")
    #expect(store.activeScope.maxAgeLevel == 1)
  }

  /// ANY one profile value in the target blocks the copy: two states are never mixed.
  @Test func aSingleExistingValueBlocksTheWholeCopy() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    store.setCachedProfiles([profileA, profileB], unrestrictedLevel: 4)
    let copied = store.migrateFromLegacyStore(legacyValues)
    #expect(copied.isEmpty)
    #expect(store.activeProfileID == nil)
  }

  @Test func neverDeletesTheLegacyCopy() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    let url = try writePlist(legacyValues)
    store.migrateFromLegacyStore(ActiveProfileStore.legacyValues(at: url))
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(ActiveProfileStore.legacyValues(at: url)?["dsReel.profile.activeID"] as? String == "pf_a")
  }

  @Test func noLegacyValuesSetsOnlyTheMarker() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    #expect(store.migrateFromLegacyStore(nil).isEmpty)
    #expect(store.activeProfileID == nil)
    // The marker is set: a later call with values is a no-op.
    #expect(store.migrateFromLegacyStore(legacyValues).isEmpty)
    #expect(store.activeProfileID == nil)
  }

  /// Sign-out clears the account's values but not the marker, so the old copy never returns.
  @Test func theMarkerSurvivesSignOut() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    store.migrateFromLegacyStore(legacyValues)
    #expect(store.activeProfileID == "pf_a")
    store.clearAll()
    #expect(store.activeProfileID == nil)
    #expect(store.migrateFromLegacyStore(legacyValues).isEmpty)
    #expect(store.activeProfileID == nil, "the legacy values were not copied back after sign-out")
  }
}
