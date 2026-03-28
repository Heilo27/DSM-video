import Foundation
import os.log

// MARK: - HomeCacheEntry

struct HomeCacheEntry: Codable, Sendable {
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

enum HomeCache {
  private static let cacheFileName = "dsReel-homeCache.json"
  private static let backgroundRefreshAgeSeconds: TimeInterval = 30 * 60
  private static let maxAgeSeconds: TimeInterval = 7 * 24 * 3600

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

  static func needsRefresh(serverURL: String) -> Bool {
    guard let data = readData(),
          let entry = try? JSONDecoder().decode(HomeCacheEntry.self, from: data),
          entry.serverURL == serverURL
    else {
      log.info("needsRefresh: no valid cache — refresh needed")
      return true
    }
    let age = Date().timeIntervalSince(entry.savedAt)
    let stale = age > backgroundRefreshAgeSeconds
    log.info("needsRefresh: age=\(Int(age))s threshold=\(Int(backgroundRefreshAgeSeconds))s → \(stale ? "STALE" : "FRESH")")
    return stale
  }

  static func save(serverURL: String, libraries: [Library], items: [ItemSummary],
                   counts: [String: Int], updatedAt: [String: String]) {
    log.info("save: encoding \(items.count) items, \(libraries.count) libs")
    let entry = HomeCacheEntry(serverURL: serverURL, libraries: libraries, items: items,
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
