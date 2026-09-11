import Foundation

/// Remembers which seasons the user has expanded or collapsed, per show.
///
/// Without this, every visit to a show re-derived expansion from scratch: open the season
/// containing the resume point, or the lowest season otherwise. Someone watching season 6
/// had to collapse 1–5 and expand 6 on *every* visit, and the app forgot immediately. A
/// choice the user made explicitly should outlive the screen that made it.
///
/// Deliberately ONE implementation shared by iOS and tvOS. The expansion rule already
/// existed twice — once per platform, written out separately — and that is exactly how the
/// iOS copy drifted into expanding every season at once, firing one episode request per
/// season on a 20-season show. The default rule and the persistence now live here, and both
/// platforms call the same function.
///
/// Storage is UserDefaults: it is small (a set of season numbers per show), per-device by
/// nature (an expansion state is a UI preference, not library data worth syncing), and
/// survives relaunch, which is the whole point.
enum SeasonExpansionStore {

  /// One entry per show. Keyed by show id so two shows never share state.
  private static func key(showID: String) -> String {
    "dsReel.seasonExpansion.\(showID)"
  }

  /// Seasons the user has explicitly expanded for this show, or nil if they have never
  /// made a choice here.
  ///
  /// nil and empty are meaningfully different: nil means "no opinion — use the default
  /// rule", while empty means "the user collapsed everything", which must be honoured.
  static func storedSelection(showID: String) -> Set<Int>? {
    guard let raw = UserDefaults.standard.array(forKey: key(showID: showID)) as? [Int] else {
      return nil
    }
    return Set(raw)
  }

  /// Records the user's choice for one season, preserving the rest.
  ///
  /// Seeds from `defaultExpanded` on the first change so that toggling season 6 does not
  /// silently collapse the season the app had opened for them — only the season they
  /// actually touched changes.
  static func setExpanded(_ expanded: Bool,
                          season: Int,
                          showID: String,
                          allSeasons: [Int],
                          highlightSeason: Int?) {
    var selection = storedSelection(showID: showID)
      ?? defaultExpandedSet(allSeasons: allSeasons, highlightSeason: highlightSeason)
    if expanded {
      selection.insert(season)
    } else {
      selection.remove(season)
    }
    UserDefaults.standard.set(Array(selection).sorted(), forKey: key(showID: showID))
  }

  /// Whether a season should start expanded: the user's stored choice when they have one,
  /// otherwise the default rule.
  ///
  /// This is THE answer for both platforms. Previously each initialiser computed it inline.
  static func isExpanded(season: Int,
                         showID: String,
                         allSeasons: [Int],
                         highlightSeason: Int?) -> Bool {
    if let stored = storedSelection(showID: showID) {
      return stored.contains(season)
    }
    return defaultExpandedSet(allSeasons: allSeasons, highlightSeason: highlightSeason).contains(season)
  }

  /// The default before the user expresses a preference: the season holding the resume
  /// point, or the lowest season when there is no resume point.
  ///
  /// Exactly ONE season, never all of them. Expanding every season makes each one fire its
  /// own episode request on appear — 20 simultaneous fetches on a long-running show, which
  /// is the bug the iOS copy of this rule shipped with.
  static func defaultExpandedSet(allSeasons: [Int], highlightSeason: Int?) -> Set<Int> {
    if let highlight = highlightSeason, allSeasons.contains(highlight) {
      return [highlight]
    }
    if let lowest = allSeasons.min() {
      return [lowest]
    }
    return []
  }

  /// Forgets a show's stored expansion. Used when signing out, so the next user does not
  /// inherit someone else's layout.
  static func clear(showID: String) {
    UserDefaults.standard.removeObject(forKey: key(showID: showID))
  }

  /// Forgets every show's stored expansion.
  static func clearAll() {
    let defaults = UserDefaults.standard
    for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("dsReel.seasonExpansion.") {
      defaults.removeObject(forKey: k)
    }
  }
}
