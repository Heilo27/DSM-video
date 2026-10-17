import Foundation

/// Where the active profile's GET /collections request stands.
enum CollectionsLoadState: Equatable, Sendable {
  case notLoaded
  case loaded
  case failed
}

/// What a browse surface shows for collections (FRD-002 FR-270, FR-274, FR-276).
///
/// Which collections a profile gets is the server's decision; this only decides presentation.
/// `isKids` (Profile.isKids) picks whether collections REPLACE the genre list (kids) or are an
/// extra row (Teens and Adult), and whether an empty or failed answer is worth saying out loud:
/// for a kids' profile collections are the primary browse, so silence would be a dead end.
enum CollectionsBrowse: Equatable {
  /// Nothing rendered: offline, not loaded yet, or a non-kids profile with nothing to offer.
  case hidden
  /// Render these collections, in the server's order.
  case collections([MediaCollection])
  /// Kids' profile, server answered with no collections (FR-276).
  case noneYet
  /// Kids' profile, the request failed. Distinct from `noneYet` (AC-002-65).
  case failed

  static func decide(collections: [MediaCollection], load: CollectionsLoadState,
                     isKids: Bool, isOffline: Bool) -> CollectionsBrowse {
    // Offline: hide. Collections are never recomputed from the on-device catalog.
    if isOffline { return .hidden }
    switch load {
    case .notLoaded:
      return .hidden
    case .failed:
      return isKids ? .failed : .hidden
    case .loaded:
      if !collections.isEmpty { return .collections(collections) }
      return isKids ? .noneYet : .hidden
    }
  }

  /// Whether the genre filter is shown. Kids browse by collections instead (FR-270).
  static func showsGenres(isKids: Bool) -> Bool { !isKids }
}
