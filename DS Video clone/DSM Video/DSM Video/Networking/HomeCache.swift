import Foundation
import os.log

// MARK: - HomeCacheEntry

nonisolated struct HomeCacheEntry: Codable, Sendable {
  let serverURL: String
  let libraries: [Library]
  let items: [ItemSummary]
  let savedAt: Date
  let libraryCounts: [String: Int]
  let libraryUpdatedAt: [String: String]
}

// MARK: - HomeCache
//
// Fully nonisolated — no @MainActor anywhere in this enum.
// File-based cache in the Caches directory — faster than UserDefaults for large data
// and does not bloat the UserDefaults plist.

nonisolated enum HomeCache {
  private static let cacheFileName = "dsReel-homeCache.json"
  private static let staleAgeSeconds: TimeInterval = 24 * 3600   // force full re-fetch after 24h
  private static let maxAgeSeconds: TimeInterval = 7 * 24 * 3600 // discard cache after 7 days

  private static let log = Logger(subsystem: "com.dsm.dsvideo", category: "HomeCache")

  private static var cacheFileURL: URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    return caches.appendingPathComponent(cacheFileName)
  }

  private static func readData() -> Data? {
    try? Data(contentsOf: cacheFileURL)
  }

  private static func writeData(_ data: Data) {
    try? data.write(to: cacheFileURL, options: .atomic)
  }

  /// Load cache without server URL validation — used for synchronous pre-render seeding only.
  /// The async load() path still validates serverURL and will replace data if it mismatches.
  static func loadForPrerender() -> HomeCacheEntry? {
    guard let data = readData(),
          let entry = try? JSONDecoder().decode(HomeCacheEntry.self, from: data) else { return nil }
    let age = Date().timeIntervalSince(entry.savedAt)
    guard age < maxAgeSeconds else { return nil }
    return entry
  }

  static func load(serverURL: String) -> HomeCacheEntry? {
    log.debug("load: reading cache file")
    guard let data = readData() else {
      log.info("load: no cache — cold start")
      return nil
    }
    guard let entry = try? JSONDecoder().decode(HomeCacheEntry.self, from: data) else {
      log.error("load: decode failed — cache corrupt, discarding")
      return nil
    }
    guard entry.serverURL == serverURL else {
      log.info("load: server URL mismatch — ignoring stale cache")
      return nil
    }
    let age = Date().timeIntervalSince(entry.savedAt)
    guard age < maxAgeSeconds else {
      log.info("load: cache expired (age=\(Int(age))s) — discarding")
      return nil
    }
    log.info("load: HIT — \(entry.items.count) items, \(entry.libraries.count) libs, age=\(Int(age))s")
    return entry
  }

  /// Returns true if the cache exists but is older than 24 hours — triggers a full re-fetch
  /// rather than relying solely on count/lastUpdatedAt change detection.
  static func isStale(serverURL: String) -> Bool {
    guard let data = readData(),
          let entry = try? JSONDecoder().decode(HomeCacheEntry.self, from: data),
          entry.serverURL == serverURL
    else { return false }
    let age = Date().timeIntervalSince(entry.savedAt)
    let stale = age > staleAgeSeconds
    log.info("isStale: age=\(Int(age))s threshold=\(Int(staleAgeSeconds))s → \(stale ? "STALE" : "fresh")")
    return stale
  }

  static func save(serverURL: String, libraries: [Library], items: [ItemSummary],
                   counts: [String: Int], updatedAt: [String: String]) {
    log.info("save: encoding \(items.count) items, \(libraries.count) libs")
    let strippedItems = items.map { $0.withoutProgress }
    let entry = HomeCacheEntry(serverURL: serverURL, libraries: libraries, items: strippedItems,
                               savedAt: Date(), libraryCounts: counts, libraryUpdatedAt: updatedAt)
    guard let data = try? JSONEncoder().encode(entry) else {
      log.error("save: encode failed")
      return
    }
    log.debug("save: writing \(data.count) bytes")
    writeData(data)
  }

  static func touch(serverURL: String) {
    guard let existing = load(serverURL: serverURL) else { return }
    log.info("touch: bumping savedAt")
    let updated = HomeCacheEntry(serverURL: existing.serverURL, libraries: existing.libraries,
                                 items: existing.items, savedAt: Date(),
                                 libraryCounts: existing.libraryCounts,
                                 libraryUpdatedAt: existing.libraryUpdatedAt)
    guard let data = try? JSONEncoder().encode(updated) else { return }
    writeData(data)
  }

  static func invalidate() {
    log.info("invalidate: clearing cache")
    try? FileManager.default.removeItem(at: cacheFileURL)
  }
}
