import Foundation

/// The ONE home of "which profile is this device acting for" (FR-220, FR-264).
///
/// Lives in the app-group defaults so every process that talks to the server or shows
/// library content reads the same answer: APIClient (every request), DownloadManager and
/// Trickplay (hand-built requests) and App Intents. Nothing else may cache the active profile
/// id; read it here at the moment of use.
///
/// The Top Shelf extension does NOT read this store. It reads `topshelf.json`, which the app
/// writes under the account's most restricted ceiling, independent of the active profile
/// (AppState.writeTopShelfSnapshot, TASK-923).
///
/// Also caches the account's profile list so the picker can be shown offline (FR-263), and
/// the two server levels, each the one stored home of its value: `unrestrictedLevel` (with the
/// list, GET /profiles) and `unratedLevel` (GET /profiles/age-levels). Different questions,
/// never derived from each other.
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
    static let unrestrictedLevel = "dsReel.profile.unrestrictedLevel"
    static let unratedLevel = "dsReel.profile.unratedLevel"
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

  /// The scope LocalStore filters by (see ProfileScope for the three kinds):
  /// - a chosen profile -> that profile;
  /// - none chosen, but a profile list is known -> unchosen: fail closed at the most
  ///   restricted cached profile's ceiling, mirroring the server's header-less rule (FR-221);
  /// - none chosen and no list ever seen -> legacy (pre-profile server, FR-233 hand-over).
  var activeScope: ProfileScope {
    let unrated = unratedLevel
    if let id = activeProfileID {
      // A missing ceiling on a known profile must fail closed, not open (FR-242).
      let level = defaults.object(forKey: Keys.activeMaxAgeLevel) as? Int ?? 1
      return ProfileScope(id: id, maxAgeLevel: level, unratedLevel: unrated)
    }
    if let ceiling = cachedProfiles.map(\.maxAgeLevel).min() {
      return .unchosen(maxAgeLevel: ceiling, unratedLevel: unrated)
    }
    return .legacy(unrestrictedLevel: unrestrictedLevel, unratedLevel: unrated)
  }

  /// The ladder's top level as the server last stated it with the profile list. Answers only
  /// "is this profile restricted" (maxAgeLevel below it); never the level of an unrated title.
  /// Offline-safe: persisted with the cached list. Before any list was ever cached it is
  /// ProfilesResponse.fallbackUnrestrictedLevel.
  var unrestrictedLevel: Int {
    let stored = defaults.object(forKey: Keys.unrestrictedLevel) as? Int ?? 0
    return stored >= 1 ? stored : ProfilesResponse.fallbackUnrestrictedLevel
  }

  /// The level a title with no level counts as (FR-242), as GET /profiles/age-levels last
  /// stated it. Offline-safe: persisted. Before that endpoint ever answered on this device it
  /// is AgeLevelsResponse.fallbackUnratedLevel.
  var unratedLevel: Int {
    let stored = defaults.object(forKey: Keys.unratedLevel) as? Int ?? 0
    return stored >= 1 ? stored : AgeLevelsResponse.fallbackUnratedLevel
  }

  /// Stores the server's unrated level (AppState.loadAgeLevelsIfNeeded, on success). A
  /// non-positive level is not a ladder level and is ignored, keeping the last good value.
  func setUnratedLevel(_ level: Int) {
    guard level >= 1 else { return }
    defaults.set(level, forKey: Keys.unratedLevel)
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

  /// Caches the list and, when given, the server's ladder top from the same response.
  /// `unrestrictedLevel` nil keeps the stored value (callers that only reshape the list).
  /// A non-positive level is not a ladder and is ignored, keeping the last good value.
  func setCachedProfiles(_ profiles: [Profile], unrestrictedLevel: Int? = nil) {
    if profiles.isEmpty {
      defaults.removeObject(forKey: Keys.cachedProfiles)
    } else if let data = try? JSONEncoder().encode(profiles) {
      defaults.set(data, forKey: Keys.cachedProfiles)
    }
    if let unrestrictedLevel, unrestrictedLevel >= 1 {
      defaults.set(unrestrictedLevel, forKey: Keys.unrestrictedLevel)
    }
  }

  /// Sign-out: profiles belong to the account, so nothing survives it.
  func clearAll() {
    setActive(nil)
    defaults.removeObject(forKey: Keys.cachedProfiles)
    defaults.removeObject(forKey: Keys.unrestrictedLevel)
    defaults.removeObject(forKey: Keys.unratedLevel)
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
