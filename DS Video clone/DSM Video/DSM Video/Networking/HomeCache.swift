import Foundation

// MARK: - HomeCacheEntry
//
// LEGACY FORMAT — read-only, kept solely for one-time migration.
//
// This was the payload of the old JSON-file home cache. `LocalStore` replaced that cache
// with an indexed SQLite store (see LocalStore.swift), and the `HomeCache` enum that read
// and wrote this file — `load`, `save`, `touch`, `invalidate`, `isStale`, `cacheFileExists`
// — has had zero callers since. It was deleted; only the shape survives, because
// LocalStore still decodes an existing on-disk file once when migrating a user forward
// (LocalStore.swift:262).
//
// The removed `touch()` is worth remembering if anyone is tempted to restore this:
// it rewrote `savedAt` to now WITHOUT refetching, which permanently defeated both the
// 24-hour staleness check and the 7-day expiry.
//
// Do not add new writers. When the migration path is eventually dropped, this goes too.

nonisolated struct HomeCacheEntry: Codable, Sendable {
  let serverURL: String
  let libraries: [Library]
  let items: [ItemSummary]
  let savedAt: Date
  let libraryCounts: [String: Int]
  let libraryUpdatedAt: [String: String]
}
