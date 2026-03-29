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

  /// Serial queue that serializes all file I/O — prevents touch/save races when two concurrent
  /// refresh cycles overlap (P1-3). All readData/writeData calls go through this queue.
  static let ioQueue = DispatchQueue(label: "HomeCache.io", qos: .utility)

  private static var cacheFileURL: URL {
    // Use Documents (not Caches) — the OS purges Caches under storage pressure,
    // which causes cold-start network fetches for large libraries.
    // Documents are only cleared on app uninstall.
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      preconditionFailure("HomeCache: cannot locate Documents directory — file system unavailable")
    }
    return docs.appendingPathComponent(cacheFileName)
  }

  private static func readData() -> Data? {
    ioQueue.sync { try? Data(contentsOf: cacheFileURL) }
  }

  private static func writeData(_ data: Data) {
    ioQueue.sync { try? data.write(to: cacheFileURL, options: .atomic) }
  }

  // MARK: - Combined load+staleness (P2-1: single file decode on cold start)

  /// Reads the cache file once and returns both the entry and its staleness.
  /// Callers on cold start should use this instead of calling `load` + `isStale` separately,
  /// avoiding a double file read + decode.
  static func loadWithStaleness(serverURL: String) -> (entry: HomeCacheEntry, isStale: Bool)? {
    log.debug("loadWithStaleness: reading cache file")
    guard let data = readData() else {
      log.info("loadWithStaleness: no cache — cold start")
      return nil
    }
    guard let entry = try? JSONDecoder().decode(HomeCacheEntry.self, from: data) else {
      log.error("loadWithStaleness: decode failed — cache corrupt, discarding")
      return nil
    }
    guard entry.serverURL == serverURL else {
      log.info("loadWithStaleness: server URL mismatch — ignoring stale cache")
      return nil
    }
    let age = Date().timeIntervalSince(entry.savedAt)
    guard age < maxAgeSeconds else {
      log.info("loadWithStaleness: cache expired (age=\(Int(age))s) — discarding")
      return nil
    }
    let stale = age > staleAgeSeconds
    log.info("loadWithStaleness: HIT — \(entry.items.count) items, age=\(Int(age))s, stale=\(stale)")
    return (entry, stale)
  }

  static func load(serverURL: String) -> HomeCacheEntry? {
    loadWithStaleness(serverURL: serverURL)?.entry
  }

  /// Returns true if the cache exists but is older than 24 hours — triggers a full re-fetch
  /// rather than relying solely on count/lastUpdatedAt change detection.
  static func isStale(serverURL: String) -> Bool {
    guard let result = loadWithStaleness(serverURL: serverURL) else { return false }
    log.info("isStale: → \(result.isStale ? "STALE" : "fresh")")
    return result.isStale
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
