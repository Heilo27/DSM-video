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
    let store = LocalStore()
    Task { await store.setupLogged() }
    return store
  }()

  private var db: OpaquePointer?
  private var isReady: Bool = false
  private var readyContinuations: [CheckedContinuation<Void, Never>] = []
  private let log = Logger(subsystem: "com.dsm.dsvideo", category: "LocalStore")
  // Shared formatter — ISO8601DateFormatter is expensive to allocate; reuse per instance (TASK-427).
  private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  private init() {}

  // Called once at startup. Using a separate async method avoids the actor-isolation
  // restriction on calling isolated methods from a synchronous init.
  // setupLogged wraps setup() so errors are logged rather than silently swallowed.
  func setupLogged() async {
    // Read the legacy JSON cache file off-actor before acquiring the actor for setup
    // so the blocking Data(contentsOf:) call doesn't hold the actor thread (TASK-506).
    let jsonCacheData: (url: URL, data: Data)? = await Task.detached(priority: .utility) {
      guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
      let jsonURL = docs.appendingPathComponent("dsReel-homeCache.json")
      guard FileManager.default.fileExists(atPath: jsonURL.path),
            let data = try? Data(contentsOf: jsonURL) else { return nil }
      return (url: jsonURL, data: data)
    }.value
    do {
      try setup(jsonCacheData: jsonCacheData)
    } catch {
      log.error("LocalStore.setup failed: \(error.localizedDescription)")
    }
    // Signal all callers that are waiting on ensureReady().
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

  private func openDatabase() throws {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      throw LocalStoreError.cannotLocateDocuments
    }
    let dbURL = docs.appendingPathComponent("dsreel.db")
    if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
      throw LocalStoreError.openFailed(String(cString: sqlite3_errmsg(db)))
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
  }

  private func applyFileProtection(to url: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    try? fm.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: url.path
    )
  }

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
                        season_number, episode_number, change_seq)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        change_seq=excluded.change_seq
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
      if let year = item.year { sqlite3_bind_int(stmt, 5, Int32(year)) } else { sqlite3_bind_null(stmt, 5) }
      if let dur = item.durationSeconds { sqlite3_bind_int(stmt, 6, Int32(dur)) } else { sqlite3_bind_null(stmt, 6) }
      sqlite3_bind_text(stmt, 7, item.addedAt, -1, SQLITE_TRANSIENT)
      if let r = item.rating { sqlite3_bind_double(stmt, 8, r) } else { sqlite3_bind_null(stmt, 8) }
      if let p = item.posterImageId { sqlite3_bind_text(stmt, 9, p, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
      if let b = item.backdropImageId { sqlite3_bind_text(stmt, 10, b, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 10) }
      if let s = item.showName { sqlite3_bind_text(stmt, 11, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 11) }
      if let f = item.showFolderId { sqlite3_bind_text(stmt, 12, f, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 12) }
      if let sn = item.seasonNumber { sqlite3_bind_int(stmt, 13, Int32(sn)) } else { sqlite3_bind_null(stmt, 13) }
      if let en = item.episodeNumber { sqlite3_bind_int(stmt, 14, Int32(en)) } else { sqlite3_bind_null(stmt, 14) }
      sqlite3_bind_int64(stmt, 15, Int64(item.changeSeq ?? 0))
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

  func upsertProgress(_ progress: [String: ItemProgress]) {
    guard !progress.isEmpty, let db else { return }
    exec("BEGIN TRANSACTION")
    // FIX-8: Only overwrite position if the incoming server timestamp is newer than what's
    // stored locally. This prevents a reconnect sync from reverting offline-recorded progress.
    // Strategy: INSERT new rows unconditionally; for conflicts, only update position/duration
    // when the incoming updated_at is strictly newer than the stored value.
    let sql = """
      INSERT INTO progress(item_id, position_seconds, duration_seconds, updated_at)
      VALUES(?,?,?,?)
      ON CONFLICT(item_id) DO UPDATE SET
        position_seconds=CASE WHEN excluded.updated_at > updated_at THEN excluded.position_seconds ELSE position_seconds END,
        duration_seconds=CASE WHEN excluded.updated_at > updated_at THEN excluded.duration_seconds ELSE duration_seconds END,
        updated_at=CASE WHEN excluded.updated_at > updated_at THEN excluded.updated_at ELSE updated_at END
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
      sqlite3_bind_int(stmt, 2, Int32(p.positionSeconds))
      sqlite3_bind_int(stmt, 3, Int32(p.durationSeconds))
      sqlite3_bind_text(stmt, 4, p.updatedAt, -1, SQLITE_TRANSIENT)
      // FIX-3: Check return code — SQLITE_BUSY under contention was silently swallowed.
      let rc = sqlite3_step(stmt)
      if rc != SQLITE_DONE {
        let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
        log.error("upsertProgress: step failed [\(rc)] for item \(itemId): \(msg)")
      }
    }
    exec("COMMIT")
  }

  func upsertSingleProgress(itemId: String, positionSeconds: Int, durationSeconds: Int) {
    guard let db else { return }
    var stmt: OpaquePointer?
    let sql = """
      INSERT INTO progress(item_id, position_seconds, duration_seconds, updated_at)
      VALUES(?,?,?,?)
      ON CONFLICT(item_id) DO UPDATE SET
        position_seconds=excluded.position_seconds,
        duration_seconds=excluded.duration_seconds,
        updated_at=excluded.updated_at
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      log.error("upsertSingleProgress: sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db)))")
      return
    }
    defer { sqlite3_finalize(stmt) }
    let now = iso8601Formatter.string(from: Date())
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(stmt, 2, Int32(positionSeconds))
    sqlite3_bind_int(stmt, 3, Int32(durationSeconds))
    sqlite3_bind_text(stmt, 4, now, -1, SQLITE_TRANSIENT)
    // FIX-3: Check return code — SQLITE_BUSY under contention was silently swallowed.
    let rc = sqlite3_step(stmt)
    if rc != SQLITE_DONE {
      let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
      log.error("upsertSingleProgress: step failed [\(rc)] for item \(itemId): \(msg)")
    }
  }

  func getProgressSeconds(itemId: String) -> Int {
    guard let db else { return 0 }
    var stmt: OpaquePointer?
    let sql = "SELECT position_seconds FROM progress WHERE item_id=? LIMIT 1"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(stmt, 0))
  }

  // MARK: - Rails Queries

  // Shared 18-column projection used by all three rail queries.
  private static let itemSelectColumns = """
    i.id, i.library_id, i.type, i.title, i.year, i.duration_seconds,
    i.added_at, i.rating, i.poster_image_id, i.backdrop_image_id,
    i.show_name, i.show_folder_id, i.season_number, i.episode_number, i.change_seq,
    p.position_seconds, p.duration_seconds, p.updated_at
    """

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
      JOIN progress p ON p.item_id = i.id
      WHERE p.duration_seconds > 0
        -- FIX-11: unified 5% lower threshold matches iOS computeHomeRails (was 0.02, tvOS diverged)
        AND CAST(p.position_seconds AS REAL) / p.duration_seconds BETWEEN 0.05 AND 0.95
      ORDER BY p.updated_at DESC
      LIMIT 20
    """
    return fetchItems(sql: sql, deduplicateByShow: true, maxCount: 10)
  }

  private func queryJustAdded() -> [ItemSummary] {
    // Show recently-added items that have not been started (< 5% watched).
    // Mirrors the iOS home rail: exclude in-progress (>= 5%) and fully-watched (>= 95%)
    // items, which belong in Continue Watching / Recently Watched respectively.
    let sql = """
      SELECT \(Self.itemSelectColumns)
      FROM items i
      LEFT JOIN progress p ON p.item_id = i.id
      WHERE p.item_id IS NULL
         OR p.duration_seconds = 0
         OR CAST(p.position_seconds AS REAL) / p.duration_seconds < 0.05
      ORDER BY i.added_at DESC
      LIMIT 500
    """
    var items = fetchItems(sql: sql, deduplicateByShow: true, maxCount: 8)
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
      JOIN progress p ON p.item_id = i.id
      WHERE p.duration_seconds > 0
        AND CAST(p.position_seconds AS REAL) / p.duration_seconds >= 0.95
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

    var results: [ItemSummary] = []
    var seenShows = Set<String>()

    while sqlite3_step(stmt) == SQLITE_ROW {
      let item = itemFromStatement(stmt)

      if deduplicateByShow {
        // Deduplicate by show_name when available, fall back to show_folder_id.
        // show_name may be null for shows where TMDb metadata was never fetched.
        if let key = (item.showName ?? item.showFolderId).map({ $0.lowercased() }) {
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
      LEFT JOIN progress p ON p.item_id = i.id
      WHERE i.library_id = ?
      ORDER BY i.added_at DESC
      LIMIT ?
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, libraryId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(stmt, 2, Int32(limit))
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

  // MARK: - Sync Cursors

  func getSyncCursors() -> SyncCursors {
    guard let db else { return SyncCursors(itemSeq: 0, progressSeq: 0) }
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
      else if key == "progress_seq" { progressSeq = val }
    }
    return SyncCursors(itemSeq: itemSeq, progressSeq: progressSeq)
  }

  func setSyncCursors(_ cursors: SyncCursors) {
    guard let db else { return }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_cursors(key, value) VALUES(?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    for (key, val) in [("item_seq", cursors.itemSeq), ("progress_seq", cursors.progressSeq)] {
      sqlite3_reset(stmt)
      sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
      sqlite3_bind_int64(stmt, 2, Int64(val))
      sqlite3_step(stmt)
    }
  }

  func setItemSeq(_ seq: Int) {
    guard let db else { return }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_cursors(key, value) VALUES('item_seq', ?)", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(seq))
    sqlite3_step(stmt)
  }

  func setProgressSeq(_ seq: Int) {
    guard let db else { return }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_cursors(key, value) VALUES('progress_seq', ?)", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(seq))
    sqlite3_step(stmt)
  }

  // MARK: - Clear

  func clearAll() {
    // Wrap in a transaction so a crash mid-clear cannot corrupt sync state (TASK-438).
    exec("BEGIN TRANSACTION")
    exec("DELETE FROM items")
    exec("DELETE FROM progress")
    exec("INSERT OR REPLACE INTO sync_cursors(key, value) VALUES('item_seq', 0)")
    exec("INSERT OR REPLACE INTO sync_cursors(key, value) VALUES('progress_seq', 0)")
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
      libraryId: libId, changeSeq: changeSeq
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
