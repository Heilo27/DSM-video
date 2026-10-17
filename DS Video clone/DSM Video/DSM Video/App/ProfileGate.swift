import Foundation

/// What this session knows about the server's profile support (FRD-002). In memory only:
/// it starts `.unknown` at every launch and sign-out, and only a `GET /profiles` answer
/// moves it. Never persisted, because a cached answer is exactly the stale belief that
/// would let a header-less write through after the server was upgraded.
nonisolated enum ProfileSupport: Equatable, Sendable {
  /// No `/profiles` answer yet this session: offline launch, failed list load, or a sync
  /// that started before the list loaded.
  case unknown
  /// The server answered 404: it predates profiles, and a header-less request is the
  /// account's only identity. Legacy behaviour is correct.
  case unsupported
  /// The server answered the list: profiles exist on this account.
  case supported
}

/// Pure decisions about when profile-scoped server traffic may run. No state, no I/O.
nonisolated enum ProfileGate {
  /// Whether progress upload, progress download and watchlist traffic may run for `scope`.
  ///
  /// A request with no `X-DSVideo-Profile` is served for the MOST RESTRICTED profile in a
  /// family account (FR-221). Progress recorded before profiles existed sits in the legacy
  /// bucket (''), so uploading it header-less files the owner's positions under a kid, and
  /// downloading header-less files the kid's positions into the bucket that
  /// `claimLegacyRows` later hands to the owner (FR-233). So with no active profile, the
  /// traffic is held until either a profile is active, or the server has proved it has no
  /// profiles at all. Held rows stay pending locally: nothing is lost, only delayed.
  ///
  /// The unchosen scope (a profile account with no profile chosen on this device) never
  /// syncs, whatever the support: it has no identity to sync as, and records nothing.
  static func progressSyncAllowed(scope: ProfileScope, support: ProfileSupport) -> Bool {
    if scope.isUnchosen { return false }
    return !scope.isLegacy || support == .unsupported
  }

  /// What a failed `GET /profiles` proves. Only a 404 proves the server predates profiles.
  /// Offline, timeout, 5xx and 401 prove nothing, so support stays unknown and the gate
  /// above stays shut. `unknown_profile` is a profile-level 404 from a server that DOES
  /// support profiles, so it is not read as "unsupported".
  static func support(afterProfilesError error: Error) -> ProfileSupport {
    switch error as? APIError {
    case .http(404)?:
      return .unsupported
    case .server(let code, let status, _)? where status == 404 && code != "unknown_profile":
      return .unsupported
    default:
      return .unknown
    }
  }
}

/// The platform rule in FR-260 differs by device, so the decision takes it as an input
/// rather than reading `#if os` itself: both rows of the table stay testable on one target.
nonisolated enum ProfilePickerPlatform: Equatable, Sendable {
  case iOS
  case tvOS

  static var current: ProfilePickerPlatform {
    #if os(tvOS)
    return .tvOS
    #else
    return .iOS
    #endif
  }
}

/// What just happened that might call for the picker (FR-260).
nonisolated enum ProfilePickerTrigger: Equatable, Sendable {
  /// The app process started with a session already stored.
  case coldLaunch
  /// A session was just created: sign-in on iOS, pairing on tvOS.
  case signedIn
  /// The app came back to the foreground after this many seconds in the background.
  case returnedFromBackground(away: TimeInterval)
  /// The user asked for "Switch profile".
  case switchRequested
}

extension ProfileGate {
  /// FR-260: tvOS asks again when the app returns after MORE than this long in the background.
  nonisolated static let tvOSPickerBackgroundThreshold: TimeInterval = 30 * 60

  /// Whether the views must show the profile picker (FR-260, AC-002-40, AC-002-40a).
  ///
  /// - `profileIDs`: the account's profiles as last known (fresh list, else the cached one).
  ///   Empty means no list is known (old server, or offline with nothing cached).
  /// - `activeID`: the remembered/active profile, if any.
  /// - `trigger`: nil for a plain validity check, e.g. after a fresh list load.
  ///
  /// A single-profile account (or no known list) never sees it. With several profiles, a
  /// missing or no-longer-listed active profile always brings it back, on both platforms.
  /// Otherwise tvOS asks at every launch, after pairing and after a long absence, while iOS
  /// keeps the remembered profile until the user asks to switch.
  nonisolated static func shouldShowPicker(
    platform: ProfilePickerPlatform,
    trigger: ProfilePickerTrigger?,
    profileIDs: [String],
    activeID: String?
  ) -> Bool {
    guard profileIDs.count > 1 else { return false }
    guard let activeID, profileIDs.contains(activeID) else { return true }
    switch trigger {
    case nil:
      return false
    case .switchRequested:
      return true
    case .coldLaunch, .signedIn:
      return platform == .tvOS
    case .returnedFromBackground(let away):
      return platform == .tvOS && away > tvOSPickerBackgroundThreshold
    }
  }
}
