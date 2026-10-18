import Testing
import Foundation
import SQLite3
@testable import DSM_Video

// MARK: - TASK-938 (client half) · FRD-002 client contract
//
// Four things the profile screens' own tests do not reach, each pinned at the layer the user
// (or the server) observes, with expected values written as literals from the FRD:
//
//   1. AC-002-43 / FR-262  a restricted scope's LOCAL reads never return a title above its level
//   2. AC-002-44 / 48      X-DSVideo-Profile is actually SENT on the wire (iOS and tvOS share this)
//   3. AC-002-45 / 45a     a v2 on-device store upgrades into the legacy bucket, loses nothing,
//                          and hands over to the owner only on the explicit claim
//   4. OC-2040 / AC-002-46 the delete confirmation names what is lost and Cancel deletes nothing
//
// Persistence-shaped tests read through the store's public reads against a database file that
// a separate SQLite handle built (1, 3) or through a URLProtocol stub that records requests
// (2, 4); none of them asserts a value it configured itself.

// MARK: Shared helpers

@MainActor
private func ccTempDir(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-cc-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@MainActor
private func ccRemove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

/// A movie row; `level` is the server-sent ageLevel (nil = an older server / unrated).
private func ccItem(_ id: String, level: Int?, library: String = "lib_cc", day: Int = 1) -> ItemSummary {
  ItemSummary(
    id: id, type: "movie", title: "Title \(id)", year: 2020,
    durationSeconds: 7200, addedAt: "2026-01-0\(day)T00:00:00Z",
    libraryId: library, changeSeq: 1, ageLevel: level)
}

// MARK: - 1 · AC-002-43 · local reads never exceed the active profile's level

/// The five levels a catalog can hold: 1...4 and "no level" (nil), which is unrated and must
/// be hidden from every restricted ceiling but visible to the unrestricted one (FR-242).
private let ccLevels: [(suffix: String, level: Int?)] = [
  ("l1", 1), ("l2", 2), ("l3", 3), ("l4", 4), ("lnil", nil),
]

/// One ceiling and the title suffixes it may see. Literals from FRD-002 §6 / FR-242, never
/// derived from the store's own rule.
nonisolated struct CeilingCase: Sendable, CustomTestStringConvertible {
  let maxAgeLevel: Int
  let visible: [String]
  var testDescription: String { "ceiling \(maxAgeLevel)" }

  static let all: [CeilingCase] = [
    CeilingCase(maxAgeLevel: 1, visible: ["l1"]),
    CeilingCase(maxAgeLevel: 2, visible: ["l1", "l2"]),
    CeilingCase(maxAgeLevel: 3, visible: ["l1", "l2", "l3"]),
    // The unrestricted ceiling sees all four levels AND the unrated title.
    CeilingCase(maxAgeLevel: ProfileScope.unrestrictedLevel,
                visible: ["l1", "l2", "l3", "l4", "lnil"]),
  ]
}

private let ccProfileID = "pf_cc"

/// A store holding, per rail, the five level-tagged titles. The three groups never overlap
/// in what they qualify for, so each query is exercised on its own rows:
///   cw-*  started 25% in  -> Continue Watching only
///   rw-*  watched to 97%  -> Recently Watched only
///   ja-*  never started   -> Just Added, and the library listing for "lib_cc_browse"
@MainActor
private func ccSeededStore(dir: URL) async -> LocalStore {
  let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
  var items: [ItemSummary] = []
  for (suffix, level) in ccLevels {
    items.append(ccItem("cw-\(suffix)", level: level, library: "lib_cc_other", day: 1))
    items.append(ccItem("rw-\(suffix)", level: level, library: "lib_cc_other", day: 2))
    items.append(ccItem("ja-\(suffix)", level: level, library: "lib_cc_browse", day: 3))
  }
  await store.upsertItems(items)
  for (suffix, _) in ccLevels {
    await store.upsertSingleProgress(itemId: "cw-\(suffix)", positionSeconds: 1800,
                                     durationSeconds: 7200, profileID: ccProfileID)
    await store.upsertSingleProgress(itemId: "rw-\(suffix)", positionSeconds: 7000,
                                     durationSeconds: 7200, profileID: ccProfileID)
  }
  return store
}

@MainActor
@Suite("AC-002-43 · local reads honour the profile ceiling")
struct LocalReadsHonourTheCeilingTests {

  /// OC: AC-002-43 · given a restricted profile and Continue Watching rows at levels 1..4 plus
  /// one unrated, when the on-device rail is read, then only titles at or below the ceiling
  /// come back (0/1/2/3 and the unrestricted max, with the level above each ceiling present).
  /// Red if: `AND sqlVisibleToScope` is removed from queryContinueWatching (the other queries keep
  /// theirs, so only this test fails), or the unrated rule stops failing closed.
  @Test(arguments: CeilingCase.all)
  func continueWatchingNeverExceedsTheCeiling(_ c: CeilingCase) async throws {
    let dir = try ccTempDir("cw"); defer { ccRemove(dir) }
    let store = await ccSeededStore(dir: dir)
    await store.setActiveProfile(ProfileScope(id: ccProfileID, maxAgeLevel: c.maxAgeLevel))

    let rail = await store.queryRails().continueWatching
    #expect(Set(rail.map(\.id)) == Set(c.visible.map { "cw-" + $0 }))
    #expect(rail.count == c.visible.count, "no title listed twice")
  }

  /// OC: AC-002-43 · same, for Recently Watched.
  /// Red if: `AND sqlVisibleToScope` is removed from queryRecentlyWatched.
  @Test(arguments: CeilingCase.all)
  func recentlyWatchedNeverExceedsTheCeiling(_ c: CeilingCase) async throws {
    let dir = try ccTempDir("rw"); defer { ccRemove(dir) }
    let store = await ccSeededStore(dir: dir)
    await store.setActiveProfile(ProfileScope(id: ccProfileID, maxAgeLevel: c.maxAgeLevel))

    let rail = await store.queryRails().recentlyWatched
    #expect(Set(rail.map(\.id)) == Set(c.visible.map { "rw-" + $0 }))
    #expect(rail.count == c.visible.count)
  }

  /// OC: AC-002-43 · same, for Just Added (the LEFT JOIN rail: a title with no progress for
  /// this profile must still be filtered by level, not passed through the join).
  /// Just Added has no watched filter (FR-088, TASK-986), so the started cw-* and watched rw-*
  /// titles are on it too; the ceiling is what bounds the set (3 groups x visible <= 16).
  /// Red if: `AND sqlVisibleToScope` is removed from queryJustAdded.
  @Test(arguments: CeilingCase.all)
  func justAddedNeverExceedsTheCeiling(_ c: CeilingCase) async throws {
    let dir = try ccTempDir("ja"); defer { ccRemove(dir) }
    let store = await ccSeededStore(dir: dir)
    await store.setActiveProfile(ProfileScope(id: ccProfileID, maxAgeLevel: c.maxAgeLevel))

    let rail = await store.queryRails().justAdded
    #expect(Set(rail.map(\.id)) == Set(c.visible.flatMap { ["cw-" + $0, "rw-" + $0, "ja-" + $0] }))
    #expect(rail.count == c.visible.count * 3)
  }

  /// OC: AC-002-43 · same, for the offline library listing.
  /// Red if: `AND sqlVisibleToScope` is removed from fetchItems(forLibraryId:).
  @Test(arguments: CeilingCase.all)
  func libraryListingNeverExceedsTheCeiling(_ c: CeilingCase) async throws {
    let dir = try ccTempDir("lib"); defer { ccRemove(dir) }
    let store = await ccSeededStore(dir: dir)
    await store.setActiveProfile(ProfileScope(id: ccProfileID, maxAgeLevel: c.maxAgeLevel))

    let listing = await store.fetchItems(forLibraryId: "lib_cc_browse")
    #expect(Set(listing.map(\.id)) == Set(c.visible.map { "ja-" + $0 }))
    #expect(listing.count == c.visible.count)
    let other = await store.fetchItems(forLibraryId: "lib_cc_other")
    #expect(Set(other.map(\.id)) == Set(c.visible.flatMap { ["cw-" + $0, "rw-" + $0] }),
            "the filter applies to every library, and the other library's titles are not lost")
  }

  /// OC: AC-002-43 · a position saved for a title above the ceiling is not handed back as a
  /// resume point (the resume read is a local read too).
  /// Red if: `AND sqlVisibleToScope` is removed from getProgressSeconds.
  @Test(arguments: CeilingCase.all)
  func resumePositionIsHiddenForTitlesAboveTheCeiling(_ c: CeilingCase) async throws {
    let dir = try ccTempDir("resume"); defer { ccRemove(dir) }
    let store = await ccSeededStore(dir: dir)
    await store.setActiveProfile(ProfileScope(id: ccProfileID, maxAgeLevel: c.maxAgeLevel))

    for (suffix, _) in ccLevels {
      let expected = c.visible.contains(suffix) ? 1800 : 0
      #expect(await store.getProgressSeconds(itemId: "cw-\(suffix)") == expected,
              "cw-\(suffix) under ceiling \(c.maxAgeLevel)")
    }
  }

  /// OC: AC-002-43 · negative: switching the SAME store from the unrestricted ceiling to a
  /// restricted one takes effect on the very next read (no cached unfiltered result).
  /// Red if: the rails memoise a result across setActiveProfile.
  @Test func loweringTheCeilingTakesEffectOnTheNextRead() async throws {
    let dir = try ccTempDir("switch"); defer { ccRemove(dir) }
    let store = await ccSeededStore(dir: dir)

    await store.setActiveProfile(ProfileScope(id: ccProfileID, maxAgeLevel: ProfileScope.unrestrictedLevel))
    #expect(await store.queryRails().justAdded.count == 15, "precondition: unrestricted sees all fifteen")

    await store.setActiveProfile(ProfileScope(id: ccProfileID, maxAgeLevel: 1))
    #expect(Set(await store.queryRails().justAdded.map(\.id)) == ["cw-l1", "rw-l1", "ja-l1"])
  }
}

// MARK: - 2 · AC-002-44 / AC-002-48 · the profile header is on the wire

/// A server for `client-contract.stub.test` only. Records every request's profile header.
nonisolated final class ClientContractStub: URLProtocol, @unchecked Sendable {
  struct Recorded: Equatable {
    let method: String
    let path: String
    let body: String
    let profileHeader: String?
  }

  static let host = "client-contract.stub.test"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var routes: [String: (Int, String)] = [:]
  nonisolated(unsafe) private static var log: [Recorded] = []
  static let registered: Bool = {
    URLProtocol.registerClass(ClientContractStub.self)
    return true
  }()

  /// Keys are "METHOD /path". Anything unrouted answers 404 not_found.
  static func reset(_ newRoutes: [String: (Int, String)] = [:]) {
    _ = registered
    lock.lock(); defer { lock.unlock() }
    routes = newRoutes
    log = []
  }
  static var requests: [Recorded] {
    lock.lock(); defer { lock.unlock() }
    return log
  }
  static func count(_ key: String) -> Int {
    requests.filter { "\($0.method) \($0.path)" == key }.count
  }

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let req = request
    var body = ""
    if let stream = req.httpBodyStream {
      stream.open()
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
      }
      stream.close()
      body = String(decoding: data, as: UTF8.self)
    } else if let data = req.httpBody {
      body = String(decoding: data, as: UTF8.self)
    }
    let method = req.httpMethod ?? "GET"
    let path = req.url?.path ?? ""
    Self.lock.lock()
    Self.log.append(Recorded(method: method, path: path, body: body,
                             profileHeader: req.value(forHTTPHeaderField: "X-DSVideo-Profile")))
    let reply = Self.routes["\(method) \(path)"] ?? (404, #"{"error":"not_found"}"#)
    Self.lock.unlock()

    let response = HTTPURLResponse(url: req.url!, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private func ccProfile(_ id: String, _ name: String, level: Int = 2, owner: Bool = false) -> Profile {
  Profile(id: id, name: name, avatar: "cat", maxAgeLevel: level, hasPin: false, isOwner: owner)
}

/// Runs `body` with `profile` as the active profile of a private ActiveProfileStore (a
/// throwaway UserDefaults suite, TASK-925), handed to `body` so it builds its client on it.
/// Nothing in the app group is read or written.
@MainActor
private func ccWithActiveProfile(_ profile: Profile?, _ body: (ActiveProfileStore) async -> Void) async {
  let suite = "ClientContract.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suite) else {
    Issue.record("could not create the throwaway UserDefaults suite")
    return
  }
  defer { defaults.removePersistentDomain(forName: suite) }
  let store = ActiveProfileStore(defaults: defaults)
  store.setActive(profile)
  await body(store)
}

/// Holds ProfileStateGate for a whole test: ClientContractStub's route table and its request
/// log are process-wide, and Swift Testing runs suites in parallel (ProfileScopeFixTests,
/// ProfileScreensServerTests and DeleteConfirmationTests use stubs too). Reset, exercise and
/// read-back must all happen inside it.
@MainActor
private func ccGated(_ work: () async -> Void) async {
  await ProfileStateGate.shared.run(work)
}

@MainActor
@Suite("AC-002-44/48 · X-DSVideo-Profile is sent", .serialized)
struct ProfileHeaderOnTheWireTests {
  private let watchlistRoute: [String: (Int, String)] = ["GET /api/v1/watchlist": (200, #"{"items":[]}"#)]
  /// A client whose `.activeProfile` header reads `store`, not the app's shared one.
  private func api(_ store: ActiveProfileStore) -> APIClient {
    var client = APIClient(baseURL: URL(string: "http://\(ClientContractStub.host)")!, token: "tok")
    client.profileStore = store
    return client
  }

  private func sentHeaders() -> [String?] {
    ClientContractStub.requests.filter { $0.path == "/api/v1/watchlist" }.map(\.profileHeader)
  }

  /// OC: AC-002-44, AC-002-48 · given Maya is the active profile, when the app makes an
  /// ordinary request, then that request carries X-DSVideo-Profile: pf_maya.
  /// Red if: APIClient stops calling ActiveProfileStore.setHeader (or reads the wrong id).
  @Test func anActiveProfileIsNamedOnEveryRequest() async throws {
    await ccGated {
      ClientContractStub.reset(watchlistRoute)
      await ccWithActiveProfile(ccProfile("pf_maya", "Maya")) { store in
        _ = try? await api(store).watchlist()
      }
      #expect(sentHeaders() == ["pf_maya"])
    }
  }

  /// OC: AC-002-44 · negative: with no active profile (a server that predates profiles, or
  /// the legacy scope) the header is ABSENT, not empty.
  /// Red if: APIClient sends the header (or an empty value) when there is no profile.
  @Test func noActiveProfileSendsNoHeader() async throws {
    await ccGated {
      ClientContractStub.reset(watchlistRoute)
      await ccWithActiveProfile(nil) { store in
        _ = try? await api(store).watchlist()
      }
      #expect(ClientContractStub.count("GET /api/v1/watchlist") == 1, "precondition: the request was made")
      #expect(sentHeaders() == [nil])
    }
  }

  /// OC: AC-002-44 · given a client built while Maya was active, when the user switches to
  /// Leo before the next request, then the request names Leo: the id is read when the request
  /// is built, never frozen into the client.
  /// Red if: APIClient captures the profile id at construction.
  @Test func aProfileSwitchIsPickedUpByAnExistingClient() async throws {
    await ccGated {
      ClientContractStub.reset(watchlistRoute)
      await ccWithActiveProfile(ccProfile("pf_maya", "Maya")) { store in
        let client = api(store)
        _ = try? await client.watchlist()
        store.setActive(ccProfile("pf_leo", "Leo", level: 3))
        _ = try? await client.watchlist()
      }
      #expect(sentHeaders() == ["pf_maya", "pf_leo"])
    }
  }

  /// OC: AC-002-44 · given Maya is active but work was pinned to Leo (progress sync, the
  /// outbox), when it sends, then it names Leo, not the current profile.
  /// Red if: `pinned(to:)` stops overriding the active profile.
  @Test func aPinnedClientSendsThePinnedIdNotTheActiveOne() async throws {
    await ccGated {
      ClientContractStub.reset(watchlistRoute)
      await ccWithActiveProfile(ccProfile("pf_maya", "Maya")) { store in
        _ = try? await api(store).pinned(to: "pf_leo").watchlist()
      }
      #expect(sentHeaders() == ["pf_leo"])
    }
  }

  /// OC: AC-002-44 · pinning to nil while a profile is active sends NO header (the profile
  /// routes, which must work whoever is active).
  /// Red if: pinned(nil) falls back to the active profile.
  @Test func pinningToNothingSendsNoHeaderEvenWhenAProfileIsActive() async throws {
    await ccGated {
      ClientContractStub.reset(watchlistRoute)
      await ccWithActiveProfile(ccProfile("pf_maya", "Maya")) { store in
        _ = try? await api(store).pinned(to: nil).watchlist()
      }
      #expect(ClientContractStub.count("GET /api/v1/watchlist") == 1, "precondition: the request was made")
      #expect(sentHeaders() == [nil])
    }
  }

  /// OC: AC-002-44 · the profile-management routes send no header even with a profile active
  /// (a stale id from a deleted profile must not lock the picker out).
  /// Red if: profiles() stops pinning to nil.
  @Test func theProfileListRouteSendsNoHeader() async throws {
    await ccGated {
      ClientContractStub.reset(["GET /api/v1/profiles": (200, #"{"maxProfiles":4,"activeProfileId":null,"profiles":[]}"#)])
      await ccWithActiveProfile(ccProfile("pf_maya", "Maya")) { store in
        _ = try? await api(store).profiles()
      }
      #expect(ClientContractStub.count("GET /api/v1/profiles") == 1)
      #expect(ClientContractStub.requests.first?.profileHeader == nil)
    }
  }

  /// OC: AC-002-44 · requests the app builds by hand (downloads, trickplay, and the shared
  /// store the Top Shelf extension and App Intents read) carry the same header, and follow a
  /// switch. Uses a private defaults suite so the shared store is untouched.
  /// Red if: setHeader/applyHeader stops writing the header, or reads a stale id.
  @Test func handBuiltRequestsCarryTheActiveProfileAndFollowASwitch() throws {
    let suite = "cc-header-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ActiveProfileStore(defaults: defaults)
    let url = URL(string: "http://\(ClientContractStub.host)/file")!

    var none = URLRequest(url: url)
    store.applyHeader(to: &none)
    #expect(none.value(forHTTPHeaderField: "X-DSVideo-Profile") == nil, "no profile, no header")

    store.setActive(ccProfile("pf_maya", "Maya"))
    var maya = URLRequest(url: url)
    store.applyHeader(to: &maya)
    #expect(maya.value(forHTTPHeaderField: "X-DSVideo-Profile") == "pf_maya")

    store.setActive(ccProfile("pf_leo", "Leo", level: 3))
    var leo = URLRequest(url: url)
    store.applyHeader(to: &leo)
    #expect(leo.value(forHTTPHeaderField: "X-DSVideo-Profile") == "pf_leo")

    store.setActive(nil)
    var cleared = URLRequest(url: url)
    store.applyHeader(to: &cleared)
    #expect(cleared.value(forHTTPHeaderField: "X-DSVideo-Profile") == nil, "sign-out/clear removes it again")
  }
}

// MARK: - 3 · AC-002-45 / 45a · upgrading a v2 on-device store

/// Builds, with a SEPARATE SQLite handle, the database an app build from before profiles left
/// on the device: user_version 2, `progress` keyed by item alone with a pending_sync flag, no
/// age_level on items, a single global `progress_seq` cursor. Nothing here goes through
/// LocalStore, so the migration cannot have shaped its own input.
private func ccWriteV2Database(at url: URL, progressRows: [(item: String, pos: Int, pending: Int)],
                               itemSeq: Int, progressSeq: Int) throws {
  var handle: OpaquePointer?
  guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
    throw NSError(domain: "cc", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create v2 fixture"])
  }
  defer { sqlite3_close(db) }
  var sql = """
    CREATE TABLE items (
      id TEXT PRIMARY KEY, library_id TEXT NOT NULL, type TEXT NOT NULL, title TEXT NOT NULL,
      year INTEGER, duration_seconds INTEGER, added_at TEXT NOT NULL, rating REAL,
      poster_image_id TEXT, backdrop_image_id TEXT, show_name TEXT, show_folder_id TEXT,
      season_number INTEGER, episode_number INTEGER, change_seq INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE progress (
      item_id TEXT PRIMARY KEY, position_seconds INTEGER NOT NULL, duration_seconds INTEGER NOT NULL,
      updated_at TEXT NOT NULL, pending_sync INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE sync_cursors (key TEXT PRIMARY KEY, value INTEGER NOT NULL DEFAULT 0);
    INSERT INTO sync_cursors(key, value) VALUES ('item_seq', \(itemSeq));
    INSERT INTO sync_cursors(key, value) VALUES ('progress_seq', \(progressSeq));
    """
  for (n, row) in progressRows.enumerated() {
    sql += """
      INSERT INTO items(id, library_id, type, title, added_at, duration_seconds, change_seq)
        VALUES ('\(row.item)', 'lib_v2', 'movie', 'Old \(row.item)', '2025-01-0\(n + 1)T00:00:00Z', 7200, 1);
      INSERT INTO progress(item_id, position_seconds, duration_seconds, updated_at, pending_sync)
        VALUES ('\(row.item)', \(row.pos), 7200, '2025-02-0\(n + 1)T00:00:00Z', \(row.pending));
      """
  }
  sql += "PRAGMA user_version = 2;"
  var err: UnsafeMutablePointer<CChar>?
  guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
    let msg = err.map { String(cString: $0) } ?? "unknown"
    sqlite3_free(err)
    throw NSError(domain: "cc", code: 2, userInfo: [NSLocalizedDescriptionKey: "v2 fixture SQL: \(msg)"])
  }
}

@MainActor
@Suite("AC-002-45/45a · v2 store upgrade")
struct V2UpgradeTests {
  // Three positions, one still unsent (pending), two already accepted by the server.
  private static let rows: [(item: String, pos: Int, pending: Int)] = [
    ("mv-a", 600, 1), ("mv-b", 1200, 0), ("mv-c", 1800, 0),
  ]
  private static let oldIDs: Set<String> = ["mv-a", "mv-b", "mv-c"]

  private func upgradedStore(_ dir: URL) async throws -> LocalStore {
    let url = dir.appendingPathComponent("dsreel.db")
    try ccWriteV2Database(at: url, progressRows: Self.rows, itemSeq: 77, progressSeq: 42)
    let store = await LocalStore.makeForTesting(databaseURL: url)
    try #require(await store.isUnavailable == false, "the v2 file must open and migrate")
    return store
  }

  /// OC: AC-002-45 · given a device with three stored positions (one unsent), when the app
  /// is upgraded, then every position is still there, none lost or duplicated, under the
  /// legacy bucket (no profile yet), and the unsent one is still queued for upload.
  /// Red if: migrateToV3 drops rows, writes them to another bucket, or resets pending_sync.
  @Test func everyStoredPositionSurvivesIntoTheLegacyBucketWithItsPendingFlag() async throws {
    let dir = try ccTempDir("v2-legacy"); defer { ccRemove(dir) }
    let store = try await upgradedStore(dir)

    #expect(await store.getProgressSeconds(itemId: "mv-a") == 600)
    #expect(await store.getProgressSeconds(itemId: "mv-b") == 1200)
    #expect(await store.getProgressSeconds(itemId: "mv-c") == 1800)
    let continueIDs = await store.queryRails().continueWatching.map(\.id)
    #expect(Set(continueIDs) == Self.oldIDs)
    #expect(continueIDs.count == 3, "three rows in, three rows out")

    let pending = await store.pendingProgress(profileID: "")
    #expect(pending.map(\.itemId) == ["mv-a"], "only the unsent position stays queued")
    #expect(pending.first?.positionSeconds == 600)
    #expect(await store.pendingProgressCount(profileID: "") == 1)
  }

  /// OC: AC-002-45 · the global progress cursor becomes the legacy bucket's cursor and the
  /// catalog cursor is untouched, so the upgrade neither re-downloads the library nor loses
  /// its place in the progress stream.
  /// Red if: the `progress_seq` -> `progress_seq:` rename is removed (legacy cursor reads 0).
  @Test func theGlobalProgressCursorBecomesTheLegacyCursor() async throws {
    let dir = try ccTempDir("v2-cursor"); defer { ccRemove(dir) }
    let store = try await upgradedStore(dir)

    let legacy = await store.getSyncCursors(profileID: "")
    #expect(legacy.progressSeq == 42)
    #expect(legacy.itemSeq == 77)
    #expect(await store.getSyncCursors(profileID: "pf_owner").progressSeq == 0,
            "no other profile inherits the old cursor")
  }

  /// OC: AC-002-45a · given the upgrade happened but the profile list has not loaded (or
  /// failed to), when a restricted profile, or any profile that is not the owner, reads, then
  /// no position appears and none is queued under them.
  /// Red if: migrated rows land under a real profile id, or reads ignore profile_id.
  @Test func beforeTheOwnerClaimsThemNoProfileSeesTheOldPositions() async throws {
    let dir = try ccTempDir("v2-unclaimed"); defer { ccRemove(dir) }
    let store = try await upgradedStore(dir)

    for scope in [ProfileScope(id: "pf_kid", maxAgeLevel: 2),
                  ProfileScope(id: "pf_teen", maxAgeLevel: ProfileScope.unrestrictedLevel)] {
      await store.setActiveProfile(scope)
      for id in ["mv-a", "mv-b", "mv-c"] {
        #expect(await store.getProgressSeconds(itemId: id) == 0, "\(id) under \(scope.id)")
      }
      let rails = await store.queryRails()
      #expect(rails.continueWatching.isEmpty, "\(scope.id) continue watching")
      #expect(rails.recentlyWatched.isEmpty, "\(scope.id) recently watched")
      #expect(await store.pendingProgressCount(profileID: scope.id) == 0)
    }
  }

  /// OC: AC-002-45a · given pre-upgrade items that have no age level, a restricted profile
  /// sees none of them in any local read (unrated fails closed), while the legacy/unrestricted
  /// scope still sees them; and a title synced AFTER the upgrade (with a level) is stored,
  /// proving the age_level column exists on the upgraded table.
  /// Red if: the upgrade leaves old items visible to a restricted scope, or does not add
  /// age_level (the post-upgrade upsert would fail and the new title would be missing).
  @Test func upgradedItemsWithoutALevelAreHiddenFromRestrictedProfilesAndNewOnesAreStored() async throws {
    let dir = try ccTempDir("v2-items"); defer { ccRemove(dir) }
    let store = try await upgradedStore(dir)

    await store.setActiveProfile(ProfileScope(id: "pf_kid", maxAgeLevel: 2))
    #expect(await store.queryRails().justAdded.isEmpty)
    #expect(await store.fetchItems(forLibraryId: "lib_v2").isEmpty)

    await store.upsertItems([ccItem("mv-new", level: 2, library: "lib_v2")])
    #expect(await store.fetchItems(forLibraryId: "lib_v2").map(\.id) == ["mv-new"],
            "the kid sees the new level-2 title and still none of the unrated ones")

    await store.setActiveProfile(.legacy)
    #expect(Set(await store.fetchItems(forLibraryId: "lib_v2").map(\.id)) == Self.oldIDs.union(["mv-new"]))
  }

  /// OC: AC-002-45 · given the owner's id becomes known, when the legacy rows are claimed,
  /// then the owner has all three positions with the unsent one still queued, the legacy
  /// bucket is empty, and a restricted profile still sees none.
  /// Red if: claimLegacyRows does not move rows, moves them to the wrong id, clears
  /// pending_sync, or leaves a copy behind.
  @Test func claimingMovesTheOldPositionsToTheOwnerAndToNoOneElse() async throws {
    let dir = try ccTempDir("v2-claim"); defer { ccRemove(dir) }
    let store = try await upgradedStore(dir)

    await store.claimLegacyRows(ownerID: "pf_owner")

    await store.setActiveProfile(ProfileScope(id: "pf_owner", maxAgeLevel: ProfileScope.unrestrictedLevel))
    #expect(await store.getProgressSeconds(itemId: "mv-a") == 600)
    #expect(await store.getProgressSeconds(itemId: "mv-b") == 1200)
    #expect(await store.getProgressSeconds(itemId: "mv-c") == 1800)
    let ownerIDs = await store.queryRails().continueWatching.map(\.id)
    #expect(Set(ownerIDs) == Self.oldIDs)
    #expect(ownerIDs.count == 3)
    #expect(await store.pendingProgress(profileID: "pf_owner").map(\.itemId) == ["mv-a"])

    #expect(await store.pendingProgressCount(profileID: "") == 0, "nothing left in the legacy bucket")
    await store.setActiveProfile(.legacy)
    #expect(await store.getProgressSeconds(itemId: "mv-a") == 0)

    await store.setActiveProfile(ProfileScope(id: "pf_kid", maxAgeLevel: 2))
    #expect(await store.getProgressSeconds(itemId: "mv-a") == 0)
    #expect(await store.queryRails().continueWatching.isEmpty)
  }

  /// OC: AC-002-45 · the claim survives a restart: a fresh store on the same file still has
  /// the owner's three positions (the hand-over was committed, not held in memory).
  /// Red if: claimLegacyRows does not commit.
  @Test func theHandOverIsDurable() async throws {
    let dir = try ccTempDir("v2-durable"); defer { ccRemove(dir) }
    let store = try await upgradedStore(dir)
    await store.claimLegacyRows(ownerID: "pf_owner")

    let reopened = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
    await reopened.setActiveProfile(ProfileScope(id: "pf_owner", maxAgeLevel: ProfileScope.unrestrictedLevel))
    #expect(await reopened.getProgressSeconds(itemId: "mv-c") == 1800)
    #expect(await reopened.pendingProgressCount(profileID: "pf_owner") == 1)
  }

  /// OC: AC-002-45 · boundary: a v2 store with zero positions still upgrades (nothing to
  /// move is not an error) and keeps its cursors.
  /// Red if: the migration's copied-count check treats zero rows as a failure and rolls back.
  @Test func aV2StoreWithNoPositionsUpgradesCleanly() async throws {
    let dir = try ccTempDir("v2-empty"); defer { ccRemove(dir) }
    let url = dir.appendingPathComponent("dsreel.db")
    try ccWriteV2Database(at: url, progressRows: [], itemSeq: 5, progressSeq: 9)

    let store = await LocalStore.makeForTesting(databaseURL: url)
    #expect(await store.isUnavailable == false)
    #expect(await store.pendingProgressCount(profileID: "") == 0)
    #expect(await store.getSyncCursors(profileID: "").progressSeq == 9)
    #expect(await store.getSyncCursors(profileID: "").itemSeq == 5)
  }
}

// MARK: - 4 · OC-2040 / AC-002-46 · delete confirmation

@MainActor
@Suite("OC-2040 · delete confirmation", .serialized)
struct DeleteConfirmationTests {
  private let ryan = #"{"id":"pf_ryan","name":"Ryan","avatar":"moon","maxAgeLevel":4,"hasPin":true,"isOwner":true}"#
  private let maya = #"{"id":"pf_maya","name":"Maya","avatar":"cat","maxAgeLevel":2,"hasPin":false,"isOwner":false}"#
  private var mayaProfile: Profile { ccProfile("pf_maya", "Maya") }
  private var ryanProfile: Profile { ccProfile("pf_ryan", "Ryan", level: 4, owner: true) }

  /// A signed-in AppState pointed at the stub, over its own profile store and catalog
  /// (TASK-925). Gated only because the stub's route table is process-wide and the other
  /// stub-backed suites run in parallel with this one.
  private func withAccount(routes: [String: (Int, String)], _ body: (AppState) async -> Void) async {
    await ProfileStateGate.shared.run {
      ClientContractStub.reset(routes)
      await withIsolatedAppState(cached: [ryanProfile, mayaProfile], active: ryanProfile,
                                 stubHost: ClientContractStub.host, body)
    }
  }

  /// OC: AC-002-46, OC-2040 · given a profile named Maya, when the owner chooses Delete, then
  /// the confirmation title names her and the message says her history, progress and
  /// watchlist will be permanently deleted and that videos and other profiles are untouched.
  /// Red if: the title or ProfileText.deleteConfirmation wording loses what is deleted, or the
  /// view stops using the confirmation model.
  @Test func theConfirmationNamesTheProfileAndWhatIsLost() {
    let confirmation = ProfileDeleteConfirmation(profile: mayaProfile)
    #expect(confirmation.title == "Delete Maya?")
    #expect(confirmation.message
      == "Maya's watch history, progress and watchlist will be permanently deleted. "
      + "Your videos and other profiles are not affected. This can't be undone.")
    #expect(confirmation.message.contains("permanently deleted"))
  }

  /// OC: AC-002-46 · boundary: no profile resolved (should not happen) still warns, with a
  /// generic name, rather than showing an empty or "nil" message.
  /// Red if: the nil fallback is dropped.
  @Test func withoutAProfileTheConfirmationStillWarns() {
    let confirmation = ProfileDeleteConfirmation(profile: nil)
    #expect(confirmation.title == "Delete profile?")
    #expect(confirmation.message.hasPrefix("This profile's watch history, progress and watchlist will be permanently deleted."))
  }

  /// OC: OC-2040 · given the confirmation is showing for Maya, when the owner chooses Cancel,
  /// then NO request reaches the server and Maya is still listed with the count unchanged.
  /// Red if: the Cancel choice deletes (or contacts the server in any way).
  @Test func cancelDeletesNothing() async {
    await withAccount(routes: [
      "DELETE /api/v1/profiles/pf_maya": (200, #"{"ok":true}"#),
      "GET /api/v1/profiles": (200, #"{"maxProfiles":4,"activeProfileId":null,"profiles":[\#(ryan)]}"#),
    ]) { state in
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_maya"], "precondition: both listed")

      let outcome = await ProfileDeleteConfirmation(profile: mayaProfile)
        .perform(.cancel, on: state, ownerPin: "0420")

      #expect(outcome == nil, "cancel produces no result: nothing was attempted")
      #expect(ClientContractStub.requests.isEmpty, "cancel sends no request at all")
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_maya"], "Maya still listed, count unchanged")
    }
  }

  /// OC: OC-2040 · the paired positive: confirming the SAME dialog does delete, naming Maya
  /// only and sending the owner PIN, and the list afterwards no longer holds her. This is what
  /// proves the cancel test above would have noticed a delete.
  /// Red if: confirm stops calling the delete route, deletes the wrong id, or omits the PIN.
  @Test func confirmingDeletesOnlyThatProfileWithTheOwnerPin() async {
    await withAccount(routes: [
      "DELETE /api/v1/profiles/pf_maya": (200, #"{"ok":true}"#),
      "GET /api/v1/profiles": (200, #"{"maxProfiles":4,"activeProfileId":null,"profiles":[\#(ryan)]}"#),
    ]) { state in
      let outcome = await ProfileDeleteConfirmation(profile: mayaProfile)
        .perform(.delete, on: state, ownerPin: "0420")

      if case .failure? = outcome { Issue.record("confirmed delete reported failure") }
      #expect(outcome != nil)
      let deletes = ClientContractStub.requests.filter { $0.method == "DELETE" }
      #expect(deletes.count == 1)
      #expect(deletes.first?.path == "/api/v1/profiles/pf_maya")
      #expect(deletes.first?.body == #"{"ownerPin":"0420"}"#)
      #expect(state.profiles.map(\.id) == ["pf_ryan"], "Maya gone, the owner survives")
    }
  }

  /// OC: OC-2040 · negative: a confirmed delete the server refuses (wrong owner PIN) reports
  /// the failure and leaves the list as it was.
  /// Red if: a refused delete is reported as success or removes the profile locally.
  @Test func aRefusedDeleteLeavesTheProfileListed() async {
    await withAccount(routes: [
      "DELETE /api/v1/profiles/pf_maya": (403, #"{"error":"owner_pin_incorrect"}"#),
    ]) { state in
      let outcome = await ProfileDeleteConfirmation(profile: mayaProfile)
        .perform(.delete, on: state, ownerPin: "0000")

      if case .success? = outcome { Issue.record("refused delete reported success") }
      #expect(outcome != nil)
      #expect(ClientContractStub.count("DELETE /api/v1/profiles/pf_maya") == 1)
      #expect(state.profiles.map(\.id) == ["pf_ryan", "pf_maya"])
    }
  }
}
