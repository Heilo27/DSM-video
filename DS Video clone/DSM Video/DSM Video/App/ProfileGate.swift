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
  static func progressSyncAllowed(scope: ProfileScope, support: ProfileSupport) -> Bool {
    !scope.isLegacy || support == .unsupported
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
