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
/// `offersCollections` (the server's `Profile.offersCollections`, FR-274) says whether the
/// profile gets any: kids and Teens do, Adult does not. It is checked first, whatever the
/// server sent, so an older server that still lists collections for Adult shows no row.
/// `isKids` (the server's `Profile.kids`, FR-270) picks whether collections REPLACE the genre
/// list (kids) or are an extra row (Teens), and whether an empty or failed answer is worth
/// saying out loud: for a kids' profile collections are the primary browse, so silence would
/// be a dead end.
enum CollectionsBrowse: Equatable {
  /// Nothing rendered: offline, not loaded yet, a profile offered no collections (Adult), or a
  /// Teens profile with nothing to offer.
  case hidden
  /// Render these collections, in the server's order.
  case collections([MediaCollection])
  /// Kids' profile, server answered with no collections (FR-276).
  case noneYet
  /// Kids' profile, the request failed. Distinct from `noneYet` (AC-002-65).
  case failed

  static func decide(collections: [MediaCollection], load: CollectionsLoadState,
                     isKids: Bool, offersCollections: Bool, isOffline: Bool) -> CollectionsBrowse {
    // Adult: no collections, whatever the server sent (FR-274).
    guard offersCollections else { return .hidden }
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
