import Foundation
import os

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
/// The Continue Watching widget (FR-154) reads one value of it, the active profile id, through
/// `ContinueWatchingSnapshotPolicy.activeProfileID(in:)` and the shared key in SharedAppGroup, so
/// it shows a snapshot only to the profile it was written for. It writes nothing here.
///
/// Also caches the account's profile list so the picker can be shown offline (FR-263), and
/// the two server levels, each the one stored home of its value: `unrestrictedLevel` (with the
/// list, GET /profiles) and `unratedLevel` (GET /profiles/age-levels). Different questions,
/// never derived from each other.
///
/// `@unchecked Sendable`: the only stored state is a `UserDefaults`, which is documented as
/// thread-safe. No other mutable state exists.
nonisolated final class ActiveProfileStore: @unchecked Sendable {
  /// The app group. Its one definition is SharedAppGroup (ContinueWatchingSnapshot.swift), which
  /// the widget also compiles; kept as a name here so existing call sites read naturally.
  static let appGroupID = SharedAppGroup.identifier
  /// The request and response header naming the profile (FR-220, FR-222).
  static let headerName = "X-DSVideo-Profile"

  /// The process-wide store. Its first use runs the one-time upgrade copy from the app-local store
  /// (`migrateFromLegacyStore`), so nothing reads the profile before that copy has happened.
  static let shared: ActiveProfileStore = {
    let store = ActiveProfileStore(defaults: UserDefaults(suiteName: appGroupID) ?? .standard)
    store.migrateFromLegacyStore(legacyValues(at: legacyAppLocalStoreURL))
    return store
  }()

  private static let log = Logger(subsystem: "com.dsm.dsvideo", category: "ActiveProfileStore")

  private enum Keys {
    /// Shared with the widget, so its one home is SharedAppGroup.
    static let activeID = SharedAppGroup.activeProfileIDKey
    static let activeMaxAgeLevel = "dsReel.profile.activeMaxAgeLevel"
    static let cachedProfiles = "dsReel.profile.cachedProfiles"
    static let unrestrictedLevel = "dsReel.profile.unrestrictedLevel"
    static let unratedLevel = "dsReel.profile.unratedLevel"
    static let ageLevels = "dsReel.profile.ageLevels"
    /// Every value this store holds for the account: what the upgrade copy carries across.
    static let profileValues = [activeID, activeMaxAgeLevel, cachedProfiles, unrestrictedLevel,
                                unratedLevel, ageLevels]
    /// Set once the upgrade copy has run in this store. Never cleared, not even by sign-out.
    static let legacyStoreMigrated = "dsReel.profile.legacyStoreMigrated"
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

  /// The ladder's display labels as GET /profiles/age-levels last stated them. Persisted so a
  /// cold launch with the NAS unreachable still names a profile's level (FR-265, OC-2186).
  /// Display only; empty before the endpoint ever answered on this device.
  var cachedAgeLevels: [AgeLevelsResponse.Level] {
    guard let data = defaults.data(forKey: Keys.ageLevels) else { return [] }
    return (try? JSONDecoder().decode([AgeLevelsResponse.Level].self, from: data)) ?? []
  }

  /// Stores the ladder after a successful fetch. An empty ladder is not an answer and keeps
  /// the last good one.
  func setCachedAgeLevels(_ levels: [AgeLevelsResponse.Level]) {
    guard !levels.isEmpty, let data = try? JSONEncoder().encode(levels) else { return }
    defaults.set(data, forKey: Keys.ageLevels)
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

  /// Sign-out: profiles belong to the account, so nothing survives it. The upgrade-copy marker is
  /// not account data and stays, so the legacy values are never copied back after a sign-out.
  func clearAll() {
    setActive(nil)
    defaults.removeObject(forKey: Keys.cachedProfiles)
    defaults.removeObject(forKey: Keys.unrestrictedLevel)
    defaults.removeObject(forKey: Keys.unratedLevel)
    defaults.removeObject(forKey: Keys.ageLevels)
  }

  // MARK: - Upgrade copy from the app-local store (FR-154, TASK-743)

  /// Where this store's values lived while the app had no App Group entitlement. Without it,
  /// `UserDefaults(suiteName: appGroupID)` is an ordinary app-local domain, kept at
  /// Library/Preferences/<suite>.plist in the app's own container. Once the entitlement is
  /// granted the same suite resolves to the group container instead and this file is no longer
  /// read by anything except `migrateFromLegacyStore`.
  static var legacyAppLocalStoreURL: URL? {
    FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Preferences/\(appGroupID).plist")
  }

  /// The values in the plist at `url`, or nil when there is none. A file that exists but cannot be
  /// read is logged and treated as none: the copy is skipped, never guessed.
  static func legacyValues(at url: URL?) -> [String: Any]? {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
      guard let values = plist as? [String: Any] else {
        log.error("legacy profile store at \(url.path, privacy: .public) is not a dictionary; not copied")
        return nil
      }
      return values
    } catch {
      log.error("legacy profile store unreadable, not copied: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// One-time upgrade copy: when the app gains the App Group entitlement (TASK-743 B2), this
  /// store's suite moves from the app-local domain to the group container, which starts empty.
  /// Without this the device would forget its profiles and active profile once, on upgrade.
  ///
  /// - Copies this store's values from `legacy` only when this store holds NONE of them, so it
  ///   never overwrites a value and never mixes two states.
  /// - Runs once per store: the first call sets a marker, and every later call returns at once. So
  ///   a sign-out after the copy (clearAll) is never undone by copying the old values back.
  /// - Only ever copies; the legacy values are left where they are.
  /// - Harmless without the entitlement: then this store IS the legacy domain, so it already holds
  ///   the values (nothing to copy) or neither has any. Its marker lands in the app-local domain,
  ///   which is the legacy file later, and is never copied across.
  ///
  /// Returns the keys copied, for tests and the log.
  @discardableResult
  func migrateFromLegacyStore(_ legacy: [String: Any]?) -> [String] {
    guard !defaults.bool(forKey: Keys.legacyStoreMigrated) else { return [] }
    defaults.set(true, forKey: Keys.legacyStoreMigrated)
    guard let legacy else { return [] }
    guard !Keys.profileValues.contains(where: { defaults.object(forKey: $0) != nil }) else { return [] }
    let copied = Keys.profileValues.filter { legacy[$0] != nil }
    for key in copied { defaults.set(legacy[key], forKey: key) }
    if !copied.isEmpty {
      Self.log.info("copied \(copied.count) profile values from the app-local store into the app group")
    }
    return copied
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
