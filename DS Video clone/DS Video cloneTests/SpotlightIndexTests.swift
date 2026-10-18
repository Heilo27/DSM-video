import Foundation
import Testing
@testable import DSM_Video

// FR-153, TASK-743. Written by the implementer at the brief's explicit instruction (this team's
// brief for this task); a blind oracle pass by Worf should still follow. Expected values are
// literals, not derived from SpotlightPolicy.

// MARK: - A fake index

/// Records what the app asked the system index to do, in order.
@MainActor
final class FakeSpotlightIndexer: SpotlightIndexing {
  enum Call: Equatable { case sync([String]), clear }
  private(set) var calls: [Call] = []
  /// What the index holds right now: the ids of the last sync, emptied by clear.
  private(set) var indexed: [String] = []

  func sync(entries: [SpotlightEntry], artwork: @escaping (String) async -> Data?) async {
    indexed = entries.map(\.id)
    calls.append(.sync(indexed))
  }

  func clear() async {
    indexed = []
    calls.append(.clear)
  }
}

private func movie(_ id: String, level: Int?, year: Int? = 2020, poster: String? = nil) -> ItemSummary {
  ItemSummary(id: id, type: "movie", title: "Movie \(id)", year: year, addedAt: "2026-01-01T00:00:00Z",
              posterImageId: poster, ageLevel: level)
}

private func episode(_ id: String, show: String, season: Int, ep: Int, level: Int?,
                     poster: String? = nil) -> ItemSummary {
  ItemSummary(id: id, type: "episode", title: "Ep \(id)", year: 2019, addedAt: "2026-01-01T00:00:00Z",
              posterImageId: poster, showName: show, seasonNumber: season, episodeNumber: ep,
              ageLevel: level)
}

private func scope(_ id: String, max: Int, unrated: Int = 4) -> ProfileScope {
  ProfileScope(id: id, maxAgeLevel: max, unratedLevel: unrated)
}

// MARK: - The policy

@Suite("Spotlight policy")
struct SpotlightPolicyTests {

  /// Red if: the filter is skipped, or compares levels itself with the wrong sense.
  @Test func aRestrictedProfileIsOfferedNothingAboveItsCeiling() {
    let items = [movie("m-kid", level: 1), movie("m-teen", level: 3), movie("m-adult", level: 4)]
    #expect(SpotlightPolicy.entries(for: items, scope: scope("pf_kid", max: 1)).map(\.id) == ["m-kid"])
    #expect(SpotlightPolicy.entries(for: items, scope: scope("pf_teen", max: 3)).map(\.id) == ["m-kid", "m-teen"])
    #expect(SpotlightPolicy.entries(for: items, scope: scope("pf_owner", max: 4)).map(\.id)
            == ["m-adult", "m-kid", "m-teen"])
  }

  /// An unrated title counts at the profile's unrated level (FR-242): hidden from a profile
  /// whose ceiling is below it.
  @Test func anUnratedTitleCountsAtTheUnratedLevel() {
    let items = [movie("m-unrated", level: nil)]
    #expect(SpotlightPolicy.entries(for: items, scope: scope("pf_kid", max: 1, unrated: 4)).isEmpty)
    #expect(SpotlightPolicy.entries(for: items, scope: scope("pf_owner", max: 4, unrated: 4)).map(\.id)
            == ["m-unrated"])
  }

  /// Fails closed: an account with profiles where none is chosen indexes nothing.
  @Test func anUnchosenProfileIndexesNothing() {
    let items = [movie("m-kid", level: 1)]
    let unchosen = ProfileScope.unchosen(maxAgeLevel: 4, unratedLevel: 4)
    #expect(SpotlightPolicy.entries(for: items, scope: unchosen).isEmpty)
  }

  @Test func aShowIsOneEntryNotOnePerEpisode() {
    let items = [
      episode("e3", show: "Severance", season: 1, ep: 3, level: 3),
      episode("e1", show: "Severance", season: 1, ep: 1, level: 3),
      episode("e2", show: "Severance", season: 1, ep: 2, level: 3),
      movie("m1", level: 3),
    ]
    let entries = SpotlightPolicy.entries(for: items, scope: scope("pf_owner", max: 4))
    #expect(entries.map(\.id) == ["e1", "m1"])
    #expect(entries.first?.title == "Severance")
    #expect(entries.first?.isShow == true)
    #expect(entries.last?.isShow == false)
    #expect(entries.last?.subtitle == "2020")
  }

  /// The same library handed over in a different order gives the same answer.
  @Test func theChoiceOfEpisodeDoesNotDependOnListOrder() {
    let items = [
      episode("b", show: "Show", season: 2, ep: 1, level: 1),
      episode("a", show: "Show", season: 1, ep: 5, level: 1),
      episode("c", show: "Show", season: 1, ep: 9, level: 1),
    ]
    let forward = SpotlightPolicy.entries(for: items, scope: scope("p", max: 4))
    let backward = SpotlightPolicy.entries(for: items.reversed(), scope: scope("p", max: 4))
    #expect(forward == backward)
    #expect(forward.map(\.id) == ["a"])
  }

  /// A show whose adult episodes are hidden still appears through the episodes the profile may see,
  /// and one with none visible does not appear at all.
  @Test func aShowShowsOnlyThroughEpisodesTheProfileMaySee() {
    let items = [
      episode("e1", show: "Mixed", season: 1, ep: 1, level: 4),
      episode("e2", show: "Mixed", season: 1, ep: 2, level: 1),
      episode("x1", show: "AllAdult", season: 1, ep: 1, level: 4),
    ]
    let kid = SpotlightPolicy.entries(for: items, scope: scope("pf_kid", max: 1))
    #expect(kid.map(\.id) == ["e2"])
  }

  @Test func aShowUsesAnEpisodePosterWhenItsFirstEpisodeHasNone() {
    let items = [
      episode("e1", show: "S", season: 1, ep: 1, level: 1, poster: nil),
      episode("e2", show: "S", season: 1, ep: 2, level: 1, poster: "img-2"),
    ]
    let entries = SpotlightPolicy.entries(for: items, scope: scope("p", max: 4))
    #expect(entries.map(\.id) == ["e1"])
    #expect(entries.first?.posterImageId == "img-2")
  }

  // MARK: Manifest diff

  @Test func theDiffAddsUpdatesAndRemovesOnlyTheDifference() {
    let keep = SpotlightEntry(id: "keep", title: "Keep", subtitle: nil, posterImageId: nil, isShow: false)
    let changed = SpotlightEntry(id: "chg", title: "New title", subtitle: nil, posterImageId: nil, isShow: false)
    let added = SpotlightEntry(id: "add", title: "Add", subtitle: nil, posterImageId: nil, isShow: false)
    let oldChanged = SpotlightEntry(id: "chg", title: "Old title", subtitle: nil, posterImageId: nil, isShow: false)
    let manifest = [
      "keep": SpotlightPolicy.manifestValue(for: keep, withArtwork: false),
      "chg": SpotlightPolicy.manifestValue(for: oldChanged, withArtwork: false),
      "gone": "whatever",
    ]
    let result = SpotlightPolicy.changes(desired: [keep, changed, added], manifest: manifest)
    #expect(result.upserts.map(\.id) == ["chg", "add"])
    #expect(result.deletes == ["gone"])
  }

  @Test func nothingChangedMeansNothingToDo() {
    let entry = SpotlightEntry(id: "a", title: "A", subtitle: "2020", posterImageId: "img", isShow: false)
    let manifest = ["a": SpotlightPolicy.manifestValue(for: entry, withArtwork: true)]
    #expect(SpotlightPolicy.changes(desired: [entry], manifest: manifest).isEmpty)
  }

  /// Indexed earlier without the picture it can now have: indexed again. One that never had a
  /// poster is not retried forever.
  @Test func anEntryIndexedWithoutItsArtworkIsRetried() {
    let withPoster = SpotlightEntry(id: "a", title: "A", subtitle: nil, posterImageId: "img", isShow: false)
    let noPoster = SpotlightEntry(id: "b", title: "B", subtitle: nil, posterImageId: nil, isShow: false)
    let manifest = [
      "a": SpotlightPolicy.manifestValue(for: withPoster, withArtwork: false),
      "b": SpotlightPolicy.manifestValue(for: noPoster, withArtwork: false),
    ]
    let result = SpotlightPolicy.changes(desired: [withPoster, noPoster], manifest: manifest)
    #expect(result.upserts.map(\.id) == ["a"])
  }

  /// The profile-switch case: titles the new profile may not see are in `deletes`.
  @Test func switchingToAStricterProfileDeletesTheTitlesItMayNotSee() {
    let items = [movie("m-kid", level: 1), movie("m-adult", level: 4)]
    let owner = SpotlightPolicy.entries(for: items, scope: scope("pf_owner", max: 4))
    var manifest: [String: String] = [:]
    for entry in owner { manifest[entry.id] = SpotlightPolicy.manifestValue(for: entry, withArtwork: false) }
    let kid = SpotlightPolicy.entries(for: items, scope: scope("pf_kid", max: 1))
    let result = SpotlightPolicy.changes(desired: kid, manifest: manifest)
    #expect(result.deletes == ["m-adult"])
    #expect(result.upserts.isEmpty)
  }

  /// S4: what is handed to the index carries no address, token or path.
  @Test func anEntryCarriesNoUrlOrToken() {
    let entry = SpotlightPolicy.entries(
      for: [movie("m1", level: 1, poster: "img-1")], scope: scope("p", max: 4))[0]
    let flat = entry.fingerprint
    #expect(!flat.contains("http"))
    #expect(!flat.contains("token"))
    #expect(!flat.contains("/api/"))
  }
}

// MARK: - The AppState wiring

@Suite("Spotlight wiring")
@MainActor
struct SpotlightWiringTests {
  private let kid = Profile(id: "pf_sp_kid", name: "Kid", avatar: "cat", maxAgeLevel: 1,
                            hasPin: false, isOwner: false)
  private let owner = Profile(id: "pf_sp_owner", name: "Owner", avatar: "moon", maxAgeLevel: 4,
                              hasPin: false, isOwner: true)

  /// An isolated AppState (its own profile store and catalog) over a fake index, with the catalog
  /// holding one kid-safe and one adult movie.
  private func withState(
    active: Profile, _ body: (AppState, FakeSpotlightIndexer, LocalStore) async -> Void
  ) async {
    let suite = "SpotlightWiringTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      Issue.record("no throwaway defaults suite")
      return
    }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel-spotlight-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
      Issue.record("no temp dir: \(error)")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: dir)
    }
    let profileStore = ActiveProfileStore(defaults: defaults)
    profileStore.setCachedProfiles([owner, kid])
    profileStore.setActive(active)
    let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
    await store.setActiveProfile(profileStore.activeScope)
    await store.upsertItems([movie("m-kid", level: 1), movie("m-adult", level: 4)])
    let fake = FakeSpotlightIndexer()
    let state = AppState(profileStore: profileStore, localStore: store, serverUpdateDefaults: defaults,
                         firstConnectionDefaults: defaults, spotlightIndexer: fake)
    state.sessionToken = nil
    await body(state, fake, store)
  }

  /// Red if: the refresh reads the catalog unscoped, or does not run.
  @Test func theIndexHoldsOnlyWhatTheActiveProfileMaySee() async {
    await withState(active: kid) { state, fake, _ in
      state.sessionToken = "stub-token"
      state.refreshSpotlightIndex()
      await state.waitForSpotlightIdle()
      #expect(fake.indexed == ["m-kid"])
    }
  }

  /// A profile switch empties the index, then fills it for the new profile, in that order.
  @Test func aProfileSwitchClearsThenReindexesForTheNewProfile() async {
    await withState(active: owner) { state, fake, store in
      state.sessionToken = "stub-token"
      state.refreshSpotlightIndex()
      await state.waitForSpotlightIdle()
      #expect(fake.indexed == ["m-adult", "m-kid"])

      await state.switchProfile(to: kid)
      await state.waitForSpotlightIdle()
      // Cleared before the new profile's pass, and the pass held nothing the kid may not see.
      #expect(fake.calls.contains(.clear))
      let lastClear = fake.calls.lastIndex(of: .clear) ?? -1
      let lastSync = fake.calls.lastIndex(where: { if case .sync = $0 { true } else { false } }) ?? -1
      #expect(lastClear < lastSync)
      #expect(fake.indexed == ["m-kid"])
      _ = store
    }
  }

  /// Sign-out leaves nothing searchable.
  @Test func signOutEmptiesTheIndex() async {
    await withState(active: owner) { state, fake, _ in
      state.sessionToken = "stub-token"
      state.refreshSpotlightIndex()
      await state.waitForSpotlightIdle()
      #expect(!fake.indexed.isEmpty)

      state.logout()
      await state.waitForSpotlightIdle()
      #expect(fake.indexed.isEmpty)
      #expect(fake.calls.last == .clear)
    }
  }

  /// Signed out, a stray refresh (a late sync completion) must not index anything.
  @Test func aRefreshWithNoSessionIndexesNothing() async {
    await withState(active: owner) { state, fake, _ in
      state.sessionToken = nil
      state.refreshSpotlightIndex()
      await state.waitForSpotlightIdle()
      #expect(fake.calls.isEmpty)
    }
  }

  /// Demo mode's library is not the user's: never indexed.
  @Test func demoModeIndexesNothing() async {
    await withState(active: owner) { state, fake, _ in
      state.sessionToken = "demo"
      state.refreshSpotlightIndex()
      await state.waitForSpotlightIdle()
      #expect(fake.calls.isEmpty)
    }
  }
}
