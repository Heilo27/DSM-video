import Foundation

// MARK: - Shared with the Continue Watching widget (FR-154, TASK-743)
//
// This file is compiled by the app targets AND by the iPhone widget extension (TASK-743 B2), so it
// may use Foundation only: no ItemSummary, no ProfileScope, no AppState. What the app knows that the
// widget does not (the rail, the profile's ceiling, how progress is computed) is mapped in
// ContinueWatchingSnapshot+Rail.swift, which only the apps compile.

/// The app group and the defaults keys more than one process reads. ONE home for both: the app
/// (ActiveProfileStore, AppState's snapshot files) and the widget read them from here.
/// TopShelfExtension/TopShelfProvider.swift keeps its own copy of the identifier because that target
/// does not compile this file: it MUST match, as must every entitlements file.
nonisolated enum SharedAppGroup {
  static let identifier = "group.HeiloProjects.DSReel"

  /// The active profile's id in the group defaults. Written only by ActiveProfileStore; the widget
  /// reads it so a snapshot is shown only to the profile it was written for.
  static let activeProfileIDKey = "dsReel.profile.activeID"

  /// The group's shared container, or nil when this process does not hold the App Group
  /// entitlement (the iPhone app before TASK-743 B2).
  static func containerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }
}

/// The one shape of the link that opens an item's detail page (FR-147). The Top Shelf, the widget and
/// the app's URL handlers all speak it.
nonisolated enum ItemDeepLink {
  static func urlString(itemID: String) -> String { "dsvideo://item/\(itemID)" }
}

/// What the widget may show: the active profile's Continue Watching, as the app last saw it.
///
/// Carries only display data (title, a subtitle, a progress fraction, a poster image id and a small
/// poster picture). Never a stream URL, a token or an image address (TRUTHS S4): the widget makes no
/// network call, ever (TRUTHS A2), so everything it draws is in this file.
nonisolated struct ContinueWatchingSnapshot: Codable, Equatable, Sendable {
  nonisolated struct Entry: Codable, Equatable, Sendable {
    /// The item the entry opens (`ItemDeepLink`).
    let id: String
    /// A movie's title, or an episode's show name.
    let title: String
    /// "S2 · E4" for an episode, the year for a movie, nil when neither is known.
    let subtitle: String?
    /// How far through the item the profile is, 0...1, or nil when no ratio is meaningful.
    let progress: Double?
    /// The poster's image id: the key a thumbnail is reused under. Not an address.
    let posterImageID: String?
    /// A small poster picture (JPEG), nil until the app has fetched one.
    let thumbnail: Data?

    func withThumbnail(_ data: Data?) -> Entry {
      Entry(id: id, title: title, subtitle: subtitle, progress: progress,
            posterImageID: posterImageID, thumbnail: data)
    }
  }

  /// The server profile id the entries belong to. The widget shows nothing unless it is the
  /// profile active right now.
  let profileID: String
  let entries: [Entry]
}

/// The ONE home of the snapshot's rules: when one exists, what it holds, how it is stored, and who
/// may see it. The app's writer (AppState.writeContinueWatchingSnapshot) and the widget only carry
/// the answer out.
nonisolated enum ContinueWatchingSnapshotPolicy {
  /// The widget shows at most this many titles (a medium widget's row).
  static let maxItems = 4
  /// The WidgetKit kind the widget registers and the app reloads.
  static let widgetKind = "ContinueWatchingWidget"
  /// The file in the app group's container.
  static let fileName = "widget-continue-watching.json"

  /// Where the snapshot lives, or nil without the App Group entitlement.
  static func containerFileURL() -> URL? {
    SharedAppGroup.containerURL()?.appendingPathComponent(fileName)
  }

  /// The snapshot to store, or nil when there must be NO file:
  /// - no profile id (no profile chosen, or a server without profiles): nothing is shown, so a
  ///   widget can never show one person's history to another;
  /// - no entries: an empty rail clears the widget rather than leaving old titles advertised.
  ///
  /// Keeps the rail's order (the server's most-recent-first) and truncates to `maxItems`.
  static func snapshot(profileID: String?, entries: [ContinueWatchingSnapshot.Entry]) -> ContinueWatchingSnapshot? {
    guard let profileID, !profileID.isEmpty, !entries.isEmpty else { return nil }
    return ContinueWatchingSnapshot(profileID: profileID, entries: Array(entries.prefix(maxItems)))
  }

  /// What a reader may show from `snapshot` while `activeProfileID` is active: everything when the
  /// snapshot is that profile's, otherwise nothing. A missing active profile shows nothing.
  static func visibleEntries(_ snapshot: ContinueWatchingSnapshot?, activeProfileID: String?) -> [ContinueWatchingSnapshot.Entry] {
    guard let snapshot, let activeProfileID, !activeProfileID.isEmpty,
          snapshot.profileID == activeProfileID else { return [] }
    return Array(snapshot.entries.prefix(maxItems))
  }

  /// The active profile id as ActiveProfileStore wrote it (empty reads as none, as there).
  static func activeProfileID(in defaults: UserDefaults) -> String? {
    let id = defaults.string(forKey: SharedAppGroup.activeProfileIDKey)
    return (id?.isEmpty ?? true) ? nil : id
  }

  /// The widget's whole read: the file, checked against the active profile. No network.
  /// A missing or unreadable file shows nothing.
  static func read(from fileURL: URL, defaults: UserDefaults) -> [ContinueWatchingSnapshot.Entry] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return visibleEntries(decode(data), activeProfileID: activeProfileID(in: defaults))
  }

  /// sortedKeys: key order is otherwise unspecified, so equal snapshots could encode to different
  /// bytes and `write` would announce a change that is not one.
  static func encode(_ snapshot: ContinueWatchingSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
  }

  /// nil for anything that is not a snapshot: an unreadable file shows nothing rather than guessing.
  static func decode(_ data: Data) -> ContinueWatchingSnapshot? {
    try? JSONDecoder().decode(ContinueWatchingSnapshot.self, from: data)
  }

  /// Stores `snapshot` atomically. Returns false, writing nothing, when the file already holds these
  /// exact bytes: the rail's didSet fires on many changes that leave the widget as it was, and
  /// reloading the widget for those is wasted work.
  @discardableResult
  static func write(_ snapshot: ContinueWatchingSnapshot, to fileURL: URL) throws -> Bool {
    let data = try encode(snapshot)
    if (try? Data(contentsOf: fileURL)) == data { return false }
    try data.write(to: fileURL, options: .atomic)
    return true
  }
}
