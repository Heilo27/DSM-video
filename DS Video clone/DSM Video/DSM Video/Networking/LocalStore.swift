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
    try? fm.setAttributes(
      [.protectionKey: FileProtectionType.complete],
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
    let current = (try? fm.attributesOfItem(atPath: url.path)[.protectionKey]) as? FileProtectionType
    guard current != nil, current != .none else { return }
    do {
      try fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
      log.info("cleared file protection on \(url.lastPathComponent) — was \(String(describing: current))")
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
      INSERT INTO progress(item_id, position_seconds, duration_seconds, updated_at, pending_sync)
      VALUES(?,?,?,?,0)
      ON CONFLICT(item_id) DO UPDATE SET
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
  func upsertSingleProgress(itemId: String, positionSeconds: Int, durationSeconds: Int) {
    guard let db else { return }
    var stmt: OpaquePointer?
    let sql = """
      INSERT INTO progress(item_id, position_seconds, duration_seconds, updated_at, pending_sync)
      VALUES(?,?,?,?,1)
      ON CONFLICT(item_id) DO UPDATE SET
        position_seconds=excluded.position_seconds,
        duration_seconds=excluded.duration_seconds,
        updated_at=excluded.updated_at,
        pending_sync=1
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      log.error("upsertSingleProgress: sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db)))")
      return
    }
    defer { sqlite3_finalize(stmt) }
    let now = iso8601Formatter.string(from: Date())
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 2, Int64(positionSeconds))
    sqlite3_bind_int64(stmt, 3, Int64(durationSeconds))
    sqlite3_bind_text(stmt, 4, now, -1, SQLITE_TRANSIENT)
    // FIX-3: Check return code — SQLITE_BUSY under contention was silently swallowed.
    let rc = sqlite3_step(stmt)
    if rc != SQLITE_DONE {
      let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
      log.error("upsertSingleProgress: step failed [\(rc)] for item \(itemId): \(msg)")
    }
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
  }

  /// Progress rows the server has not yet confirmed, oldest first so the flush replays in
  /// the order the user actually watched. Bounded: a device offline for a long stretch
  /// should not fire an unbounded burst at the NAS on reconnect.
  func pendingProgress(limit: Int = 200) -> [PendingProgress] {
    guard let db else { return [] }
    var stmt: OpaquePointer?
    let sql = """
      SELECT item_id, position_seconds, duration_seconds
      FROM progress
      WHERE pending_sync = 1
      ORDER BY updated_at ASC
      LIMIT ?
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(limit))
    var out: [PendingProgress] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let idC = sqlite3_column_text(stmt, 0) else { continue }
      out.append(PendingProgress(
        itemId: String(cString: idC),
        positionSeconds: Int(sqlite3_column_int64(stmt, 1)),
        durationSeconds: Int(sqlite3_column_int64(stmt, 2))
      ))
    }
    return out
  }

  /// Clears the pending flag after the server accepted this exact value.
  ///
  /// The position/duration guard matters: if the user kept watching while the flush was in
  /// flight, the row now holds a NEWER position than the one just uploaded. Clearing
  /// unconditionally would drop that newer value from the outbox and it would never be sent.
  func markProgressSynced(itemId: String, positionSeconds: Int, durationSeconds: Int) {
    guard let db else { return }
    var stmt: OpaquePointer?
    let sql = """
      UPDATE progress SET pending_sync = 0
      WHERE item_id = ? AND position_seconds = ? AND duration_seconds = ?
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 2, Int64(positionSeconds))
    sqlite3_bind_int64(stmt, 3, Int64(durationSeconds))
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
  func dropPendingProgress(itemId: String) {
    guard let db else { return }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "UPDATE progress SET pending_sync = 0 WHERE item_id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
    if sqlite3_step(stmt) != SQLITE_DONE {
      let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
      log.error("dropPendingProgress: step failed for \(itemId): \(msg)")
    }
  }

  /// Count of unsynced rows — for diagnostics and to skip a no-op flush cheaply.
  func pendingProgressCount() -> Int {
    guard let db else { return 0 }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM progress WHERE pending_sync = 1", -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
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
    let sql = "SELECT position_seconds, duration_seconds FROM progress WHERE item_id=? LIMIT 1"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
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
  private static let sqlIsFinished = """
    (\(sqlRatio) > \(PlaybackProgress.watchedThreshold) \
    OR \(sqlRemaining) < \(PlaybackProgress.finishedRemainingSeconds))
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
        -- TASK-841: upper bound now excludes the 90s-remaining case as well as the 95% ratio,
        -- so this rail agrees with PlaybackProgress.isFinished / getProgressSeconds.
        AND \(Self.sqlIsInProgress)
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
         OR \(Self.sqlRatio) < \(PlaybackProgress.startedThreshold)
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
