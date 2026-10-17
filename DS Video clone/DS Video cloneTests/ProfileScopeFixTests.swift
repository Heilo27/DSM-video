import Testing
import Foundation
import SQLite3
@testable import DSM_Video

// MARK: - TASK-919 L2 · profile scope fixes (TASK-935, TASK-936, TASK-921, TASK-922)
//
// Every test names the change that turns it red. Expected values are literals taken from the
// spec (FRD-002 §6, FR-221, FR-242, ProfilesAPI.md), never recomputed from production code,
// except where a test's whole job is to pin two production implementations to each other
// (SQL vs ProfileScope.allows), and there a literal table anchors both.
//
// Two layers:
//  - isolated: a LocalStore on a temp file and an ActiveProfileStore on a private UserDefaults
//    suite, so nothing shared is touched and persistence is read back through a FRESH instance.
//  - wiring: AppState against the profile stub server, over the shared stores, because
//    refreshProfiles/recordProgress only ever talk to LocalStore.shared. Those run inside
//    ProfileStateGate (shared with ProfileScreensServerTests) and put every shared store back.

// MARK: Helpers

/// One test at a time may hold the shared stores (ActiveProfileStore.shared, LocalStore.shared's
/// scope) and the stub server's route table. Swift Testing runs suites in parallel, and these
/// tests interleave at every `await`, so without this two suites would overwrite each other's
/// routes and scopes mid-run. FIFO; ownership is handed to the next waiter without a gap.
@MainActor
final class ProfileStateGate {
  static let shared = ProfileStateGate()
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func run(_ work: () async -> Void) async {
    if busy {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      busy = true
    }
    await work()
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

private func scopeTempDir(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-scope-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A private UserDefaults suite, so an ActiveProfileStore built on it shares nothing.
private func privateDefaults(_ name: String) -> UserDefaults {
  let suite = "scopefix-\(name)-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

private func prof(_ id: String, level: Int, owner: Bool = false, kids: Bool = false) -> Profile {
  Profile(id: id, name: id, avatar: "cat", maxAgeLevel: level, hasPin: false,
          isOwner: owner, kids: kids)
}

private func titleItem(_ id: String, level: Int?, seq: Int = 1) -> ItemSummary {
  ItemSummary(id: id, type: "movie", title: id, durationSeconds: 7200,
              addedAt: "2026-01-01T00:00:00Z", libraryId: "lib_t", changeSeq: seq, ageLevel: level)
}

/// Rewinds the shared store's `age_level_backfill` attempt counter through a second SQLite
/// connection to the same file (WAL permits it). The counter is persistent state of the app's
/// own database and the store offers no way to clear it; without this the wiring test could
/// run only three times per simulator install.
private func resetSharedBackfillAttempts() -> Bool {
  guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
  else { return false }
  var handle: OpaquePointer?
  defer { sqlite3_close(handle) }
  guard sqlite3_open_v2(docs.appendingPathComponent("dsreel.db").path, &handle,
                        SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
  sqlite3_busy_timeout(handle, 3000)
  return sqlite3_exec(handle, "DELETE FROM sync_cursors WHERE key = 'age_level_backfill'",
                      nil, nil, nil) == SQLITE_OK
}

/// A visible-ids set read through the same path the app reads (fetchItems, under the store's
/// current scope).
@MainActor private func visibleIDs(_ store: LocalStore) async -> Set<String> {
  Set(await store.fetchItems(forLibraryId: "lib_t").map { $0.id })
}

@Suite("TASK-919 L2 profile scope fixes", .serialized)
@MainActor
struct ProfileScopeFixTests {
  /// Borrowed for its `withAccount` (signed-in AppState on the stub, shared stores restored).
  private let host = ProfileScreensServerTests()

  private let ryanJSON = #"{"id":"pf_ryan","name":"Ryan","avatar":"moon","maxAgeLevel":4,"hasPin":true,"isOwner":true}"#
  private let mayaJSON = #"{"id":"pf_maya","name":"Maya","avatar":"cat","maxAgeLevel":2,"hasPin":false,"isOwner":false}"#
  private let progressOK = ProfileStubServer.Reply.json(200, #"{"ok":true,"applied":true}"#)

  private func profilesReply(_ profiles: [String]) -> ProfileStubServer.Reply {
    .json(200, #"{"maxProfiles":4,"activeProfileId":null,"unrestrictedLevel":4,"profiles":[\#(profiles.joined(separator: ","))]}"#)
  }
  private func plainProfile(_ id: String, level: Int = 2, owner: Bool = false) -> String {
    #"{"id":"\#(id)","name":"\#(id)","avatar":"cat","maxAgeLevel":\#(level),"hasPin":false,"isOwner":\#(owner)}"#
  }
  private func postCount() -> Int {
    ProfileStubServer.requests.filter { $0.method == "POST" }.count
  }

  // MARK: TASK-921 · kids is the server's flag

  /// OC: TASK-921 AC3 · given the server says kids:true for a level-3 profile and
  /// kids:false for a level-1 profile, when the list is decoded, then the client carries the
  /// server's flag, not a verdict of its own.
  /// Red if: Profile.kids is derived from maxAgeLevel (the old `maxAgeLevel <= 2`): the
  /// level-3 profile would read false and the level-1 profile true.
  @Test func kidsFollowsTheServerFlagNotTheLevel() throws {
    let json = #"""
    {"maxProfiles":4,"activeProfileId":null,"unrestrictedLevel":4,"profiles":[
      {"id":"pf_a","name":"A","avatar":"cat","maxAgeLevel":3,"hasPin":false,"isOwner":false,"kids":true},
      {"id":"pf_b","name":"B","avatar":"cat","maxAgeLevel":1,"hasPin":false,"isOwner":false,"kids":false}]}
    """#
    let resp = try JSONDecoder().decode(ProfilesResponse.self, from: Data(json.utf8))
    #expect(resp.profiles.map(\.id) == ["pf_a", "pf_b"])
    #expect(resp.profiles.map(\.kids) == [true, false])
    #expect(resp.profiles.map(\.maxAgeLevel) == [3, 1])
  }

  /// OC: TASK-921 AC3 · given an older server that sends no `kids`, when decoded, then kids is
  /// false (browse falls back to genres) and every other field survives.
  /// Red if: the missing-key default becomes true, or the decode throws on a missing key.
  @Test func missingKidsFieldDecodesAsFalse() throws {
    let json = #"{"id":"pf_old","name":"Old","avatar":"fox","maxAgeLevel":2,"hasPin":true,"isOwner":false}"#
    let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
    #expect(profile.kids == false)
    #expect(profile.id == "pf_old")
    #expect(profile.maxAgeLevel == 2)
    #expect(profile.hasPin)
  }

  /// OC: TASK-921 AC3 · given cached profiles with kids true and false, when the list is read
  /// back through a FRESH store on the same defaults, then each flag is kept; and a list
  /// cached by an older build (no `kids` key at all) still loads, with kids false.
  /// Red if: kids is dropped on encode (CodingKeys), or the cached decode throws on the
  /// older shape (the whole picker cache would silently vanish).
  @Test func cachedProfilesKeepKidsAndLoadFromAnOlderCache() throws {
    let defaults = privateDefaults("kids-cache")
    ActiveProfileStore(defaults: defaults).setCachedProfiles(
      [prof("pf_kid", level: 3, kids: true), prof("pf_teen", level: 1, kids: false)])

    let fresh = ActiveProfileStore(defaults: defaults).cachedProfiles
    #expect(fresh.map(\.id) == ["pf_kid", "pf_teen"])
    #expect(fresh.map(\.kids) == [true, false])

    let olderBuild = privateDefaults("kids-older")
    let legacyJSON = #"[{"id":"pf_o","name":"O","avatar":"cat","maxAgeLevel":4,"hasPin":false,"isOwner":true}]"#
    olderBuild.set(Data(legacyJSON.utf8), forKey: "dsReel.profile.cachedProfiles")
    let loaded = ActiveProfileStore(defaults: olderBuild).cachedProfiles
    #expect(loaded.map(\.id) == ["pf_o"])
    #expect(loaded.map(\.kids) == [false])
  }

  // MARK: TASK-922 · two server levels, two questions (D1b)
  //
  // unrestrictedLevel (GET /profiles)         -> "is this profile restricted": maxAgeLevel < it.
  // unratedLevel      (GET /profiles/age-levels) -> what a title with NO level counts as (FR-242).
  // Every test below uses values where the two DIFFER (5/4 and 4/5), so a conflation of the
  // two shows up as a wrong answer, not a coincidence.

  /// OC: TASK-922 AC1 · given a server that sends no `unrestrictedLevel`, when the
  /// list is decoded, then it is the documented fallback 4; given one that sends 5, then 5; and
  /// the age-levels body's own `unratedLevel` decodes independently of it.
  /// Red if: the fallback is dropped or changed, a sent value is ignored in favour of 4, or
  /// AgeLevelsResponse.unratedLevel is read from the wrong key.
  @Test func unrestrictedLevelFallsBackOnlyWhenTheServerOmitsIt() throws {
    let body = #""maxProfiles":4,"activeProfileId":null,"profiles":[]"#
    let missing = try JSONDecoder().decode(ProfilesResponse.self, from: Data("{\(body)}".utf8))
    #expect(missing.unrestrictedLevel == 4)
    let sent = try JSONDecoder().decode(
      ProfilesResponse.self, from: Data(#"{\#(body),"unrestrictedLevel":5}"#.utf8))
    #expect(sent.unrestrictedLevel == 5)

    let ladder = #"{"unratedLevel":5,"levels":[{"level":1,"key":"little","label":"Little kids","movie":["G"],"tv":["TV-Y"]}]}"#
    let levels = try JSONDecoder().decode(AgeLevelsResponse.self, from: Data(ladder.utf8))
    #expect(levels.unratedLevel == 5)
    #expect(levels.levels.map(\.level) == [1])
  }

  /// OC: TASK-922 AC1 · given the server's ladder top is 5 and its unrated level is 4 (and the
  /// reverse), when the list is cached, then a FRESH store reports each value separately and
  /// the scopes it builds carry the UNRATED level, never the ladder top; a store that never
  /// cached a list answers 4; a later list-only cache keeps 5; a non-positive level is ignored;
  /// sign-out (clearAll) forgets it.
  /// Red if: the level is not persisted (fresh store reads 4), is overwritten by a nil/0
  /// update, survives clearAll, or the scope is built from unrestrictedLevel (the conflation:
  /// activeScope.unratedLevel would read 5 where the server's unrated level is 4).
  @Test func unrestrictedLevelPersistsThroughTheStoreWithoutBecomingTheUnratedLevel() {
    let defaults = privateDefaults("unrestricted")
    let never = ActiveProfileStore(defaults: defaults)
    #expect(never.unrestrictedLevel == 4, "never cached -> fallback")
    #expect(never.unratedLevel == 4, "never stated -> fallback")

    // Ladder top 5, unrated level 4 (the unrated title sits BELOW the top).
    let writer = ActiveProfileStore(defaults: defaults)
    writer.setUnratedLevel(4)
    writer.setCachedProfiles([prof("pf_r", level: 4, owner: true), prof("pf_m", level: 2)],
                             unrestrictedLevel: 5)
    let fresh = ActiveProfileStore(defaults: defaults)
    #expect(fresh.unrestrictedLevel == 5)
    #expect(fresh.unratedLevel == 4)
    #expect(fresh.activeScope.isUnchosen)
    #expect(fresh.activeScope.unratedLevel == 4, "the scope filters with the unrated level")
    #expect(fresh.activeScope.maxAgeLevel == 2)

    fresh.setActive(prof("pf_r", level: 4, owner: true))
    #expect(fresh.activeScope.unratedLevel == 4, "a chosen profile's scope uses it too")

    fresh.setCachedProfiles([prof("pf_r", level: 4, owner: true)])
    #expect(ActiveProfileStore(defaults: defaults).unrestrictedLevel == 5, "list-only update keeps it")
    fresh.setCachedProfiles([prof("pf_r", level: 4, owner: true)], unrestrictedLevel: 0)
    #expect(ActiveProfileStore(defaults: defaults).unrestrictedLevel == 5, "non-positive ignored")

    // The reverse: unrated level 5 above a ladder top of 4.
    let other = privateDefaults("unrestricted-reverse")
    let reverse = ActiveProfileStore(defaults: other)
    reverse.setUnratedLevel(5)
    reverse.setCachedProfiles([prof("pf_r", level: 4, owner: true)], unrestrictedLevel: 4)
    let reread = ActiveProfileStore(defaults: other)
    #expect(reread.unrestrictedLevel == 4)
    #expect(reread.unratedLevel == 5)
    #expect(reread.activeScope.unratedLevel == 5)

    fresh.clearAll()
    let cleared = ActiveProfileStore(defaults: defaults)
    #expect(cleared.unrestrictedLevel == 4, "sign-out forgets the ladder top")
    #expect(cleared.unratedLevel == 4, "sign-out forgets the unrated level")
  }

  /// OC: TASK-922 AC1 · given the age-levels endpoint never answered on this device, when the
  /// store is read, then the unrated level is the documented fallback 4; once stated (5) a
  /// FRESH store keeps it and every kind of scope (chosen, unchosen, legacy) carries it while
  /// the ladder top stays 4; zero and negative values are ignored; a list cached afterwards
  /// does not touch it.
  /// Red if: setUnratedLevel does not persist, accepts non-positive values, any scope kind
  /// ignores it (legacy keeps a literal), or setCachedProfiles overwrites it.
  @Test func unratedLevelPersistsAndReachesEveryScopeKind() {
    let defaults = privateDefaults("unrated")
    let store = ActiveProfileStore(defaults: defaults)
    #expect(store.unratedLevel == 4, "before any age-levels answer: fallback")
    #expect(AgeLevelsResponse.fallbackUnratedLevel == 4, "the documented fallback")
    #expect(store.activeScope.isLegacy)
    #expect(store.activeScope.unratedLevel == 4)

    store.setUnratedLevel(5)
    store.setUnratedLevel(0)
    store.setUnratedLevel(-3)
    let fresh = ActiveProfileStore(defaults: defaults)
    #expect(fresh.unratedLevel == 5, "persisted, and 0 / -3 did not replace it")
    #expect(fresh.unrestrictedLevel == 4, "the ladder top is a different value")

    #expect(fresh.activeScope.isLegacy)
    #expect(fresh.activeScope.unratedLevel == 5, "legacy scope")
    #expect(fresh.activeScope.maxAgeLevel == 5, "legacy sees up to the higher of the two levels")

    fresh.setCachedProfiles([prof("pf_a", level: 2, owner: true), prof("pf_b", level: 3)],
                            unrestrictedLevel: 4)
    #expect(ActiveProfileStore(defaults: defaults).unratedLevel == 5, "a list does not touch it")
    #expect(fresh.activeScope.isUnchosen)
    #expect(fresh.activeScope.unratedLevel == 5, "unchosen scope")

    fresh.setActive(prof("pf_b", level: 3))
    #expect(fresh.activeScope.unratedLevel == 5, "chosen scope")
  }

  /// OC: TASK-922 AC1 · given a ladder top of 5 and an unrated level of 4, a level-4 profile is
  /// restricted; given a ladder top of 4 and an unrated level of 5, the same profile is NOT.
  /// Red if: Profile.isRestricted compares against a literal 4, a static, or the unrated level
  /// (the second half would read restricted, the first half would read unrestricted).
  @Test func isRestrictedFollowsTheStoredLadderTopNotTheUnratedLevel() async {
    await ProfileStateGate.shared.run {
      let store = ActiveProfileStore.shared
      let savedList = store.cachedProfiles
      let savedTop = store.unrestrictedLevel
      let savedUnrated = store.unratedLevel
      let adult = prof("pf_adult", level: 4, owner: true)

      store.setUnratedLevel(4)
      store.setCachedProfiles(savedList, unrestrictedLevel: 5)
      #expect(adult.isRestricted, "level 4 is below a ladder that now reaches 5")
      #expect(prof("pf_top", level: 5).isRestricted == false)

      store.setUnratedLevel(5)
      store.setCachedProfiles(savedList, unrestrictedLevel: 4)
      #expect(adult.isRestricted == false, "level 4 is the top of a 4-level ladder, whatever unrated is")
      #expect(prof("pf_teen", level: 3).isRestricted, "control: a lower profile is restricted")

      store.setUnratedLevel(savedUnrated)
      store.setCachedProfiles(savedList, unrestrictedLevel: savedTop)
    }
  }

  /// OC: TASK-922 AC2 · given titles at levels 1...5 plus one with no level, when each ceiling
  /// 1...5 reads them through SQL (fetchItems) and through ProfileScope.allows(ageLevel:), for an
  /// unrated level of 4 and of 5, then both give the same answer, and that answer is the literal
  /// table below: the untitled-level title follows the UNRATED level, not the ceiling's top.
  /// Red if: the SQL binds a literal 4 (unrated 5: the unrated title shows to ceiling 4), binds
  /// the wrong scope field, allows() uses a literal, or the two rules drift apart.
  @Test func sqlFilterAndSwiftRuleAgreeForEveryLevelAndNull() async throws {
    let dir = try scopeTempDir("agree")
    defer { try? FileManager.default.removeItem(at: dir) }

    func ids(upTo n: Int, withUnrated: Bool = false) -> Set<String> {
      Set((1...n).map { "L\($0)" }).union(withUnrated ? ["LNULL"] : [])
    }
    // [unratedLevel, ceiling] -> the titles that ceiling may see. LNULL has no level.
    let table: [[Int]: Set<String>] = [
      [4, 1]: ids(upTo: 1), [4, 2]: ids(upTo: 2), [4, 3]: ids(upTo: 3),
      [4, 4]: ids(upTo: 4, withUnrated: true), [4, 5]: ids(upTo: 5, withUnrated: true),
      [5, 1]: ids(upTo: 1), [5, 2]: ids(upTo: 2), [5, 3]: ids(upTo: 3),
      [5, 4]: ids(upTo: 4),                       [5, 5]: ids(upTo: 5, withUnrated: true),
    ]
    for unrated in [4, 5] {
      let store = await LocalStore.makeForTesting(
        databaseURL: dir.appendingPathComponent("agree-\(unrated).db"))
      #expect(await store.isUnavailable == false, "precondition: the store opened")
      let rated: [ItemSummary] = (1...5).map { (n: Int) in titleItem("L\(n)", level: n) }
      let all = rated + [titleItem("LNULL", level: nil)]
      await store.upsertItems(all)

      for ceiling in 1...5 {
        let scope = ProfileScope(id: "pf_x", maxAgeLevel: ceiling, unratedLevel: unrated)
        await store.setActiveProfile(scope)
        let sql = await visibleIDs(store)
        let swift = Set(all.filter { scope.allows(ageLevel: $0.ageLevel) }.map { $0.id })
        #expect(sql == swift, "SQL and allows() disagree at unrated \(unrated) ceiling \(ceiling)")
        #expect(sql == table[[unrated, ceiling]], "unrated \(unrated) ceiling \(ceiling)")
      }
    }
  }

  /// OC: TASK-922 AC1 · given the server states its unrated level is 5 and the device held 4,
  /// when the age ladder loads, then the store holds 5 (a FRESH read), the ladder labels
  /// arrive, the ladder top is untouched, the offline scope now carries 5, and a title with no
  /// level that a ceiling-4 viewer saw a moment ago is hidden.
  /// Red if: loadAgeLevelsIfNeeded stops storing the level (still 4), or forgets to hand the
  /// new scope to LocalStore (scope still 4 and the unrated title still shows).
  @Test func loadingTheAgeLadderStoresTheUnratedLevelAndReachesTheOfflineReads() async {
    let viewer = prof("pf_t922_viewer", level: 4, owner: true)
    let ladder = #"{"unratedLevel":5,"levels":[{"level":1,"key":"little","label":"Little kids","movie":["G"],"tv":["TV-Y"]},{"level":2,"key":"kids","label":"Kids","movie":["PG"],"tv":["TV-PG"]}]}"#

    await host.withAccount(
      cached: [viewer], active: viewer,
      routes: ["GET /api/v1/profiles/age-levels": .json(200, ladder)]
    ) { state in
      let store = ActiveProfileStore.shared
      let savedUnrated = store.unratedLevel
      let topBefore = store.unrestrictedLevel
      await LocalStore.shared.ensureReady()

      // Precondition: unrated 4, a ceiling-4 viewer, one rated and one unrated title.
      store.setUnratedLevel(4)
      await LocalStore.shared.setActiveProfile(store.activeScope)
      await LocalStore.shared.upsertItems([titleItem("t922-rated", level: 4),
                                           titleItem("t922-unrated", level: nil, seq: 2)])
      @MainActor func mine() async -> Set<String> {
        Set(await LocalStore.shared.fetchItems(forLibraryId: "lib_t").map { $0.id }
          .filter { $0.hasPrefix("t922-") })
      }
      #expect(await mine() == ["t922-rated", "t922-unrated"], "precondition: unrated 4 shows it")

      await state.loadAgeLevelsIfNeeded()

      #expect(state.ageLevels.map(\.level) == [1, 2])
      #expect(ActiveProfileStore.shared.unratedLevel == 5)
      #expect(ActiveProfileStore.shared.unrestrictedLevel == topBefore, "the ladder top is untouched")
      #expect(await LocalStore.shared.activeScope.unratedLevel == 5)
      #expect(await mine() == ["t922-rated"], "the unrated title is now above a ceiling of 4")

      await LocalStore.shared.deleteItems(["t922-rated", "t922-unrated"])
      store.setUnratedLevel(savedUnrated)
    }
  }

  /// OC: TASK-922 AC1 · negative: given the device holds an unrated level of 5 and the server's
  /// age-levels body carries no `unratedLevel`, when the ladder loads, then the load fails as a
  /// whole (no labels) and the stored level stays 5, not reset to the fallback.
  /// Red if: a missing `unratedLevel` is defaulted into the store, or the failure path
  /// overwrites what the device already knew.
  @Test func anAgeLadderWithoutAnUnratedLevelChangesNothing() async {
    let noLevel = #"{"levels":[{"level":1,"key":"little","label":"Little kids","movie":["G"],"tv":["TV-Y"]}]}"#
    await host.withAccount(
      routes: ["GET /api/v1/profiles/age-levels": .json(200, noLevel)]
    ) { state in
      let store = ActiveProfileStore.shared
      let savedUnrated = store.unratedLevel
      store.setUnratedLevel(5)

      await state.loadAgeLevelsIfNeeded()

      #expect(state.ageLevels.isEmpty)
      #expect(ActiveProfileStore.shared.unratedLevel == 5)
      store.setUnratedLevel(savedUnrated)
    }
  }

  // MARK: TASK-936 · no chosen viewer fails closed

  /// OC: TASK-936 AC3 · given a cached list [Ryan 4, Maya 2, Leo 3], when no
  /// profile is chosen, then the scope is unchosen (not legacy), sends no header, and its
  /// ceiling is the lowest cached level (2); choosing Leo gives Leo's scope; with NO cached
  /// list it is the legacy scope, unchanged.
  /// Red if: activeScope returns .legacy for "no active id" regardless of the cache (the
  /// original bug), or takes the first/last profile's level instead of the minimum.
  @Test func noActiveProfileIsUnchosenWhenAListIsKnownAndLegacyWhenNot() {
    let defaults = privateDefaults("unchosen")
    let store = ActiveProfileStore(defaults: defaults)

    let none = store.activeScope
    #expect(none.isLegacy)
    #expect(none.isUnchosen == false)
    #expect(none.id == "")
    #expect(none.maxAgeLevel == 4)
    #expect(none.headerValue == nil)

    store.setCachedProfiles([prof("pf_ryan", level: 4, owner: true), prof("pf_maya", level: 2),
                             prof("pf_leo", level: 3)])
    let unchosen = store.activeScope
    #expect(unchosen.isUnchosen)
    #expect(unchosen.isLegacy == false)
    #expect(unchosen.headerValue == nil)
    #expect(unchosen.maxAgeLevel == 2)

    store.setActive(prof("pf_leo", level: 3))
    let chosen = store.activeScope
    #expect(chosen.isUnchosen == false)
    #expect(chosen.id == "pf_leo")
    #expect(chosen.maxAgeLevel == 3)
    #expect(chosen.headerValue == "pf_leo")

    store.setActive(nil)
    #expect(store.activeScope.isUnchosen, "clearing the choice returns to unchosen, not legacy")
  }

  /// OC: TASK-936 AC3 · given titles at levels 1, 2, 3 and one with no level, and a
  /// profile's own progress row, when the store reads under the unchosen scope (ceiling 2),
  /// then only levels 1 and 2 are visible, no title carries progress, Continue Watching is
  /// empty and the resume position is 0; under the real profile the same data is visible.
  /// Red if: the unchosen scope falls to legacy (ceiling/unrated 4: the level-3 and unrated
  /// titles appear), or progress rows of another bucket leak into the unchosen read.
  @Test func unchosenScopeReadsFailClosed() async throws {
    let dir = try scopeTempDir("unchosen-reads")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("a.db"))
    #expect(await store.isUnavailable == false, "precondition: the store opened")
    await store.upsertItems([titleItem("t1", level: 1), titleItem("t2", level: 2),
                             titleItem("t3", level: 3), titleItem("tnull", level: nil)])
    await store.upsertSingleProgress(itemId: "t1", positionSeconds: 600, durationSeconds: 7200,
                                     profileID: "pf_maya")

    await store.setActiveProfile(ProfileScope(id: "pf_maya", maxAgeLevel: 2, unratedLevel: 4))
    #expect(await store.getProgressSeconds(itemId: "t1") == 600, "control: Maya sees her own row")
    #expect(await store.queryRails().continueWatching.map { $0.id } == ["t1"])

    let defaults = privateDefaults("unchosen-reads")
    let cache = ActiveProfileStore(defaults: defaults)
    cache.setCachedProfiles([prof("pf_ryan", level: 4, owner: true), prof("pf_maya", level: 2)])
    await store.setActiveProfile(cache.activeScope)

    let shown = await store.fetchItems(forLibraryId: "lib_t")
    #expect(Set(shown.map { $0.id }) == ["t1", "t2"])
    #expect(shown.count == 2)
    #expect(shown.allSatisfy { $0.progress == nil }, "no progress under the unchosen scope")
    #expect(await store.queryRails().continueWatching.isEmpty)
    #expect(await store.getProgressSeconds(itemId: "t1") == 0)
  }

  /// OC: TASK-936 AC1 · given the unchosen scope is active in LocalStore, when a
  /// progress write or a cursor write arrives under it (a caller that bypassed AppState), then
  /// nothing is stored under any bucket; the same write under a real profile does land.
  /// Red if: LocalStore.refusesWrites is removed from upsertSingleProgress/upsertProgress/
  /// setProgressSeq: a row/cursor appears under "#unchosen".
  @Test func localStoreRefusesWritesFiledUnderTheUnchosenScope() async throws {
    let dir = try scopeTempDir("refuse")
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("a.db")
    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await store.isUnavailable == false, "precondition: the store opened")

    await store.setActiveProfile(.unchosen(maxAgeLevel: 2, unratedLevel: 4))
    await store.upsertSingleProgress(itemId: "w1", positionSeconds: 600, durationSeconds: 7200)
    await store.upsertProgress(["w2": ItemProgress(positionSeconds: 600, durationSeconds: 7200,
                                                    updatedAt: "2026-01-01T00:00:00Z")])
    await store.setProgressSeq(42)

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.storedProfileIDs().isEmpty)
    for bucket in ["", ProfileScope.unchosenID] {
      #expect(await reopened.pendingProgress(profileID: bucket).isEmpty, "bucket '\(bucket)'")
    }
    #expect(await reopened.getSyncCursors(profileID: ProfileScope.unchosenID).progressSeq == 0)

    // Control: the same call under a real profile lands.
    await store.setActiveProfile(ProfileScope(id: "pf_maya", maxAgeLevel: 4, unratedLevel: 4))
    await store.upsertSingleProgress(itemId: "w1", positionSeconds: 600, durationSeconds: 7200)
    let reopened2 = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened2.pendingProgress(profileID: "pf_maya").map(\.itemId) == ["w1"])
  }

  /// OC: TASK-936 AC1 · progress sync is allowed for a chosen profile, held for
  /// legacy until the server is known not to have profiles, and never allowed for unchosen.
  /// Red if: ProfileGate.progressSyncAllowed drops its isUnchosen clause (an unchosen scope is
  /// not legacy, so it would sync with the supported/unsupported answer).
  @Test func progressSyncIsNeverAllowedForTheUnchosenScope() {
    let unchosen = ProfileScope.unchosen(maxAgeLevel: 2, unratedLevel: 4)
    for support in [ProfileSupport.unknown, .supported, .unsupported] {
      #expect(ProfileGate.progressSyncAllowed(scope: unchosen, support: support) == false)
    }
    let chosen = ProfileScope(id: "pf_maya", maxAgeLevel: 2, unratedLevel: 4)
    #expect(ProfileGate.progressSyncAllowed(scope: chosen, support: .supported))
    #expect(ProfileGate.progressSyncAllowed(scope: .legacy(unrestrictedLevel: 4, unratedLevel: 4), support: .unknown) == false)
    #expect(ProfileGate.progressSyncAllowed(scope: .legacy(unrestrictedLevel: 4, unratedLevel: 4), support: .unsupported))
  }

  /// OC: TASK-936 AC1 · given Leo is remembered and the server's fresh list no
  /// longer has him, when the app refreshes, then the scope is unchosen; a recordProgress in
  /// that window writes no local row under any bucket, sends no request, and the owner's
  /// claim of the legacy bucket afterwards hands the owner nothing.
  /// Red if: the vanish branch sets the legacy scope again (the save lands in '' and the claim
  /// moves it to the owner), or recordProgress stops dropping / LocalStore stops refusing.
  @Test func aSaveAfterTheRememberedProfileVanishesNeverReachesTheOwner() async {
    let leo = prof("pf_leo", level: 3)
    await host.withAccount(
      cached: [prof("pf_ryan", level: 4, owner: true), leo], active: leo,
      routes: [
        "GET /api/v1/profiles": profilesReply([ryanJSON, mayaJSON]),
        "POST /api/v1/items/t936-vanish/progress": progressOK,
      ]
    ) { state in
      await LocalStore.shared.ensureReady()
      await LocalStore.shared.deleteProfileData(profileID: "pf_ryan")
      await state.refreshProfiles()
      let scope = await LocalStore.shared.activeScope
      #expect(scope.isUnchosen, "precondition: the window is open")

      await state.recordProgress(itemId: "t936-vanish", positionSeconds: 600, durationSeconds: 7200)

      #expect(postCount() == 0, "nothing uploaded")
      for bucket in ["", ProfileScope.unchosenID, "pf_ryan", "pf_maya"] {
        let rows = await LocalStore.shared.pendingProgress(profileID: bucket)
        #expect(rows.filter { $0.itemId == "t936-vanish" }.isEmpty, "row under '\(bucket)'")
      }
      await LocalStore.shared.claimLegacyRows(ownerID: "pf_ryan")
      let owned = await LocalStore.shared.pendingProgress(profileID: "pf_ryan")
      #expect(owned.filter { $0.itemId == "t936-vanish" }.isEmpty, "the owner was handed the save")
      await LocalStore.shared.deleteProfileData(profileID: "pf_ryan")
    }
  }

  /// OC: TASK-936 AC1 · given Profile A is active, when a save arrives that began
  /// as Profile B (asProfile), then it is dropped: no row for A or B, no upload; a save that
  /// began as A is stored and uploaded; a later setWatched that began as B changes nothing.
  /// Red if: the asProfile check is removed from recordProgress (B's save is filed under A,
  /// 600s appears before the control, the setWatched leaks 7200/7200 and A's resume reads 0).
  @Test func aSaveThatBeganAsAnotherProfileIsDropped() async {
    let a = prof("pf_t936_a", level: 4, owner: true)
    let b = prof("pf_t936_b", level: 2)
    await host.withAccount(
      cached: [a, b], active: a,
      routes: ["POST /api/v1/items/t936-as/progress": progressOK]
    ) { state in
      let store = LocalStore.shared
      await store.ensureReady()
      await store.deleteProfileData(profileID: a.id)
      await store.deleteProfileData(profileID: b.id)
      await store.setActiveProfile(ProfileScope(profile: a))

      await state.recordProgress(itemId: "t936-as", positionSeconds: 600, durationSeconds: 7200,
                                 asProfile: b.id)
      #expect(postCount() == 0)
      #expect(await store.getProgressSeconds(itemId: "t936-as") == 0, "nothing filed under A")
      await store.setActiveProfile(ProfileScope(profile: b))
      #expect(await store.getProgressSeconds(itemId: "t936-as") == 0, "nothing filed under B")

      // Control: a save that began as A is kept and uploaded.
      await store.setActiveProfile(ProfileScope(profile: a))
      await state.recordProgress(itemId: "t936-as", positionSeconds: 600, durationSeconds: 7200,
                                 asProfile: a.id)
      #expect(postCount() == 1)
      #expect(await store.getProgressSeconds(itemId: "t936-as") == 600)

      await state.setWatched(itemId: "t936-as", durationSeconds: 7200, watched: true,
                             asProfile: b.id)
      #expect(postCount() == 1, "the stale watched mark was not uploaded")
      #expect(await store.getProgressSeconds(itemId: "t936-as") == 600, "A's place is untouched")

      await store.deleteProfileData(profileID: a.id)
      await store.deleteProfileData(profileID: b.id)
    }
  }

  // MARK: TASK-935 · age-level backfill

  /// OC: TASK-935 AC1 · given titles stored without a level, when the backfill
  /// check runs, then the item cursor is reset to 0 (a full re-fetch); once the re-fetch has
  /// given every title a level it does nothing and leaves the cursor alone; a store with no
  /// NULL titles never resets.
  /// Red if: the "any NULL level" guard is dropped (the clean store resets), the reset is
  /// skipped (cursor stays 100), or the check keeps firing after the levels arrived.
  @Test func backfillResetsTheCursorOnlyWhileTitlesLackALevel() async throws {
    let dir = try scopeTempDir("backfill")
    defer { try? FileManager.default.removeItem(at: dir) }

    let clean = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("clean.db"))
    await clean.upsertItems([titleItem("c1", level: 2)])
    await clean.setItemSeq(100)
    #expect(await clean.beginAgeLevelBackfillIfNeeded() == false)
    #expect(await clean.getSyncCursors().itemSeq == 100, "a clean catalog keeps its cursor")

    let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("null.db"))
    await store.upsertItems([titleItem("n1", level: nil, seq: 5), titleItem("n2", level: 3, seq: 6)])
    await store.setItemSeq(100)
    #expect(await store.beginAgeLevelBackfillIfNeeded())
    #expect(await store.getSyncCursors().itemSeq == 0)

    // The re-fetch delivers the level; the cursor has advanced again.
    await store.upsertItems([titleItem("n1", level: 2, seq: 5)])
    await store.setItemSeq(100)
    #expect(await store.beginAgeLevelBackfillIfNeeded() == false)
    #expect(await store.getSyncCursors().itemSeq == 100, "done: not re-triggered")
    #expect(await store.ageLevel(forItemID: "n1") == 2)
  }

  /// OC: TASK-935 AC1 · given a re-fetch in progress (cursor 3, the NULL title
  /// still ahead of it), when the check runs again, then it does NOT restart; given a NULL
  /// title BEHIND the cursor (a sync in flight overwrote the reset), then it re-arms, up to 3
  /// resets in all, and then stops for good.
  /// Red if: the mid-re-fetch guard is removed (restart at cursor 3), the re-arm is removed
  /// (second call false), or the cap of 3 is removed (fourth call true).
  @Test func backfillRearmsAStompedResetButNeverRestartsOrLoopsForever() async throws {
    let dir = try scopeTempDir("rearm")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("a.db"))
    await store.upsertItems([titleItem("n1", level: nil, seq: 5)])

    await store.setItemSeq(100)
    #expect(await store.beginAgeLevelBackfillIfNeeded())           // reset 1
    await store.setItemSeq(3)                                      // re-fetch under way, n1 ahead
    #expect(await store.beginAgeLevelBackfillIfNeeded() == false)
    #expect(await store.getSyncCursors().itemSeq == 3, "a resumable re-fetch is not restarted")

    await store.setItemSeq(100)                                    // stomped: n1 now behind
    #expect(await store.beginAgeLevelBackfillIfNeeded())           // reset 2
    await store.setItemSeq(100)
    #expect(await store.beginAgeLevelBackfillIfNeeded())           // reset 3
    await store.setItemSeq(100)
    #expect(await store.beginAgeLevelBackfillIfNeeded() == false, "capped at 3 resets")
    #expect(await store.getSyncCursors().itemSeq == 100)
  }

  /// OC: TASK-935 AC1 · given a title stored without a level and the catalog cursor
  /// at 500, when the app loads the profile list successfully (no user action), then the
  /// cursor is 0 so the next sync re-fetches every title.
  /// Red if: refreshProfiles no longer calls beginAgeLevelBackfillIfNeeded (cursor stays 500).
  @Test func aSuccessfulProfileListArmsTheCatalogRefetchByItself() async {
    await host.withAccount(
      routes: ["GET /api/v1/profiles": profilesReply([ryanJSON])]
    ) { state in
      let store = LocalStore.shared
      await store.ensureReady()
      let savedSeq = await store.getSyncCursors().itemSeq
      #expect(resetSharedBackfillAttempts(), "precondition: attempt counter rewound")
      await store.upsertItems([titleItem("t935-null", level: nil, seq: 10)])
      await store.setItemSeq(500)
      #expect(await store.getSyncCursors().itemSeq == 500, "precondition")

      await state.refreshProfiles()

      #expect(await store.getSyncCursors().itemSeq == 0)
      await store.deleteItems(["t935-null"])
      await store.setItemSeq(savedSeq)
    }
  }

  // MARK: TASK-935 · vanished profiles leave the device

  /// OC: TASK-935 AC2 · given rows (one unsent, one sent) and a cursor for a
  /// deleted profile, plus rows and a cursor for a live one and a legacy '' row, when the
  /// vanished profile's data is deleted, then a FRESH store has none of its rows, unsent
  /// rows or cursor; the live profile's and the '' bucket are intact; storedProfileIDs
  /// never lists ''.
  /// Red if: deleteProfileData leaves the cursor or the outbox rows, touches another
  /// profile, or storedProfileIDs lists '' or misses a cursor-only profile.
  @Test func deletingAVanishedProfileRemovesRowsOutboxAndCursorOnly() async throws {
    let dir = try scopeTempDir("purge")
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("a.db")
    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await store.isUnavailable == false, "precondition: the store opened")

    await store.upsertSingleProgress(itemId: "g1", positionSeconds: 600, durationSeconds: 7200, profileID: "pf_gone")
    await store.upsertSingleProgress(itemId: "g2", positionSeconds: 900, durationSeconds: 7200, profileID: "pf_gone")
    await store.markProgressSynced(itemId: "g2", positionSeconds: 900, durationSeconds: 7200, profileID: "pf_gone")
    await store.setProgressSeq(7, profileID: "pf_gone")
    await store.upsertSingleProgress(itemId: "k1", positionSeconds: 1200, durationSeconds: 7200, profileID: "pf_keep")
    await store.setProgressSeq(9, profileID: "pf_keep")
    await store.upsertSingleProgress(itemId: "l1", positionSeconds: 300, durationSeconds: 7200, profileID: "")
    await store.setProgressSeq(5, profileID: "pf_cursoronly")

    #expect(await store.storedProfileIDs() == ["pf_gone", "pf_keep", "pf_cursoronly"])
    #expect(await store.pendingProgress(profileID: "pf_gone").count == 1, "precondition: an unsent row")

    await store.deleteProfileData(profileID: "pf_gone")
    await store.deleteProfileData(profileID: "pf_cursoronly")
    await store.deleteProfileData(profileID: "")

    let fresh = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await fresh.storedProfileIDs() == ["pf_keep"])
    #expect(await fresh.pendingProgress(profileID: "pf_gone").isEmpty)
    #expect(await fresh.getSyncCursors(profileID: "pf_gone").progressSeq == 0)
    #expect(await fresh.getSyncCursors(profileID: "pf_cursoronly").progressSeq == 0)
    #expect(await fresh.pendingProgress(profileID: "pf_keep").map(\.itemId) == ["k1"])
    #expect(await fresh.getSyncCursors(profileID: "pf_keep").progressSeq == 9)
    #expect(await fresh.pendingProgress(profileID: "").map(\.itemId) == ["l1"], "the '' bucket is never purged")
  }

  /// OC: TASK-935 AC2 · given this device holds rows, an unsent row and a cursor
  /// for a profile the server no longer lists, and for one it still lists, when the fresh list
  /// (which names its owner) arrives, then the missing profile's rows, outbox and cursor are
  /// gone and the listed profile's are untouched.
  /// Red if: refreshProfiles stops purging, or purges only the progress rows (cursor stays),
  /// or purges profiles the list still names.
  @Test func refreshingTheListPurgesProfilesTheServerNoLongerHas() async {
    let keep = plainProfile("pf_t935_keep")
    await host.withAccount(
      routes: ["GET /api/v1/profiles": profilesReply([ryanJSON, keep])]
    ) { state in
      let store = LocalStore.shared
      await store.ensureReady()
      for stale in await store.storedProfileIDs() { await store.deleteProfileData(profileID: stale) }
      await store.upsertSingleProgress(itemId: "t935-g1", positionSeconds: 600, durationSeconds: 7200, profileID: "pf_t935_gone")
      await store.upsertSingleProgress(itemId: "t935-g2", positionSeconds: 900, durationSeconds: 7200, profileID: "pf_t935_gone")
      await store.markProgressSynced(itemId: "t935-g2", positionSeconds: 900, durationSeconds: 7200, profileID: "pf_t935_gone")
      await store.setProgressSeq(7, profileID: "pf_t935_gone")
      await store.upsertSingleProgress(itemId: "t935-k1", positionSeconds: 1200, durationSeconds: 7200, profileID: "pf_t935_keep")
      await store.setProgressSeq(9, profileID: "pf_t935_keep")
      #expect(await store.storedProfileIDs() == ["pf_t935_gone", "pf_t935_keep"], "precondition")

      await state.refreshProfiles()

      #expect(await store.storedProfileIDs() == ["pf_t935_keep"])
      #expect(await store.pendingProgress(profileID: "pf_t935_gone").isEmpty)
      #expect(await store.getSyncCursors(profileID: "pf_t935_gone").progressSeq == 0)
      #expect(await store.pendingProgress(profileID: "pf_t935_keep").map(\.itemId) == ["t935-k1"])
      #expect(await store.getSyncCursors(profileID: "pf_t935_keep").progressSeq == 9)
      await store.deleteProfileData(profileID: "pf_t935_keep")
    }
  }

  /// OC: TASK-935 AC2 · negative: given a list that names no owner (malformed),
  /// when it arrives, then nothing is purged and the legacy '' bucket is left unclaimed.
  /// Red if: the purge runs outside the "list names an owner" branch (a malformed list would
  /// erase every unlisted profile's data).
  @Test func aListWithoutAnOwnerPurgesNothing() async {
    await host.withAccount(
      routes: ["GET /api/v1/profiles": profilesReply([plainProfile("pf_t935_a"), plainProfile("pf_t935_b")])]
    ) { state in
      let store = LocalStore.shared
      await store.ensureReady()
      for stale in await store.storedProfileIDs() { await store.deleteProfileData(profileID: stale) }
      await store.deleteProfileData(profileID: "pf_ryan")
      await store.upsertSingleProgress(itemId: "t935-ng", positionSeconds: 600, durationSeconds: 7200, profileID: "pf_t935_gone")
      await store.setProgressSeq(7, profileID: "pf_t935_gone")
      await store.upsertSingleProgress(itemId: "t935-legacy", positionSeconds: 300, durationSeconds: 7200, profileID: "")

      await state.refreshProfiles()

      #expect(await store.storedProfileIDs() == ["pf_t935_gone"], "nothing purged")
      #expect(await store.getSyncCursors(profileID: "pf_t935_gone").progressSeq == 7)
      #expect(await store.pendingProgress(profileID: "").map(\.itemId) == ["t935-legacy"],
              "legacy rows stay where they are")
      await store.deleteProfileData(profileID: "pf_t935_gone")
      // Remove the legacy row the test planted: claiming it into a throwaway owner and
      // deleting that owner leaves the shared bucket as it was found.
      await store.claimLegacyRows(ownerID: "pf_t935_cleanup")
      await store.deleteProfileData(profileID: "pf_t935_cleanup")
    }
  }
}
