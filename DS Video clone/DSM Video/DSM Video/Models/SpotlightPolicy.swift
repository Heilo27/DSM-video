import Foundation

// MARK: - Spotlight index policy (FR-153, TASK-743)

/// One searchable thing in the system index: a movie, or a whole show.
///
/// Carries ONLY what Spotlight may show: a title, the year, the show name and the id of a
/// poster. Never a stream URL, a token or a file path (TRUTHS S4). The poster is an image id;
/// the indexer turns it into thumbnail bytes and keeps neither the URL nor the id.
nonisolated struct SpotlightEntry: Equatable, Sendable {
  /// The item the result opens (FR-147: its detail page). For a show this is the show's
  /// representative episode, so the same show always opens the same page.
  let id: String
  /// A movie's title, or the show's name.
  let title: String
  /// "2019" for a movie or show with a year, nil otherwise.
  let subtitle: String?
  let posterImageId: String?
  let isShow: Bool

  /// What a change to this entry means to the index. Same fingerprint = nothing to re-index.
  var fingerprint: String {
    [id, title, subtitle ?? "", posterImageId ?? "", isShow ? "show" : "movie"].joined(separator: "\u{1F}")
  }
}

/// What the system index must do to match the library.
nonisolated struct SpotlightChanges: Equatable, Sendable {
  /// Entries to (re)index: new, changed, or indexed earlier without the artwork they now can have.
  let upserts: [SpotlightEntry]
  /// Identifiers to remove.
  let deletes: [String]

  var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty }
}

/// What Spotlight may index, and how the index is brought in line with it. The ONE home of both
/// rules; the indexer (SpotlightIndexer) only carries the answer out.
///
/// Full indexing, an incremental sync and a profile switch all take the same path: compute the
/// entries the active profile may see, diff them against what was indexed (the manifest), apply
/// the difference. A profile switch is therefore not a special case: titles the new profile may
/// not see are in `deletes`, so a restricted profile's Spotlight never lists an adult title
/// that a previous profile's session indexed.
nonisolated enum SpotlightPolicy {
  /// The CoreSpotlight domain every entry lives in; deleting the domain empties the index.
  static let domainIdentifier = "com.dsm.dsvideo.library"

  /// The NSUserActivity the detail page donates (listed in Info.plist NSUserActivityTypes), and
  /// the userInfo key carrying the item id back.
  static let viewItemActivityType = "com.dsm.dsvideo.viewItem"
  static let activityItemIDKey = "itemID"

  /// Suffix on a manifest value marking an entry indexed WITH its artwork.
  static let artworkMark = "+art"

  /// The entries for `scope` out of `items`.
  ///
  /// - Unchosen scope (the account has profiles, none is chosen): nothing. It fails closed,
  ///   as every other read does (FR-221).
  /// - Visibility is `ProfileScope.allows(ageLevel:)` (FR-242), never a comparison written here.
  ///   The caller's list is normally already scope-filtered by SQL; this applies the rule again
  ///   so the policy is safe whatever list it is handed.
  /// - A movie is one entry. A show is ONE entry however many episodes are in the library,
  ///   keyed by `ItemSummary.showDedupKey`, opening its lowest season/episode (ties broken by
  ///   id, so the choice never depends on the order the list arrives in).
  /// - Sorted by id so equal libraries give equal results.
  static func entries(for items: [ItemSummary], scope: ProfileScope) -> [SpotlightEntry] {
    guard !scope.isUnchosen else { return [] }
    var movies: [SpotlightEntry] = []
    var representatives: [String: ItemSummary] = [:]
    // Episode artwork is often missing where a show-level poster exists: a show uses the poster
    // of its earliest episode that has one.
    var posters: [String: ItemSummary] = [:]
    for item in items where scope.allows(ageLevel: item.ageLevel) {
      guard !item.id.isEmpty else { continue }
      if let key = item.showDedupKey {
        if item.posterImageId != nil, posters[key].map({ isEarlier(item, than: $0) }) ?? true {
          posters[key] = item
        }
        if let current = representatives[key], !isEarlier(item, than: current) { continue }
        representatives[key] = item
      } else {
        movies.append(SpotlightEntry(
          id: item.id, title: item.title, subtitle: item.year.map(String.init),
          posterImageId: item.posterImageId, isShow: false))
      }
    }
    let shows = representatives.map { key, episode in
      SpotlightEntry(
        id: episode.id, title: showTitle(of: episode), subtitle: episode.year.map(String.init),
        posterImageId: episode.posterImageId ?? posters[key]?.posterImageId, isShow: true)
    }
    return (movies + shows).sorted { $0.id < $1.id }
  }

  /// Works out what to add, change and remove.
  /// - Parameter manifest: identifier -> the value stored when it was indexed
  ///   (`manifestValue(for:withArtwork:)`).
  static func changes(desired: [SpotlightEntry], manifest: [String: String]) -> SpotlightChanges {
    let wanted = Set(desired.map(\.id))
    let upserts = desired.filter { entry in
      guard let stored = manifest[entry.id] else { return true }
      if !stored.hasPrefix(entry.fingerprint) { return true }
      // Indexed without artwork that it can now have: index it again (the indexer caps how many
      // pictures one pass fetches, so a large library fills in over several syncs).
      return entry.posterImageId != nil && !stored.hasSuffix(artworkMark)
    }
    let deletes = manifest.keys.filter { !wanted.contains($0) }.sorted()
    return SpotlightChanges(upserts: upserts, deletes: deletes)
  }

  static func manifestValue(for entry: SpotlightEntry, withArtwork: Bool) -> String {
    entry.fingerprint + (withArtwork ? artworkMark : "")
  }

  // MARK: Private

  private static func showTitle(of episode: ItemSummary) -> String {
    if let name = episode.showName, !name.isEmpty { return name }
    return episode.title
  }

  /// Season, then episode, then id; a missing number sorts last.
  private static func isEarlier(_ a: ItemSummary, than b: ItemSummary) -> Bool {
    let left = (a.seasonNumber ?? Int.max, a.episodeNumber ?? Int.max, a.id)
    let right = (b.seasonNumber ?? Int.max, b.episodeNumber ?? Int.max, b.id)
    return left < right
  }
}
