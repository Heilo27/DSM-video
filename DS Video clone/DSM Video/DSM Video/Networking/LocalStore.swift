import Foundation
import SQLite3
import os.log

// SQLITE_TRANSIENT is a C function pointer that Swift can't import directly.
// nonisolated(unsafe) prevents the compiler from inferring @MainActor on this constant.
private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - SyncCursors

struct SyncCursors: Sendable {
  var itemSeq: Int
  var progressSeq: Int
}

// MARK: - HomeRails

struct HomeRails: Sendable {
  var continueWatching: [ItemSummary]
  var justAdded: [ItemSummary]
  var recentlyWatched: [ItemSummary]
}

// MARK: - LocalStore

/// Actor wrapping a SQLite database on-device.
/// Replaces the JSON-file HomeCache with an indexed, queryable store.
/// All public methods are nonisolated-safe to call from any context.
actor LocalStore {
  static let shared: LocalStore = {
    let store = LocalStore(scope: ActiveProfileStore.shared.activeScope)
    Task { await store.setupLogged() }
    return store
  }()

  /// The profile every read is filtered by and every progress write defaults to (FR-233,
  /// FR-262). Seeded from ActiveProfileStore at launch; changed only by setActiveProfile.
  private(set) var activeScope: ProfileScope

  /// Switches the profile reads are filtered by. AppState calls this on every profile
  /// change, BEFORE reloading anything, so no read can return the previous profile's rows.
  func setActiveProfile(_ scope: ProfileScope) {
    activeScope = scope
  }

  private var db: OpaquePointer?
  private var isReady: Bool = false

  /// Why the store could not be opened, if it could not. Non-nil means every read returns
  /// empty and every write is discarded — the caller is NOT persisting anything.
  ///
  /// Exists because the failure was previously invisible: `isReady` was set even when
  /// `setup()` threw, so callers saw a healthy store that silently dropped their writes.
  private var setupFailure: Error?

  /// True when a corrupt database was quarantined and replaced with a fresh one on this
  /// launch. The store WORKS — it is simply empty, and will refill from the server on the next
  /// delta sync. Distinct from `isUnavailable`, which means nothing will persist at all.
  private(set) var didRecoverFromCorruption = false

  /// Asks SQLite directly whether the file is corrupt, rather than inferring it from a failed
  /// open. `sqlite3_open` is lazy and returns OK against a damaged file; the damage only
  /// surfaces when a statement touches the pages, which is why the failure appears in migrate()
  /// and why a plain retry never helps.
  ///
  /// Uses `quick_check`, not `integrity_check`: the full check walks every page and can take
  /// many seconds on a large library, and this runs on the launch path. `quick_check` skips
  /// the index-content verification but still catches the structural damage that makes a file
  /// unopenable, which is the case being handled.
  private func databaseIsCorrupt() -> Bool {
    var probe: OpaquePointer?
    let path = resolvedDatabaseURL().path
    guard sqlite3_open_v2(path, &probe, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let probe else {
      // Cannot even open it read-only. If the file exists, treat that as corrupt; if it does
      // not, the failure was something else (a missing directory, a permissions problem) and
      // quarantining would destroy nothing useful but also fix nothing.
      if probe != nil { sqlite3_close(probe) }
      return FileManager.default.fileExists(atPath: path)
    }
    defer { sqlite3_close(probe) }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(probe, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK else {
      return true   // cannot even prepare the check — damaged
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW,
          let cText = sqlite3_column_text(stmt, 0) else {
      return true
    }
    let result = String(cString: cText)
    if result != "ok" {
      log.error("PRAGMA quick_check reports: \(result)")
      return true
    }
    return false
  }

  /// Moves the corrupt database and its WAL/SHM sidecars aside, timestamped.
  ///
  /// QUARANTINE, never delete. The file may be partially salvageable by hand, it is evidence
  /// for diagnosing what corrupted it, and deleting user data to recover from a read failure is
  /// precisely the instinct that causes the losses this whole class of bug is about. The cache
  /// itself is reconstructible, but that is a reason the REBUILD is safe — not a reason to
  /// destroy the original.
  private func quarantineCorruptDatabase() -> Bool {
    let fm = FileManager.default
    let dbURL = resolvedDatabaseURL()
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let dir = dbURL.deletingLastPathComponent()

    // The main file must move for the rebuild to get a clean path. The sidecars are
    // best-effort: a stale -wal left beside a NEW database would be applied to it on open,
    // which is its own corruption, so they are moved too — but failing to move one is not
    // fatal, because SQLite discards a WAL whose header does not match the database.
    let main = dbURL
    let quarantinedMain = dir.appendingPathComponent("dsreel.corrupt-\(stamp).db")
    do {
      try fm.moveItem(at: main, to: quarantinedMain)
      log.error("quarantined corrupt database to \(quarantinedMain.lastPathComponent)")
    } catch {
      log.error("could not quarantine corrupt database: \(error.localizedDescription)")
      return false
    }
    for suffix in ["-wal", "-shm"] {
      let side = dir.appendingPathComponent("dsreel.db\(suffix)")
      guard fm.fileExists(atPath: side.path) else { continue }
      try? fm.moveItem(at: side, to: dir.appendingPathComponent("dsreel.corrupt-\(stamp).db\(suffix)"))
    }
    return true
  }

  /// True when the on-disk store could not be opened and local persistence is dead.
  /// Callers that own user-visible state should surface this rather than pretend a write
  /// landed — a resume position that silently fails to save reads to the user as data loss.
  var isUnavailable: Bool {
    setupFailure != nil || db == nil
  }

  /// Human-readable reason the store is unavailable, for a user-facing banner.
  var unavailableReason: String? {
    guard isUnavailable else { return nil }
    return "Your watch history can't be saved on this device right now. Playback still works, "
      + "and positions you set will sync to the server when it's reachable."
  }

  /// What to tell the user after a corruption recovery, or nil if none happened.
  ///
  /// Deliberately separate from `unavailableReason`: the store WORKS after a recovery, it is
  /// just empty. Reporting that as "can't be saved" would be false, and the user would not
  /// understand why their library repopulates a moment later.
  var recoveryNotice: String? {
    guard didRecoverFromCorruption else { return nil }
    return "This device's offline library was damaged and has been rebuilt. "
      + "Your videos will reappear as they sync from your server."
  }
  private var readyContinuations: [CheckedContinuation<Void, Never>] = []
  private let log = Logger(subsystem: "com.dsm.dsvideo", category: "LocalStore")
  // Shared formatter — ISO8601DateFormatter is expensive to allocate; reuse per instance (TASK-427).
  private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  /// Overrides where the SQLite file lives. `nil` means the production location
  /// (`<Documents>/dsreel.db`), which is what `shared` uses.
  ///
  /// TEST SEAM (R4 gap closure). `LocalStore` is an actor singleton writing to one fixed
  /// path in the app container, so any test exercising a write, a delete, or the
  /// unavailable-store path would share that one file with every other test — order
  /// dependent, and a `clearAll` test would wipe the developer's own library on a device
  /// run. Injecting the URL gives each test its own temp database; production behaviour is
  /// unchanged because `shared` passes nothing and `openDatabase()` falls back to the exact
  /// same Documents path it always computed.
  ///
  /// Deliberately NOT `#if DEBUG`: the shipping code path must be the code path under test.
  private let databaseURLOverride: URL?

  private init(databaseURLOverride: URL? = nil, scope: ProfileScope = .legacy) {
    self.databaseURLOverride = databaseURLOverride
    self.activeScope = scope
  }

  /// TEST SEAM (R4). Builds a store backed by `url` instead of the app container, and
  /// completes setup before returning so callers need no `ensureReady()` dance.
  /// Pass a URL inside a per-test temp directory.
  static func makeForTesting(databaseURL: URL) async -> LocalStore {
    let store = LocalStore(databaseURLOverride: databaseURL)
    await store.setupLogged()
    return store
  }

  /// TEST SEAM (R4). A store whose open is guaranteed to FAIL, for exercising the
  /// unavailable-store detection that `isUnavailable` exists to provide. The URL points
  /// into a directory that does not exist, which is what a real failed open looks like.
  static func makeUnopenableForTesting() async -> LocalStore {
    let dead = URL(fileURLWithPath: "/dev/null/definitely-not-a-directory/dsreel.db")
    let store = LocalStore(databaseURLOverride: dead)
    await store.setupLogged()
    return store
  }

  // Called once at startup. Using a separate async method avoids the actor-isolation
  // restriction on calling isolated methods from a synchronous init.
  // setupLogged wraps setup() so errors are logged rather than silently swallowed.
  func setupLogged() async {
    // Read the legacy JSON cache file off-actor before acquiring the actor for setup
    // so the blocking Data(contentsOf:) call doesn't hold the actor thread (TASK-506).
    // A store with an injected URL (R4 test seam) is not the app's store and must not adopt
    // — or delete — the app container's legacy cache file.
    let usesProductionLocation = databaseURLOverride == nil
    let jsonCacheData: (url: URL, data: Data)? = await Task.detached(priority: .utility) {
      guard usesProductionLocation,
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
      let jsonURL = docs.appendingPathComponent("dsReel-homeCache.json")
      guard FileManager.default.fileExists(atPath: jsonURL.path),
            let data = try? Data(contentsOf: jsonURL) else { return nil }
      return (url: jsonURL, data: data)
    }.value
    do {
      try setup(jsonCacheData: jsonCacheData)
      setupFailure = nil
    } catch {
      // A failed setup leaves the store unusable: every write path here short-circuits and the
      // outbox can only replay rows that reached SQLite, so a lost write is lost for good and
      // reads to the user as a server bug.
      //
      // (Note for the next reader: an earlier comment here claimed a failed open leaves `db`
      // nil and that `guard let db` therefore short-circuits. That is NOT true —
      // `sqlite3_open` leaves a NON-NIL handle even when it fails, and the open is lazy, so
      // the real failure surfaces later in migrate(). `isUnavailable` is authoritative because
      // it consults `setupFailure`, not because the handle is nil.)
      //
      // Retry once. The common causes ARE transient — the file briefly unreadable under data
      // protection, a stale WAL after a jetsam kill — and clear on a second open.
      log.error("LocalStore.setup failed: \(error.localizedDescription) — retrying once")
      do {
        try setup(jsonCacheData: jsonCacheData)
        setupFailure = nil
        log.info("LocalStore.setup succeeded on retry")
      } catch {
        // TASK-902: a second identical failure is not transient. The most likely cause is a
        // corrupt database file, and retrying re-opens THE SAME corrupt file forever — the
        // store stays dead for the life of the install, and the only user remedy is deleting
        // the app, which also destroys every download.
        //
        // So: ask SQLite whether the file is actually corrupt, and if it is, move it aside and
        // build a fresh one. This cache is fully reconstructible from the server by delta sync,
        // so an empty store is a RECOVERABLE state; a permanently dead one is not.
        log.error("LocalStore.setup failed again: \(error.localizedDescription) — checking for corruption")
        if databaseIsCorrupt() {
          if quarantineCorruptDatabase() {
            do {
              // Fresh file, fresh schema. jsonCacheData is deliberately NOT replayed here:
              // the legacy cache was already consumed (or absent) on the first attempt, and
              // re-importing it into a rebuilt store risks resurrecting stale rows.
              try setup(jsonCacheData: nil)
              setupFailure = nil
              didRecoverFromCorruption = true
              log.info("LocalStore recovered: corrupt database quarantined, fresh store created")
            } catch {
              setupFailure = error
              log.error("LocalStore: rebuild after quarantine FAILED — \(error.localizedDescription)")
            }
          } else {
            setupFailure = error
            log.error("LocalStore: database is corrupt but could not be quarantined — store is UNAVAILABLE")
          }
        } else {
          setupFailure = error
          log.error("LocalStore.setup failed twice, not corruption — store is UNAVAILABLE, local writes will not persist")
        }
      }
    }
    // Signal all callers that are waiting on ensureReady(). This is set even on failure:
    // it means "startup finished", not "the store works" — otherwise every caller awaiting
    // ensureReady() would hang forever. Ask `isUnavailable` for health.
    isReady = true
    for cont in readyContinuations { cont.resume() }
    readyContinuations.removeAll()
  }

  /// Await this before performing any store operations when there is a risk
  /// of calling before the async setup Task has completed (TASK-420).
  /// No-ops instantly if setup is already done.
  func ensureReady() async {
    guard !isReady else { return }
    await withCheckedContinuation { cont in
      readyContinuations.append(cont)
    }
  }

  private func setup(jsonCacheData: (url: URL, data: Data)? = nil) throws {
    try openDatabase()
    try migrate()
    migrateFromJSONCache(preloadedData: jsonCacheData)
  }

  // MARK: - Schema

  /// Where the SQLite file lives. ONE definition, because the corruption probe and the
  /// quarantine both need the same answer as the open — a second copy of this logic that
  /// drifted would have the recovery path moving a different file than the one that failed.
  ///
  /// `databaseURLOverride` is nil in production (see its declaration — R4 test seam), so this
  /// resolves to the same `<Documents>/dsreel.db` it always has.
  ///
  /// Returns the Documents fallback path even when Documents cannot be located; `openDatabase`
  /// still throws in that case, and a probe against a path that does not exist correctly
  /// reports "not corrupt".
  private func resolvedDatabaseURL() -> URL {
    if let override = databaseURLOverride { return override }
    guard let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dsreel.db")
    }
    return d.appendingPathComponent("dsreel.db")
  }

  private func openDatabase() throws {
    if databaseURLOverride == nil,
       FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first == nil {
      throw LocalStoreError.cannotLocateDocuments
    }
    let dbURL = resolvedDatabaseURL()
    let docs = dbURL.deletingLastPathComponent()
    if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
      // Release the half-open handle. sqlite3_open allocates one even on failure, and
      // leaving it non-nil means the `guard let db` at the head of every write path does
      // NOT short-circuit on a dead store, contrary to this file's own comments.
      sqlite3_close(db)
      db = nil
      throw LocalStoreError.openFailed("open failed at \(dbURL.path)")
    }
    // WAL mode for concurrent reads during writes
    exec("PRAGMA journal_mode=WAL")
    exec("PRAGMA synchronous=NORMAL")
    exec("PRAGMA foreign_keys=ON")

    // Apply NSFileProtectionComplete to DB and WAL/SHM sidecars.
    // WAL sidecars are created lazily when WAL mode activates; guards make this a no-op if absent.
    applyFileProtection(to: dbURL)
    applyFileProtection(to: docs.appendingPathComponent("dsreel.db-wal"))
    applyFileProtection(to: docs.appendingPathComponent("dsreel.db-shm"))

    #if os(tvOS)
    // Existing tvOS installs already carry .complete on disk from a previous version, and
    // the attribute persists across app updates — guarding the setter alone would fix new
    // installs and leave every current one broken. Clear it explicitly.
    clearFileProtection(from: dbURL)
    clearFileProtection(from: docs.appendingPathComponent("dsreel.db-wal"))
    clearFileProtection(from: docs.appendingPathComponent("dsreel.db-shm"))
    #endif
  }

  /// iOS only. `.complete` makes the file unreadable while the device is LOCKED, which is
  /// the right privacy posture for a phone — a stolen handset should not yield the user's
  /// library. tvOS has no lock state and no passcode, so there is nothing to unlock the
  /// class key: an Apple TV can end up unable to read or write its own database, and both
  /// SQLite failures here are silent (`try?`, and `exec` ignores its result).
  ///
  /// The observable symptom was the home rails being permanently empty on tvOS. The cursor
  /// write (setItemSeq) never persisted and the item rows read back empty, so every 30s
  /// cycle re-synced the ENTIRE library from since=0 — confirmed in the server log: 5,005
  /// sync/items requests paging 0 -> 5,056 and restarting at 0, ~4MB every 30 seconds,
  /// forever. queryRails() then ran against an empty table and returned nothing, which is
  /// why Just Added and Continue Watching never appeared while genre filtering, captions
  /// and playback speed — none of which touch LocalStore — all worked fine.
  private func applyFileProtection(to url: URL) {
    #if os(iOS)
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    // .completeUntilFirstUserAuthentication, NOT .complete.
    //
    // .complete makes the file unwritable whenever the device is locked. Background audio
    // is ON by default, so the normal case — phone locked in a pocket, audio playing — is
    // exactly when the resume position needs saving and exactly when the write silently
    // failed. Every position for the whole locked interval was lost, with no log.
    //
    // This class keeps the data encrypted at rest (unreadable until the first unlock after
    // boot) while staying writable for the rest of the session. The tvOS branch below
    // already had to undo .complete for the same underlying reason.
    try? fm.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
    #endif
  }

  #if os(tvOS)
  /// Undo a protection class written by an earlier build. `.none` is correct on tvOS:
  /// the device has no lock state, so there is no window in which protection could apply,
  /// and leaving `.complete` in place makes the database unreadable to its own app.
  private func clearFileProtection(from url: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    // Spell the optional out. `current != .none` on an Optional resolves to
    // Optional<FileProtectionType>.none (i.e. nil), not FileProtectionType.none — the
    // compiler warns because it means the opposite of what it reads like.
    guard let current = (try? fm.attributesOfItem(atPath: url.path)[.protectionKey]) as? FileProtectionType,
          current != FileProtectionType.none else { return }
    do {
      try fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
      log.info("cleared file protection on \(url.lastPathComponent) — was \(current.rawValue)")
    } catch {
      log.error("failed clearing file protection on \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }
  #endif

  private func migrate() throws {
    // Baseline schema — safe to run on any existing DB (all IF NOT EXISTS)
    try execThrows("""
      CREATE TABLE IF NOT EXISTS items (
        id               TEXT PRIMARY KEY,
        library_id       TEXT NOT NULL,
        type             TEXT NOT NULL,
        title            TEXT NOT NULL,
        year             INTEGER,
        duration_seconds INTEGER,
        added_at         TEXT NOT NULL,
        rating           REAL,
        poster_image_id  TEXT,
        backdrop_image_id TEXT,
        show_name        TEXT,
        show_folder_id   TEXT,
        season_number    INTEGER,
        episode_number   INTEGER,
        change_seq       INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS progress (
        item_id          TEXT PRIMARY KEY,
        position_seconds INTEGER NOT NULL,
        duration_seconds INTEGER NOT NULL,
        updated_at       TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS sync_cursors (
        key   TEXT PRIMARY KEY,
        value INTEGER NOT NULL DEFAULT 0
      );

      INSERT OR IGNORE INTO sync_cursors(key, value) VALUES ('item_seq', 0);
      INSERT OR IGNORE INTO sync_cursors(key, value) VALUES ('progress_seq', 0);

      CREATE INDEX IF NOT EXISTS idx_items_added_at    ON items(added_at DESC);
      CREATE INDEX IF NOT EXISTS idx_items_change_seq  ON items(change_seq);
      CREATE INDEX IF NOT EXISTS idx_progress_updated  ON progress(updated_at DESC);
    """)

    // Versioned additive migrations — each runs exactly once, guarded by PRAGMA user_version.
    // To add a new migration: append a block incrementing to the next version number.
    let version = userVersion()
    if version < 1 {
      // v1: show_folder_id was added after initial schema; already present in CREATE TABLE
      // above for new installs, but old DBs need the ALTER TABLE.
      execIgnoringErrors("ALTER TABLE items ADD COLUMN show_folder_id TEXT")
      setUserVersion(1)
    }
    if version < 2 {
      // v2: outbox flag for progress that has not yet been accepted by the server.
      //
      // Before this, recordProgress() wrote locally and fired a detached, unretried POST
      // whose failure was only logged — the comment claimed "the delta-sync cursor
      // reconciles the server on the next pass", but no upward push existed anywhere in
      // the client. A failed POST was lost permanently, which is why the server held zero
      // progress rows while the phone showed a populated Continue Watching rail.
      //
      // Defaulting existing rows to 1 (pending) is deliberate: every row already on a
      // device predates the outbox and may never have reached the server, so the first
      // flush after upgrade re-sends them.
      //
      // CORRECTION (2026-08-05): the original version of this comment claimed "the server
      // upsert is idempotent and its last-writer-wins comparison discards anything staler
      // than what it holds." That was FALSE — main.go's ON CONFLICT had no WHERE clause at
      // all, so the server was a pure last-write-wins sink and this replay could overwrite a
      // NEWER position watched on another device. Proven against the live server: POST 7500
      // then POST 6000 left the row at 6000. The server upsert is now genuinely conditional
      // (see handleProgress), so the safety argument this migration rests on is real rather
      // than assumed. Old servers remain vulnerable to a replay, which is why the client
      // also refuses to enqueue a regression — see recordProgress.
      execIgnoringErrors("ALTER TABLE progress ADD COLUMN pending_sync INTEGER NOT NULL DEFAULT 1")
      execIgnoringErrors("CREATE INDEX IF NOT EXISTS idx_progress_pending ON progress(pending_sync) WHERE pending_sync = 1")
      setUserVersion(2)
    }
    if version < 3 {
      try migrateToV3()
      setUserVersion(3)
    }
  }

  /// v3 (FRD-002 FR-233, FR-262): progress per profile, age level per item.
  ///
  /// - progress gains `profile_id`, and the primary key becomes (profile_id, item_id). SQLite
  ///   cannot change a primary key in place, so rows are COPIED into a new table, counted,
  ///   and only then is the old table dropped, all in one transaction. A count mismatch
  ///   rolls the whole thing back and leaves the v2 table untouched.
  /// - Existing rows go to the legacy bucket `''`. They belong to the owner (FR-233), whose
  ///   id is not known until /profiles answers; `claimLegacyRows(ownerID:)` moves them then.
  /// - The global `progress_seq` cursor becomes the legacy bucket's cursor `progress_seq:`.
  /// - items gain `age_level` (NULL = unrated: counts as the server's unrated level) and
  ///   `content_rating`.
  private func migrateToV3() throws {
    try execThrows("BEGIN IMMEDIATE")
    do {
      let before = scalarInt("SELECT COUNT(*) FROM progress") ?? -1
      try execThrows("""
        CREATE TABLE progress_v3 (
          profile_id       TEXT NOT NULL DEFAULT '',
          item_id          TEXT NOT NULL,
          position_seconds INTEGER NOT NULL,
          duration_seconds INTEGER NOT NULL,
          updated_at       TEXT NOT NULL,
          pending_sync     INTEGER NOT NULL DEFAULT 1,
          PRIMARY KEY (profile_id, item_id)
        );
        INSERT INTO progress_v3(profile_id, item_id, position_seconds, duration_seconds, updated_at, pending_sync)
          SELECT '', item_id, position_seconds, duration_seconds, updated_at, pending_sync FROM progress;
      """)
      let after = scalarInt("SELECT COUNT(*) FROM progress_v3") ?? -2
      guard before == after else {
        throw LocalStoreError.execFailed("v3 migration: copied \(after) progress rows of \(before); rolled back")
      }
      try execThrows("""
        DROP TABLE progress;
        ALTER TABLE progress_v3 RENAME TO progress;
        CREATE INDEX IF NOT EXISTS idx_progress_updated ON progress(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_progress_pending ON progress(pending_sync) WHERE pending_sync = 1;
        CREATE INDEX IF NOT EXISTS idx_progress_profile ON progress(profile_id, updated_at DESC);
        DELETE FROM sync_cursors WHERE key = 'progress_seq:';
        UPDATE sync_cursors SET key = 'progress_seq:' WHERE key = 'progress_seq';
      """)
      // Additive; a column that already exists is not an error worth failing the upgrade for.
      execIgnoringErrors("ALTER TABLE items ADD COLUMN age_level INTEGER")
      execIgnoringErrors("ALTER TABLE items ADD COLUMN content_rating TEXT")
      try execThrows("COMMIT")
      log.info("v3 migration: \(after) progress row(s) moved to per-profile storage")
    } catch {
      exec("ROLLBACK")
      log.error("v3 migration failed, rolled back: \(error.localizedDescription)")
      throw error
    }
  }

  private func scalarInt(_ sql: String) -> Int? {
    guard let db else { return nil }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : nil
  }

  /// `progress_seq:<profileId>`: the progress cursor is per profile (FR-233).
  private static func progressCursorKey(_ profileID: String) -> String {
    "progress_seq:" + profileID
  }

  private func userVersion() -> Int {
    guard let db else { return 0 }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
  }

  private func setUserVersion(_ version: Int) {
    guard let db else { return }
    // PRAGMA user_version does not support bound parameters — value is an integer literal.
    sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
  }

  // MARK: - JSON Cache Migration

  // File I/O is done off-actor by setupLogged() before calling here (TASK-506).
  private func migrateFromJSONCache(preloadedData: (url: URL, data: Data)? = nil) {
    guard let loaded = preloadedData,
          let entry = try? JSONDecoder().decode(HomeCacheEntry.self, from: loaded.data) else { return }

    log.info("Migrating JSON cache (\(entry.items.count) items) to SQLite")
    upsertItems(entry.items)
    // We don't know the old seq values, leave at 0 to force a full sync on next launch
    try? FileManager.default.removeItem(at: loaded.url)
    log.info("JSON cache migration complete — file deleted")
  }

  // MARK: - Items

  func upsertItems(_ items: [ItemSummary]) {
    guard let db else { return }
    exec("BEGIN TRANSACTION")
    let sql = """
      INSERT INTO items(id, library_id, type, title, year, duration_seconds, added_at,
                        rating, poster_image_id, backdrop_image_id, show_name, show_folder_id,
                        season_number, episode_number, change_seq, age_level, content_rating)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        library_id=excluded.library_id,
        type=excluded.type,
        title=excluded.title,
        year=excluded.year,
        duration_seconds=excluded.duration_seconds,
        added_at=excluded.added_at,
        rating=excluded.rating,
        poster_image_id=excluded.poster_image_id,
        backdrop_image_id=excluded.backdrop_image_id,
        show_name=excluded.show_name,
        show_folder_id=excluded.show_folder_id,
        season_number=excluded.season_number,
        episode_number=excluded.episode_number,
        change_seq=excluded.change_seq,
        age_level=excluded.age_level,
        content_rating=excluded.content_rating
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      exec("ROLLBACK")
      log.error("upsertItems: sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db)))")
      return
    }
    defer { sqlite3_finalize(stmt) }

    for item in items {
      sqlite3_reset(stmt)
      sqlite3_bind_text(stmt, 1, item.id, -1, SQLITE_TRANSIENT)
      // libraryId should always be present from the sync payload; "lib_unknown" is a
      // last-resort fallback that indicates a sync bug and will be visible in logs.
      let libId = item.libraryId ?? {
        log.error("upsertItems: item \(item.id) has no libraryId — check sync payload")
        return "lib_unknown"
      }()
      sqlite3_bind_text(stmt, 2, libId, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(stmt, 3, item.type, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(stmt, 4, item.title, -1, SQLITE_TRANSIENT)
      // bind_int64/Int64 — never Int32(). The models are Int (64-bit) and these values come
      // straight from server JSON, so `Int32(x)` is a TRAPPING narrowing conversion: any value
      // above Int32.max crashes the app rather than truncating. The backend validates progress
      // only as `duration <= 0 || position < 0` (main.go:4392) with no upper bound, so an
      // out-of-range duration is accepted server-side, returned by sync, and then traps here —
      // on every launch, because runDeltaSync runs at startup. That is an unrecoverable
      // crash-loop with no in-app escape. SQLite stores 64-bit integers natively; there was
      // never a reason to narrow.
      if let year = item.year { sqlite3_bind_int64(stmt, 5, Int64(year)) } else { sqlite3_bind_null(stmt, 5) }
      if let dur = item.durationSeconds { sqlite3_bind_int64(stmt, 6, Int64(dur)) } else { sqlite3_bind_null(stmt, 6) }
      sqlite3_bind_text(stmt, 7, item.addedAt, -1, SQLITE_TRANSIENT)
      if let r = item.rating { sqlite3_bind_double(stmt, 8, r) } else { sqlite3_bind_null(stmt, 8) }
      if let p = item.posterImageId { sqlite3_bind_text(stmt, 9, p, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
      if let b = item.backdropImageId { sqlite3_bind_text(stmt, 10, b, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 10) }
      if let s = item.showName { sqlite3_bind_text(stmt, 11, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 11) }
      if let f = item.showFolderId { sqlite3_bind_text(stmt, 12, f, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 12) }
      if let sn = item.seasonNumber { sqlite3_bind_int64(stmt, 13, Int64(sn)) } else { sqlite3_bind_null(stmt, 13) }
      if let en = item.episodeNumber { sqlite3_bind_int64(stmt, 14, Int64(en)) } else { sqlite3_bind_null(stmt, 14) }
      sqlite3_bind_int64(stmt, 15, Int64(item.changeSeq ?? 0))
      // NULL when the server sent no level (an older server): every read treats it as 4.
      if let a = item.ageLevel { sqlite3_bind_int64(stmt, 16, Int64(a)) } else { sqlite3_bind_null(stmt, 16) }
      if let c = item.contentRating { sqlite3_bind_text(stmt, 17, c, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 17) }
      let rc = sqlite3_step(stmt)
      if rc != SQLITE_DONE {
        let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
        log.error("upsertItems: step failed [\(rc)] for item \(item.id): \(msg)")
      }
      sqlite3_reset(stmt)
    }
    exec("COMMIT")
  }

  func deleteItems(_ ids: [String]) {
    guard !ids.isEmpty, let db else { return }
    exec("BEGIN TRANSACTION")
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "DELETE FROM items WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
      exec("ROLLBACK")
      log.error("deleteItems: sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db)))")
      return
    }
    defer { sqlite3_finalize(stmt) }
    for id in ids {
      sqlite3_reset(stmt)
      sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
      // FIX-3: Check return code — SQLITE_BUSY under contention was silently swallowed.
      let rc = sqlite3_step(stmt)
      if rc != SQLITE_DONE {
        let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
        log.error("deleteItems: step failed [\(rc)] for id \(id): \(msg)")
      }
    }
    exec("COMMIT")
  }

  // MARK: - Progress

  /// `profileID` nil = the active profile. Sync passes the profile it fetched for, so a
  /// switch mid-request can never file one profile's positions under another (FR-201).
  func upsertProgress(_ progress: [String: ItemProgress], profileID: String? = nil) {
    guard !progress.isEmpty, let db else { return }
    let pid = profileID ?? activeScope.id
    guard !refusesWrites(for: pid, "upsertProgress") else { return }
    exec("BEGIN TRANSACTION")
    // TASK-840: conflict resolution is now ownership-based, NOT a wall-clock comparison.
    //
    // The previous rule (FIX-8) was `excluded.updated_at > updated_at` — a lexical compare of
    // an RFC3339 string stamped by the DEVICE clock (upsertSingleProgress) against one stamped
    // by the NAS clock (backend main.go handleProgress). Format parity is fine; CLOCK parity is
    // not. A NAS running slow (bad NTP, dead RTC after a power cut) makes every server row look
    // older than the local row forever, so newer cross-device progress is discarded on EVERY
    // sync with no recovery short of a sign-out. A NAS running fast inverts it and clobbers
    // offline-recorded local progress — the exact loss FIX-8 existed to prevent.
    //
    // No per-row server sequence exists to compare on instead: progress_seq is a single global
    // counter and /progress/all returns only position/duration/updatedAt (main.go
    // handleProgressAll), so there is nothing monotonic and per-item to key off.
    //
    // The correct discriminator is already on the row: pending_sync. It means "this local value
    // has not been accepted by the server yet," which is the ONLY case where the local row can
    // legitimately be newer than what the server just sent us. So:
    //   pending_sync = 1 → keep local (our unsent write wins; flushPendingProgress will push it)
    //   pending_sync = 0 → take the server value (it is authoritative by definition — it either
    //                      originated here and round-tripped, or came from another device)
    // Both sides of that test are local facts. No clock is consulted, so no amount of skew can
    // suppress an update permanently.
    let sql = """
      INSERT INTO progress(item_id, position_seconds, duration_seconds, updated_at, pending_sync, profile_id)
      VALUES(?,?,?,?,0,?)
      ON CONFLICT(profile_id, item_id) DO UPDATE SET
        position_seconds=CASE WHEN pending_sync = 1 THEN position_seconds ELSE excluded.position_seconds END,
        duration_seconds=CASE WHEN pending_sync = 1 THEN duration_seconds ELSE excluded.duration_seconds END,
        updated_at=CASE WHEN pending_sync = 1 THEN updated_at ELSE excluded.updated_at END
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      exec("ROLLBACK")
      log.error("upsertProgress: sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db)))")
      return
    }
    defer { sqlite3_finalize(stmt) }
    for (itemId, p) in progress {
      sqlite3_reset(stmt)
      sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
      // See upsertItems: server-supplied, unbounded above — bind 64-bit, never Int32().
      sqlite3_bind_int64(stmt, 2, Int64(p.positionSeconds))
      sqlite3_bind_int64(stmt, 3, Int64(p.durationSeconds))
      sqlite3_bind_text(stmt, 4, p.updatedAt, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(stmt, 5, pid, -1, SQLITE_TRANSIENT)
      // FIX-3: Check return code — SQLITE_BUSY under contention was silently swallowed.
      let rc = sqlite3_step(stmt)
      if rc != SQLITE_DONE {
        let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
        log.error("upsertProgress: step failed [\(rc)] for item \(itemId): \(msg)")
      }
    }
    exec("COMMIT")
  }

  /// Writes progress locally and marks it pending upload. `pending_sync` is cleared only by
  /// `markProgressSynced(_:)` after the server has actually accepted the value.
  ///
  /// Returns the watch time it stamped (RFC3339), even when the store could not take the
  /// write: the caller sends it as the live write's `watchedAt`, so the server orders this
  /// write by the same clock as every replay from this device (FRD-001 FR-014).
  @discardableResult
  func upsertSingleProgress(itemId: String, positionSeconds: Int, durationSeconds: Int,
                            profileID: String? = nil) -> String {
    let now = iso8601Formatter.string(from: Date())
    guard let db else { return now }
    let pid = profileID ?? activeScope.id
    guard !refusesWrites(for: pid, "upsertSingleProgress") else { return now }
    var stmt: OpaquePointer?
    let sql = """
      INSERT INTO progress(item_id, position_seconds, duration_seconds, updated_at, pending_sync, profile_id)
      VALUES(?,?,?,?,1,?)
      ON CONFLICT(profile_id, item_id) DO UPDATE SET
        position_seconds=excluded.position_seconds,
        duration_seconds=excluded.duration_seconds,
        updated_at=excluded.updated_at,
        pending_sync=1
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      log.error("upsertSingleProgress: sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db)))")
      return now
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 2, Int64(positionSeconds))
    sqlite3_bind_int64(stmt, 3, Int64(durationSeconds))
    sqlite3_bind_text(stmt, 4, now, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 5, pid, -1, SQLITE_TRANSIENT)
    // FIX-3: Check return code — SQLITE_BUSY under contention was silently swallowed.
    let rc = sqlite3_step(stmt)
    if rc != SQLITE_DONE {
      let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
      log.error("upsertSingleProgress: step failed [\(rc)] for item \(itemId): \(msg)")
    }
    return now
  }

  // MARK: - Progress Outbox
  //
  // Progress is written locally first and flagged pending; the flag clears only once the
  // server confirms the write. This replaces a detached fire-and-forget POST whose failure
  // was logged and then forgotten, which silently lost every progress update made while the
  // NAS was unreachable — the reason the server held zero rows while phones showed
  // populated Continue Watching rails.

  /// One item of unsynced progress.
  struct PendingProgress: Sendable {
    let itemId: String
    let positionSeconds: Int
    let durationSeconds: Int
    /// When the viewer was actually at this position, not when the row is being uploaded.
    ///
    /// The column already existed and was used only for ORDER BY; it was never read out, so
    /// the flush could not tell the server when anything was watched and the server stamped
    /// its own receive time. A backlog flushed after a reconnect therefore landed with one
    /// timestamp across every row — measured live at 106 rows on a single second — and both
    /// home rails sort on it, so they ordered by when the queue drained.
    let updatedAt: String
  }

  /// Progress rows the server has not yet confirmed, oldest first so the flush replays in
  /// the order the user actually watched. Bounded: a device offline for a long stretch
  /// should not fire an unbounded burst at the NAS on reconnect.
  /// One profile's unsynced rows (nil = active). The outbox flushes them with that
  /// profile's header, so each row reaches the server as the profile that watched it.
  func pendingProgress(limit: Int = 200, profileID: String? = nil) -> [PendingProgress] {
    guard let db else { return [] }
    let pid = profileID ?? activeScope.id
    var stmt: OpaquePointer?
    let sql = """
      SELECT item_id, position_seconds, duration_seconds, updated_at
      FROM progress
      WHERE pending_sync = 1 AND profile_id = ?
      ORDER BY updated_at ASC
      LIMIT ?
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, pid, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 2, Int64(limit))
    var out: [PendingProgress] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let idC = sqlite3_column_text(stmt, 0) else { continue }
      out.append(PendingProgress(
        itemId: String(cString: idC),
        positionSeconds: Int(sqlite3_column_int64(stmt, 1)),
        durationSeconds: Int(sqlite3_column_int64(stmt, 2)),
        updatedAt: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
      ))
    }
    return out
  }

  /// Clears the pending flag after the server accepted this exact value.
  ///
  /// The position/duration guard matters: if the user kept watching while the flush was in
  /// flight, the row now holds a NEWER position than the one just uploaded. Clearing
  /// unconditionally would drop that newer value from the outbox and it would never be sent.
  func markProgressSynced(itemId: String, positionSeconds: Int, durationSeconds: Int,
                          profileID: String? = nil) {
    guard let db else { return }
    let pid = profileID ?? activeScope.id
    var stmt: OpaquePointer?
    let sql = """
      UPDATE progress SET pending_sync = 0
      WHERE item_id = ? AND position_seconds = ? AND duration_seconds = ? AND profile_id = ?
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 2, Int64(positionSeconds))
    sqlite3_bind_int64(stmt, 3, Int64(durationSeconds))
    sqlite3_bind_text(stmt, 4, pid, -1, SQLITE_TRANSIENT)
    if sqlite3_step(stmt) != SQLITE_DONE {
      let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
      log.error("markProgressSynced: step failed for \(itemId): \(msg)")
    }
  }

  /// Clears the pending flag for an item REGARDLESS of its current position/duration.
  ///
  /// Only for rows the server has PERMANENTLY rejected (404 for a deleted item, 400 for an
  /// invalid payload). Those can never be uploaded, so they must leave the outbox or they
  /// block every row behind them — which is the stall that 14e72cf existed to remove.
  ///
  /// Deliberately NOT markProgressSynced: that helper is value-guarded so a stale
  /// confirmation cannot clear a newer local position. Reusing it here meant a rejected row
  /// whose position advanced mid-flush never cleared, so the flush "dropped" it in the log
  /// and then retried it forever on the next pass — reintroducing the same stall under
  /// concurrent playback.
  func dropPendingProgress(itemId: String, profileID: String? = nil) {
    guard let db else { return }
    let pid = profileID ?? activeScope.id
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "UPDATE progress SET pending_sync = 0 WHERE item_id = ? AND profile_id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 2, pid, -1, SQLITE_TRANSIENT)
    if sqlite3_step(stmt) != SQLITE_DONE {
      let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
      log.error("dropPendingProgress: step failed for \(itemId): \(msg)")
    }
  }

  /// Count of unsynced rows — for diagnostics and to skip a no-op flush cheaply.
  func pendingProgressCount(profileID: String? = nil) -> Int {
    guard let db else { return 0 }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM progress WHERE pending_sync = 1 AND profile_id = ?", -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, profileID ?? activeScope.id, -1, SQLITE_TRANSIENT)
    return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
  }

  /// Resumable position for an item, or 0 if there is nothing to resume.
  ///
  /// Returns 0 for finished items (see `PlaybackProgress.isFinished`) so that playing a
  /// completed title starts from the beginning instead of dropping the viewer into the
  /// closing credits. Suppressing it here rather than at each call site keeps the resume
  /// seek, the "Start Over" button's visibility, and the progress rings in agreement.
  func getProgressSeconds(itemId: String) -> Int {
    guard let db else { return 0 }
    var stmt: OpaquePointer?
    // Active profile only, and only for a title within its ceiling (FR-201, FR-262).
    let sql = """
      SELECT p.position_seconds, p.duration_seconds
      FROM progress p
      LEFT JOIN items i ON i.id = p.item_id
      WHERE p.item_id = ?4 AND p.profile_id = ?1 AND \(Self.sqlVisibleToScope)
      LIMIT 1
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    bindScope(stmt)
    sqlite3_bind_text(stmt, 4, itemId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    let position = Int(sqlite3_column_int(stmt, 0))
    let duration = Int(sqlite3_column_int(stmt, 1))
    if PlaybackProgress.isFinished(positionSeconds: position, durationSeconds: duration) { return 0 }
    return position
  }

  // MARK: - Rails Queries

  // TASK-841/TASK-849: the rail SQL and PlaybackProgress must express the SAME rule.
  //
  // Previously the SQL knew only about the 0.95 ratio and had no equivalent of the
  // 90-seconds-remaining clause in PlaybackProgress.isFinished, and its two bands both
  // included 0.95. Two defects followed: an item at exactly ratio 0.95 satisfied
  // queryContinueWatching (BETWEEN ... AND 0.95) *and* queryRecentlyWatched (>= 0.95) and
  // rendered in both rails at once; and a ~25-min episode with 75s left sat in Continue
  // Watching with a near-full ring while getProgressSeconds — which routes through
  // PlaybackProgress.isFinished — returned 0, so tapping it restarted from 00:00.
  //
  // These fragments are interpolated from the Swift constants so the two definitions cannot
  // drift apart again. They are mutually exclusive by construction: an item is finished, or
  // it is in progress, never both.
  private static let sqlRatio = "CAST(p.position_seconds AS REAL) / p.duration_seconds"
  private static let sqlRemaining = "(p.duration_seconds - p.position_seconds)"

  /// Mirrors PlaybackProgress.isFinished: past the watched ratio OR inside the final 90s.
  ///
  /// `position_seconds > 0` mirrors the guard in `isFinished`: a row at position 0 (Mark as
  /// Unwatched writes one) is never finished, even on a clip shorter than 90s, where
  /// `remaining < 90` alone would put it in Recently Watched (TASK-962).
  private static let sqlIsFinished = """
    (p.position_seconds > 0 \
    AND (\(sqlRatio) > \(PlaybackProgress.watchedThreshold) \
    OR \(sqlRemaining) < \(PlaybackProgress.finishedRemainingSeconds)))
    """

  /// Started (>= 5%) but not finished — the exact complement of sqlIsFinished within
  /// the started band, so no row can match both rails.
  private static let sqlIsInProgress = """
    (\(sqlRatio) >= \(PlaybackProgress.startedThreshold) AND NOT \(sqlIsFinished))
    """

  // Shared 18-column projection used by all three rail queries.
  private static let itemSelectColumns = """
    i.id, i.library_id, i.type, i.title, i.year, i.duration_seconds,
    i.added_at, i.rating, i.poster_image_id, i.backdrop_image_id,
    i.show_name, i.show_folder_id, i.season_number, i.episode_number, i.change_seq,
    p.position_seconds, p.duration_seconds, p.updated_at,
    i.age_level, i.content_rating
    """

  // MARK: Profile filter (FR-201, FR-262)
  //
  // Every query that returns titles or positions binds the active scope as ?1 (profile id),
  // ?2 (max age level) and ?3 (the unrated level); query-specific parameters start at ?4.
  // Progress joins carry `p.profile_id = ?1` IN THE JOIN, so a LEFT JOIN still returns the
  // title with no progress rather than another profile's.
  //
  // sqlVisibleToScope is the client visibility rule (FR-242) as every offline read runs it:
  // a NULL level counts as the server's unrated level (GET /profiles/age-levels, not the
  // ladder's top), bound from the scope (never a literal here). Its Swift twin is
  // ProfileScope.allows(ageLevel:), for lists that never reach SQLite; SQL cannot call Swift,
  // hence two sites. Change one, change both:
  // ProfileScopeFixTests pins them to the same answer for every level and for NULL.
  private static let sqlProgressForScope = "p.profile_id = ?1"
  private static let sqlVisibleToScope = "COALESCE(i.age_level, ?3) <= ?2"

  private func bindScope(_ stmt: OpaquePointer?) {
    sqlite3_bind_text(stmt, 1, activeScope.id, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 2, Int64(activeScope.maxAgeLevel))
    sqlite3_bind_int64(stmt, 3, Int64(activeScope.unratedLevel))
  }

  func queryRails() -> HomeRails {
    HomeRails(
      continueWatching: queryContinueWatching(),
      justAdded: queryJustAdded(),
      recentlyWatched: queryRecentlyWatched()
    )
  }

  private func queryContinueWatching() -> [ItemSummary] {
    let sql = """
      SELECT \(Self.itemSelectColumns)
      FROM items i
      JOIN progress p ON p.item_id = i.id AND \(Self.sqlProgressForScope)
      WHERE p.duration_seconds > 0
        AND \(Self.sqlVisibleToScope)
        -- FIX-11: unified 5% lower threshold matches iOS computeHomeRails (was 0.02, tvOS diverged)
        -- TASK-841: upper bound now excludes the 90s-remaining case as well as the 95% ratio,
        -- so this rail agrees with PlaybackProgress.isFinished / getProgressSeconds.
        AND \(Self.sqlIsInProgress)
      ORDER BY p.updated_at DESC
      LIMIT 40
    """
    // 16, not 10. A rail that ends after ten cards looks truncated on a phone and is
    // visibly short on a TV, where more of the row is on screen at once. The SQL LIMIT is
    // raised alongside it because dedup-by-show runs AFTER the query — with episodes
    // dominating recent additions, too small a window can starve the rail before the
    // dedup ever reaches enough distinct shows.
    return fetchItems(sql: sql, deduplicateByShow: true, maxCount: 16)
  }

  private func queryJustAdded() -> [ItemSummary] {
    // Offline stand-in for the server's Just Added (FR-088, TASK-986): the newest titles by
    // added_at the profile can see, one per show, at most 16. NO progress filter. The server
    // rail (backend justadded.go queryJustAdded) has none, so a title the profile has started
    // or finished is listed here exactly when it is listed online. A progress join here would be
    // a second, drifted copy of that rule.
    let sql = """
      SELECT \(Self.itemSelectColumns)
      FROM items i
      LEFT JOIN progress p ON p.item_id = i.id AND \(Self.sqlProgressForScope)
      WHERE i.added_at != ''
        AND \(Self.sqlVisibleToScope)
      ORDER BY i.added_at DESC
      LIMIT 500
    """
    var items = fetchItems(sql: sql, deduplicateByShow: true, maxCount: 16)
    items = fillShowPosters(items)
    return items
  }

  // For TV episodes missing a poster, substitute the poster ID from any sibling
  // episode in the same show that has one. Covers the common case where individual
  // episode artwork was never downloaded but a show-level poster exists.
  private func fillShowPosters(_ items: [ItemSummary]) -> [ItemSummary] {
    guard let db else { return items }
    var result = items
    for (idx, item) in items.enumerated() {
      guard item.posterImageId == nil, let folder = item.showFolderId, !folder.isEmpty else { continue }
      var stmt: OpaquePointer?
      let sql = "SELECT id FROM items WHERE show_folder_id = ? AND poster_image_id IS NOT NULL LIMIT 1"
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
      defer { sqlite3_finalize(stmt) }
      sqlite3_bind_text(stmt, 1, folder, -1, SQLITE_TRANSIENT)
      if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
        let siblingId = String(cString: ptr)
        result[idx] = item.withPosterImageId(siblingId)
      }
    }
    return result
  }

  private func queryRecentlyWatched() -> [ItemSummary] {
    let sql = """
      SELECT \(Self.itemSelectColumns)
      FROM items i
      JOIN progress p ON p.item_id = i.id AND \(Self.sqlProgressForScope)
      WHERE p.duration_seconds > 0
        AND \(Self.sqlVisibleToScope)
        -- TASK-841: strictly > 0.95 (was >=, which overlapped Continue Watching's inclusive
        -- upper bound and put an item at exactly 0.95 in both rails), plus the 90s-remaining
        -- clause so this matches PlaybackProgress.isFinished exactly.
        AND \(Self.sqlIsFinished)
      ORDER BY p.updated_at DESC
      LIMIT 500
    """
    return fetchItems(sql: sql, deduplicateByShow: true, maxCount: 8)
  }

  private func fetchItems(sql: String, deduplicateByShow: Bool, maxCount: Int) -> [ItemSummary] {
    guard let db else { return [] }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    bindScope(stmt)

    var results: [ItemSummary] = []
    var seenShows = Set<String>()

    while sqlite3_step(stmt) == SQLITE_ROW {
      let item = itemFromStatement(stmt)

      if deduplicateByShow {
        // One entry per show, keyed by ItemSummary.showDedupKey (the single definition; the demo
        // rails use the same one). show_name may be null where TMDb metadata was never fetched.
        if let key = item.showDedupKey {
          if seenShows.contains(key) { continue }
          seenShows.insert(key)
        }
      }

      results.append(item)
      if results.count >= maxCount { break }
    }
    return results
  }

  func fetchItems(forLibraryId libraryId: String, limit: Int = 50) -> [ItemSummary] {
    guard let db else { return [] }
    let sql = """
      SELECT \(Self.itemSelectColumns)
      FROM items i
      LEFT JOIN progress p ON p.item_id = i.id AND \(Self.sqlProgressForScope)
      WHERE i.library_id = ?4
        AND \(Self.sqlVisibleToScope)
      ORDER BY i.added_at DESC
      LIMIT ?5
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    bindScope(stmt)
    sqlite3_bind_text(stmt, 4, libraryId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 5, Int64(limit))
    var results: [ItemSummary] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      results.append(itemFromStatement(stmt))
    }
    return results
  }

  func totalItemCount() -> Int {
    guard let db else { return 0 }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM items", -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(stmt, 0))
  }

  func hasItems() -> Bool {
    totalItemCount() > 0
  }

  /// The newest `added_at` in the local store, or "" when empty.
  ///
  /// Used to detect a sync that has silently stopped delivering. The cursor comparison in
  /// runDeltaSync catches a cursor that ran AHEAD of the server, but not every way a sync
  /// can wedge — and the symptom is identical and invisible either way: rails keep
  /// rendering, logs keep saying "done", and the library quietly stops growing. Comparing
  /// the newest local item against the newest the server reports is a direct check on the
  /// thing the user actually notices.
  func newestAddedAt() -> String {
    guard let db else { return "" }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT MAX(added_at) FROM items", -1, &stmt, nil) == SQLITE_OK else { return "" }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return "" }
    return sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
  }

  // MARK: - Sync Cursors

  /// The catalog cursor (account-wide) and one profile's progress cursor (nil = active).
  func getSyncCursors(profileID: String? = nil) -> SyncCursors {
    guard let db else { return SyncCursors(itemSeq: 0, progressSeq: 0) }
    let progressKey = Self.progressCursorKey(profileID ?? activeScope.id)
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT key, value FROM sync_cursors", -1, &stmt, nil) == SQLITE_OK else {
      return SyncCursors(itemSeq: 0, progressSeq: 0)
    }
    defer { sqlite3_finalize(stmt) }
    var itemSeq = 0
    var progressSeq = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
      let key = String(cString: sqlite3_column_text(stmt, 0))
      let val = Int(sqlite3_column_int64(stmt, 1))
      if key == "item_seq" { itemSeq = val }
      else if key == progressKey { progressSeq = val }
    }
    return SyncCursors(itemSeq: itemSeq, progressSeq: progressSeq)
  }

  // setSyncCursors(_:) lived here — zero callers, superseded by the individual
  // setItemSeq / setProgressSeq writers below, which report failure instead of
  // silently dropping the cursor.

  /// Persist the delta-sync watermark. Failures are LOUD, not silent.
  ///
  /// This used to ignore both the prepare failure and the step result. When the write
  /// could not land — as happened on tvOS, where a file-protection class the device can
  /// never unlock made the database unwritable — the cursor silently stayed at 0 and the
  /// client re-downloaded the entire library every 30 seconds indefinitely, with nothing
  /// anywhere reporting a problem. A cursor that does not persist is the difference
  /// between an incremental sync and an infinite one, so it has to be observable.
  func setItemSeq(_ seq: Int) {
    guard let db else { return }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_cursors(key, value) VALUES('item_seq', ?)", -1, &stmt, nil) == SQLITE_OK else {
      let msg = String(cString: sqlite3_errmsg(db))
      log.error("setItemSeq: prepare failed — \(msg)")
      dlog.error(.library, "sync cursor NOT saved (prepare): \(msg)")
      return
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(seq))
    if sqlite3_step(stmt) != SQLITE_DONE {
      let msg = String(cString: sqlite3_errmsg(db))
      log.error("setItemSeq: write failed — \(msg)")
      // Surfaced in the on-device diagnostic log: without this the only symptom is
      // "the rails are empty", which points at the rails rather than at persistence.
      dlog.error(.library, "sync cursor NOT saved — every sync will restart from 0: \(msg)")
    }
  }

  func setProgressSeq(_ seq: Int, profileID: String? = nil) {
    guard let db else { return }
    guard !refusesWrites(for: profileID ?? activeScope.id, "setProgressSeq") else { return }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_cursors(key, value) VALUES(?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, Self.progressCursorKey(profileID ?? activeScope.id), -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 2, Int64(seq))
    if sqlite3_step(stmt) != SQLITE_DONE {
      log.error("setProgressSeq: write failed — \(String(cString: sqlite3_errmsg(db)))")
    }
  }

  // MARK: - Profiles

  /// The stored age level of one title, or nil when it is unknown: the title is not in the
  /// local catalog, or the server never sent a level for it (an older server, or a row not yet
  /// backfilled). nil is NOT "unrestricted": callers must treat it as the unrated level and
  /// fail closed, exactly as sqlVisibleToScope does. Reads no scope, so it answers the same
  /// whichever profile is active (DownloadManager uses it to gate legacy downloads).
  func ageLevel(forItemID itemID: String) -> Int? {
    guard !itemID.isEmpty, let db else { return nil }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT age_level FROM items WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK else {
      return nil
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, itemID, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return colOptInt(stmt, 0)
  }

  /// Moves progress recorded before profiles existed (the legacy bucket '') to the owner
  /// (FR-233), once the owner's id is known. Where the owner already has a row for the same
  /// title, an unsent local write wins (same ownership rule as upsertProgress); otherwise
  /// the owner's row stands. The legacy cursor is dropped, so the owner's next sync
  /// re-fetches its progress in full rather than trusting a cursor kept for another bucket.
  func claimLegacyRows(ownerID: String) {
    guard !ownerID.isEmpty, let db else { return }
    exec("BEGIN TRANSACTION")
    var stmt: OpaquePointer?
    let sql = """
      INSERT INTO progress(profile_id, item_id, position_seconds, duration_seconds, updated_at, pending_sync)
        SELECT ?1, item_id, position_seconds, duration_seconds, updated_at, pending_sync
        FROM progress WHERE profile_id = ''
      ON CONFLICT(profile_id, item_id) DO UPDATE SET
        position_seconds=CASE WHEN excluded.pending_sync = 1 THEN excluded.position_seconds ELSE position_seconds END,
        duration_seconds=CASE WHEN excluded.pending_sync = 1 THEN excluded.duration_seconds ELSE duration_seconds END,
        updated_at=CASE WHEN excluded.pending_sync = 1 THEN excluded.updated_at ELSE updated_at END,
        pending_sync=MAX(pending_sync, excluded.pending_sync)
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      log.error("claimLegacyRows: prepare failed — \(String(cString: sqlite3_errmsg(db)))")
      exec("ROLLBACK")
      return
    }
    sqlite3_bind_text(stmt, 1, ownerID, -1, SQLITE_TRANSIENT)
    let rc = sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    guard rc == SQLITE_DONE else {
      log.error("claimLegacyRows: copy failed [\(rc)] — legacy rows kept")
      exec("ROLLBACK")
      return
    }
    exec("DELETE FROM progress WHERE profile_id = ''")
    exec("DELETE FROM sync_cursors WHERE key = 'progress_seq:'")
    exec("COMMIT")
  }

  /// Local mirror of FR-206: a deleted profile's positions and cursor leave this device.
  /// Touches nothing else: no items, no other profile.
  func deleteProfileData(profileID: String) {
    guard !profileID.isEmpty, let db else { return }
    exec("BEGIN TRANSACTION")
    for sql in ["DELETE FROM progress WHERE profile_id = ?", "DELETE FROM sync_cursors WHERE key = ?"] {
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
      let value = sql.contains("progress WHERE") ? profileID : Self.progressCursorKey(profileID)
      sqlite3_bind_text(stmt, 1, value, -1, SQLITE_TRANSIENT)
      if sqlite3_step(stmt) != SQLITE_DONE {
        log.error("deleteProfileData: step failed — \(String(cString: sqlite3_errmsg(db)))")
      }
      sqlite3_finalize(stmt)
    }
    exec("COMMIT")
  }

  /// Refuses a progress write filed under the unchosen scope. Nothing may be recorded for
  /// "no profile chosen" on a profile account: such a row would belong to nobody, and must
  /// never reach the legacy bucket the owner claims (FR-233). AppState drops these saves
  /// before they get here; this is the backstop for any other caller.
  private func refusesWrites(for profileID: String, _ site: StaticString) -> Bool {
    guard profileID == ProfileScope.unchosenID else { return false }
    log.warning("\(site): refused — no profile is chosen on this profile account")
    return true
  }

  /// Every profile id this device holds data for: progress rows (pending outbox included)
  /// and per-profile progress cursors. Excludes the legacy bucket '' (claimed by the owner,
  /// never purged here). refreshProfiles purges any id the server no longer lists (FR-206).
  func storedProfileIDs() -> Set<String> {
    guard let db else { return [] }
    let sql = """
      SELECT profile_id FROM progress WHERE profile_id <> ''
      UNION
      SELECT substr(key, length('progress_seq:') + 1) FROM sync_cursors
        WHERE key LIKE 'progress\\_seq:_%' ESCAPE '\\'
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      log.error("storedProfileIDs: prepare failed — \(String(cString: sqlite3_errmsg(db)))")
      return []
    }
    defer { sqlite3_finalize(stmt) }
    var ids = Set<String>()
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let id = colText(stmt, 0), !id.isEmpty { ids.insert(id) }
    }
    return ids
  }

  /// Items synced before the server sent `ageLevel` have NULL levels, which every read
  /// treats as unrated: a restricted profile would see nothing until each item changed.
  /// Called on every successful GET /profiles (the server has proved it sends levels): if any
  /// title is missing its level, reset the catalog cursor so the next sync re-fetches every
  /// item with its level. Resetting the cursor alone is safe (see homeForceRefresh):
  /// upsertItems is idempotent and the library stays usable throughout. Returns true when it
  /// reset the cursor.
  ///
  /// Once, not every call: a re-fetch from 0 checkpoints its cursor per page, so a title
  /// whose change_seq is below the cursor has been re-fetched. While the re-fetch is under
  /// way (or after it finished) no NULL title sits below the cursor, and this does nothing,
  /// so it never restarts a resumable re-fetch. If one DOES sit below the cursor, a sync pass
  /// that was already in flight wrote its own cursor over the reset, and the reset is
  /// re-armed. Bounded by `maxAgeLevelBackfills` so a title the server never re-sends cannot
  /// cause a full re-fetch at every launch.
  func beginAgeLevelBackfillIfNeeded() -> Bool {
    guard let db else { return false }
    guard scalarInt("SELECT 1 FROM items WHERE age_level IS NULL LIMIT 1") != nil else { return false }
    let attempts = scalarInt("SELECT value FROM sync_cursors WHERE key = 'age_level_backfill'") ?? 0
    if attempts > 0 {
      guard attempts < Self.maxAgeLevelBackfills else { return false }
      let cursor = scalarInt("SELECT value FROM sync_cursors WHERE key = 'item_seq'") ?? 0
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(
        db, "SELECT 1 FROM items WHERE age_level IS NULL AND change_seq < ?1 LIMIT 1",
        -1, &stmt, nil) == SQLITE_OK else { return false }
      sqlite3_bind_int64(stmt, 1, Int64(cursor))
      let skipped = sqlite3_step(stmt) == SQLITE_ROW
      sqlite3_finalize(stmt)
      guard skipped else { return false }
    }
    exec("BEGIN TRANSACTION")
    exec("INSERT OR REPLACE INTO sync_cursors(key, value) VALUES('item_seq', 0)")
    exec("INSERT OR REPLACE INTO sync_cursors(key, value) VALUES('age_level_backfill', \(attempts + 1))")
    exec("COMMIT")
    log.info("age-level backfill \(attempts + 1): item cursor reset so every item is re-fetched with its level")
    return true
  }
  private static let maxAgeLevelBackfills = 3

  // MARK: - Clear

  func clearAll() {
    // Wrap in a transaction so a crash mid-clear cannot corrupt sync state (TASK-438).
    exec("BEGIN TRANSACTION")
    exec("DELETE FROM items")
    exec("DELETE FROM progress")
    exec("INSERT OR REPLACE INTO sync_cursors(key, value) VALUES('item_seq', 0)")
    // Every profile's progress cursor goes with the rows (sign-out: nothing survives).
    exec("DELETE FROM sync_cursors WHERE key LIKE 'progress_seq%'")
    exec("COMMIT")
  }

  // MARK: - Helpers

  private func itemFromStatement(_ stmt: OpaquePointer?) -> ItemSummary {
    let id       = colText(stmt, 0) ?? ""
    let libId    = colText(stmt, 1)
    let type     = colText(stmt, 2) ?? "movie"
    let title    = colText(stmt, 3) ?? ""
    let year     = colOptInt(stmt, 4)
    let dur      = colOptInt(stmt, 5)
    let addedAt  = colText(stmt, 6) ?? ""
    let rating   = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_double(stmt, 7) : nil
    let poster   = colText(stmt, 8)
    let backdrop = colText(stmt, 9)
    let showName    = colText(stmt, 10)
    let showFolderId = colText(stmt, 11)
    let season      = colOptInt(stmt, 12)
    let episode     = colOptInt(stmt, 13)
    let changeSeq   = Int(sqlite3_column_int64(stmt, 14))
    let ageLevel    = colOptInt(stmt, 18)
    let contentRating = colText(stmt, 19)

    var progress: ItemProgress? = nil
    if sqlite3_column_type(stmt, 15) != SQLITE_NULL {
      let pos = Int(sqlite3_column_int(stmt, 15))
      let durP = Int(sqlite3_column_int(stmt, 16))
      let updAt = colText(stmt, 17) ?? ""
      progress = ItemProgress(positionSeconds: pos, durationSeconds: durP, updatedAt: updAt)
    }

    return ItemSummary(
      id: id, type: type, title: title, year: year,
      durationSeconds: dur, addedAt: addedAt, rating: rating,
      posterImageId: poster, backdropImageId: backdrop,
      progress: progress, showName: showName, showFolderId: showFolderId,
      seasonNumber: season, episodeNumber: episode,
      libraryId: libId, changeSeq: changeSeq,
      contentRating: contentRating, ageLevel: ageLevel
    )
  }

  private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
    guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
    return String(cString: ptr)
  }

  private func colOptInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
    guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int(stmt, col))
  }

  @discardableResult
  private func execIgnoringErrors(_ sql: String) -> Bool {
    guard let db else { return false }
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
  }

  @discardableResult
  private func exec(_ sql: String) -> Bool {
    guard let db else { return false }
    let rc = sqlite3_exec(db, sql, nil, nil, nil)
    if rc != SQLITE_OK {
      let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown error"
      log.error("SQLite exec failed [\(rc)]: \(msg) — SQL: \(sql)")
    }
    return rc == SQLITE_OK
  }

  private func execThrows(_ sql: String) throws {
    guard let db else { throw LocalStoreError.notOpen }
    var errMsg: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
      let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
      sqlite3_free(errMsg)
      throw LocalStoreError.execFailed(msg)
    }
  }
}

// MARK: - Errors

enum LocalStoreError: Error {
  case cannotLocateDocuments
  case openFailed(String)
  case notOpen
  case execFailed(String)
}
