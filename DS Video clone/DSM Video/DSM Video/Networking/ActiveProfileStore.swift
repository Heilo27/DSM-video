import Foundation

/// The ONE home of "which profile is this device acting for" (FR-220, FR-264).
///
/// Lives in the app-group defaults so every process that talks to the server or shows
/// library content reads the same answer: APIClient (every request), DownloadManager and
/// Trickplay (hand-built requests), App Intents, and the Top Shelf extension. Nothing else
/// may cache the active profile id; read it here at the moment of use.
///
/// Also caches the account's profile list so the picker can be shown offline (FR-263).
///
/// `@unchecked Sendable`: the only stored state is a `UserDefaults`, which is documented as
/// thread-safe. No other mutable state exists.
nonisolated final class ActiveProfileStore: @unchecked Sendable {
  static let appGroupID = "group.HeiloProjects.DSReel"
  /// The request and response header naming the profile (FR-220, FR-222).
  static let headerName = "X-DSVideo-Profile"

  static let shared = ActiveProfileStore(
    defaults: UserDefaults(suiteName: appGroupID) ?? .standard)

  private enum Keys {
    static let activeID = "dsReel.profile.activeID"
    static let activeMaxAgeLevel = "dsReel.profile.activeMaxAgeLevel"
    static let cachedProfiles = "dsReel.profile.cachedProfiles"
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// The active profile's id, or nil when none is chosen (or the server predates profiles).
  var activeProfileID: String? {
    let id = defaults.string(forKey: Keys.activeID)
    return (id?.isEmpty ?? true) ? nil : id
  }

  /// The scope LocalStore filters by. With no active profile this is the legacy scope.
  var activeScope: ProfileScope {
    guard let id = activeProfileID else { return .legacy }
    // A missing ceiling on a known profile must fail closed, not open (FR-242).
    let level = defaults.object(forKey: Keys.activeMaxAgeLevel) as? Int ?? 1
    return ProfileScope(id: id, maxAgeLevel: level)
  }

  /// Sets (or clears, with nil) the active profile.
  func setActive(_ profile: Profile?) {
    if let profile {
      defaults.set(profile.id, forKey: Keys.activeID)
      defaults.set(profile.maxAgeLevel, forKey: Keys.activeMaxAgeLevel)
    } else {
      defaults.removeObject(forKey: Keys.activeID)
      defaults.removeObject(forKey: Keys.activeMaxAgeLevel)
    }
  }

  /// Last profile list the server returned, for the offline picker (FR-263).
  var cachedProfiles: [Profile] {
    guard let data = defaults.data(forKey: Keys.cachedProfiles) else { return [] }
    return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
  }

  func setCachedProfiles(_ profiles: [Profile]) {
    if profiles.isEmpty {
      defaults.removeObject(forKey: Keys.cachedProfiles)
    } else if let data = try? JSONEncoder().encode(profiles) {
      defaults.set(data, forKey: Keys.cachedProfiles)
    }
  }

  /// Sign-out: profiles belong to the account, so nothing survives it.
  func clearAll() {
    setActive(nil)
    defaults.removeObject(forKey: Keys.cachedProfiles)
  }

  /// Adds the profile header to a hand-built request (downloads, trickplay). APIClient
  /// requests get it through `APIClient.profileHeader`; both end here.
  func applyHeader(to request: inout URLRequest) {
    Self.setHeader(activeProfileID, on: &request)
  }

  /// nil sends no header: the server then resolves the profile by FR-221.
  static func setHeader(_ profileID: String?, on request: inout URLRequest) {
    if let profileID, !profileID.isEmpty {
      request.setValue(profileID, forHTTPHeaderField: headerName)
    }
  }
}

extension Notification.Name {
  /// Posted when the server answers `unknown_profile` (FR-206, FR-220): the profile the
  /// request named is gone. `object` is the profile id that was sent (String), if any.
  nonisolated static let activeProfileRejected = Notification.Name("dsReel.activeProfileRejected")
}
