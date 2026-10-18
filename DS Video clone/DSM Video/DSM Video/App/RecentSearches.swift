import Foundation

/// OC-1096 (FR-092): the search screen's recent searches. Newest first, one entry per phrase
/// (a repeat moves to the front, matched without regard to case), at most `capacity` kept.
///
/// A value type that owns the rules and the stored form, so ordering, de-duplication and the
/// cap are testable without the view. The view keeps `@AppStorage(RecentSearches.defaultsKey)`
/// for reactivity and runs every change through this type; both ends therefore share one key
/// and one encoding. Tests inject a `UserDefaults` suite via `init(defaults:)` / `save(to:)`.
struct RecentSearches: Equatable {
  /// The `UserDefaults` key the list is stored under (the view's `@AppStorage` uses it too).
  static let defaultsKey = "dsReel.recentSearches"
  /// The most phrases kept; adding past it drops the oldest.
  static let capacity = 10
  private static let separator = "\u{001F}"

  /// Newest first.
  private(set) var items: [String]

  init(items: [String] = []) {
    self.items = items
  }

  /// Decode the stored string. Empty segments are dropped, so "" is an empty list.
  init(raw: String) {
    self.items = raw.isEmpty ? [] : raw.components(separatedBy: Self.separator).filter { !$0.isEmpty }
  }

  /// Read the list stored in `defaults`; empty when nothing is stored.
  init(defaults: UserDefaults) {
    self.init(raw: defaults.string(forKey: Self.defaultsKey) ?? "")
  }

  /// The stored encoding of the list.
  var raw: String { items.joined(separator: Self.separator) }

  /// Record a phrase: any earlier copy (case-insensitive) goes, the phrase goes first, and the
  /// list is cut to `capacity`.
  mutating func add(_ query: String) {
    items.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
    items.insert(query, at: 0)
    if items.count > Self.capacity { items = Array(items.prefix(Self.capacity)) }
  }

  /// Forget one phrase (exact match: the row the viewer swiped is the stored text).
  mutating func remove(_ query: String) {
    items.removeAll { $0 == query }
  }

  /// Forget everything.
  mutating func clear() {
    items = []
  }

  /// Persist into `defaults` under `defaultsKey`.
  func save(to defaults: UserDefaults) {
    defaults.set(raw, forKey: Self.defaultsKey)
  }
}
