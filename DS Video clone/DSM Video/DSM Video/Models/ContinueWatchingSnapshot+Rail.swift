import Foundation

// App-only half of the widget snapshot (FR-154). The widget does not compile this file: it maps the
// app's Continue Watching rail into snapshot entries using types the widget never sees.

extension ContinueWatchingSnapshotPolicy {
  /// The entries for `scope` out of the Continue Watching rail, in rail order, without thumbnails.
  ///
  /// - Only a chosen profile gets entries. Unchosen (the account has profiles, none chosen) fails
  ///   closed as every other read does (FR-221); legacy (a server without profiles) has no profile
  ///   to scope the widget to, so it shows nothing rather than an unscoped history.
  /// - Visibility is `ProfileScope.allows(ageLevel:)` (FR-242), never a comparison written here.
  ///   The rail is already filtered for the profile; this applies the rule again so the policy is
  ///   safe whatever list it is handed.
  /// - Progress is `PlaybackProgress.fraction`, the one position/duration division.
  ///
  /// Truncation to `maxItems` is `snapshot(profileID:entries:)`'s, not this function's.
  nonisolated static func entries(from rail: [ItemSummary], scope: ProfileScope) -> [ContinueWatchingSnapshot.Entry] {
    guard !scope.isLegacy, !scope.isUnchosen else { return [] }
    return rail
      .filter { !$0.id.isEmpty && scope.allows(ageLevel: $0.ageLevel) }
      .map(entry(for:))
  }

  nonisolated static func entry(for item: ItemSummary) -> ContinueWatchingSnapshot.Entry {
    let progress = item.progress.flatMap {
      PlaybackProgress.fraction(positionSeconds: $0.positionSeconds, durationSeconds: $0.durationSeconds)
    }
    return ContinueWatchingSnapshot.Entry(
      id: item.id, title: title(for: item), subtitle: subtitle(for: item), progress: progress,
      posterImageID: item.posterImageId, thumbnail: nil)
  }

  /// An episode reads as its show: `title` is often filename-derived, and the show is what a person
  /// recognises on a Home Screen. Everything else is its title.
  nonisolated static func title(for item: ItemSummary) -> String {
    if item.type == "episode", let show = item.showName, !show.isEmpty { return show }
    return item.title
  }

  /// "S2 · E4" for an episode (or the part the server supplied), the year for a movie. Same wording
  /// as the detail page's episode badge (ItemDetailView); that badge is a view-local copy, so a
  /// change to one should be checked against the other.
  nonisolated static func subtitle(for item: ItemSummary) -> String? {
    guard item.type == "episode" else { return item.year.map(String.init) }
    switch (item.seasonNumber, item.episodeNumber) {
    case let (s?, e?): return "S\(s) \u{00B7} E\(e)"
    case let (s?, nil): return "Season \(s)"
    case let (nil, e?): return "Episode \(e)"
    case (nil, nil): return nil
    }
  }
}
