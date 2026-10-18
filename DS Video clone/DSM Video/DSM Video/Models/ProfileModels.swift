import Foundation

// MARK: - Profiles (FRD-002, docs/api/ProfilesAPI.md)
//
// Shared by the iOS and tvOS targets. The server owns every rule here: the ladder, the
// unrated rule, who counts as a kid, the profile limit and PIN checks. The client reads the
// server's answers (`Profile.kids`, `ProfilesResponse.unrestrictedLevel`,
// `AgeLevelsResponse.unratedLevel`) and never derives them from a level number of its own
// (ADR-001).
//
// Two server levels, two questions, never derived from each other (both 4 today):
//  - unrestrictedLevel (GET /profiles): "is this profile restricted?" = maxAgeLevel below it.
//  - unratedLevel (GET /profiles/age-levels): the level a title with no level counts as.
//
// The client's whole visibility check is `(item.ageLevel ?? unrated) <= profile.maxAgeLevel`
// (FR-242). It runs in two places that must agree, because SQL cannot call Swift:
//  - LocalStore.sqlVisibleToScope: every offline read (rails, catalog, resume positions).
//  - ProfileScope.allows(ageLevel:): the Swift form, for lists that never touch SQLite
//    (downloads, the Top Shelf snapshot).
// (The Top Shelf extension re-checks with a copy, TopShelfCeiling.allows in
// TopShelfProvider.swift, because that target cannot compile this file.)
// ProfileScopeFixTests pins the two to the same answer for every level and for NULL.

/// One viewer within an account (FR-203). The PIN itself is never sent, only `hasPin`.
nonisolated struct Profile: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  /// Opaque key from the apps' built-in avatar set.
  let avatar: String
  /// A level on the server's ladder (1...`ProfilesResponse.unrestrictedLevel`). The owner is
  /// always the unrestricted level (FR-204).
  let maxAgeLevel: Int
  let hasPin: Bool
  let isOwner: Bool
  let createdAt: String?
  /// The server's answer to "is this a kids' profile" (FR-270): kids browse by collections in
  /// place of genres. Computed on the server from its one threshold; the client holds none.
  let kids: Bool

  init(id: String, name: String, avatar: String, maxAgeLevel: Int,
       hasPin: Bool, isOwner: Bool, createdAt: String? = nil, kids: Bool = false) {
    self.id = id
    self.name = name
    self.avatar = avatar
    self.maxAgeLevel = maxAgeLevel
    self.hasPin = hasPin
    self.isOwner = isOwner
    self.createdAt = createdAt
    self.kids = kids
  }

  /// Restricted = below the ladder's top (FRD-002 §1). The top comes from the server, stored
  /// once in ActiveProfileStore. Whether an unrated title shows is a separate question
  /// (ProfileScope.allows, with the server's unrated level).
  var isRestricted: Bool { isRestricted(in: .shared) }

  /// The one rule behind `isRestricted`, against an explicit store (tests pass an isolated one).
  func isRestricted(in store: ActiveProfileStore) -> Bool { maxAgeLevel < store.unrestrictedLevel }
}

/// GET /profiles
nonisolated struct ProfilesResponse: Codable, Sendable {
  let maxProfiles: Int
  let activeProfileId: String?
  let profiles: [Profile]
  /// The ladder's top level: a profile below it is restricted (FRD-002 §1). Answers ONLY that
  /// question; the level of an unrated title is `AgeLevelsResponse.unratedLevel`, a separate
  /// server value. Stored in ActiveProfileStore with the cached list; nothing in the client
  /// writes the number itself.
  let unrestrictedLevel: Int

  /// Fallback for a server that does not send `unrestrictedLevel` (one that predates the
  /// field): the top of the FRD-002 §6 ladder at the time profiles shipped. Also what
  /// ActiveProfileStore answers before any list was ever cached. A current server always sends
  /// the field, so a new tier needs no client release (ADR-001). One of the client's two
  /// literal ladder levels; the other is AgeLevelsResponse.fallbackUnratedLevel.
  static let fallbackUnrestrictedLevel = 4
}

// Missing-field defaults for the two server-owned values live here and nowhere else.
// In extensions so the memberwise initializers stay available.
nonisolated extension Profile {
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(String.self, forKey: .id),
      name: try c.decode(String.self, forKey: .name),
      avatar: try c.decode(String.self, forKey: .avatar),
      maxAgeLevel: try c.decode(Int.self, forKey: .maxAgeLevel),
      hasPin: try c.decode(Bool.self, forKey: .hasPin),
      isOwner: try c.decode(Bool.self, forKey: .isOwner),
      createdAt: try c.decodeIfPresent(String.self, forKey: .createdAt),
      // Missing `kids` (a server that predates the field, or a list cached by an older build)
      // -> false: browse falls back to genres. A UI mode only; the server still enforces the
      // ceiling, so nothing becomes visible that should not.
      kids: try c.decodeIfPresent(Bool.self, forKey: .kids) ?? false)
  }
}

nonisolated extension ProfilesResponse {
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      maxProfiles: try c.decode(Int.self, forKey: .maxProfiles),
      activeProfileId: try c.decodeIfPresent(String.self, forKey: .activeProfileId),
      profiles: try c.decode([Profile].self, forKey: .profiles),
      // Missing `unrestrictedLevel` -> the documented fallback (older server only).
      unrestrictedLevel: try c.decodeIfPresent(Int.self, forKey: .unrestrictedLevel)
        ?? Self.fallbackUnrestrictedLevel)
  }
}

/// GET /profiles/age-levels: the ladder, for display only. Clients never re-implement it.
nonisolated struct AgeLevelsResponse: Codable, Sendable {
  struct Level: Codable, Hashable, Sendable {
    let level: Int
    let key: String
    let label: String
    let movie: [String]
    let tv: [String]
  }
  /// The level a title with no level counts as (FR-242). Not the ladder's top: that is
  /// `ProfilesResponse.unrestrictedLevel`, a different question. Persisted in
  /// ActiveProfileStore for offline reads.
  let unratedLevel: Int
  let levels: [Level]

  /// FRD-002 §6 unrated level when profiles shipped. Used only before /profiles/age-levels has
  /// ever answered on this device (ActiveProfileStore.unratedLevel); never derived from, nor
  /// used as, the unrestricted level. The client's other literal ladder level is
  /// ProfilesResponse.fallbackUnrestrictedLevel.
  static let fallbackUnratedLevel = 4
}

/// POST /profiles. `pin` nil = no PIN.
nonisolated struct CreateProfileRequest: Encodable, Sendable {
  let ownerPin: String
  let name: String
  let avatar: String
  let maxAgeLevel: Int
  let pin: String?

  // Explicit so `pin: null` is sent rather than the key being dropped.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(ownerPin, forKey: .ownerPin)
    try c.encode(name, forKey: .name)
    try c.encode(avatar, forKey: .avatar)
    try c.encode(maxAgeLevel, forKey: .maxAgeLevel)
    try c.encode(pin, forKey: .pin)
  }
  private enum CodingKeys: String, CodingKey { case ownerPin, name, avatar, maxAgeLevel, pin }
}

/// What to change about a profile. Only the fields that are set are sent (PATCH semantics).
nonisolated enum PinChange: Equatable, Sendable {
  case set(String)
  case clear
}

/// PATCH /profiles/{id}. `ownerPin` nil is only valid when setting the owner's FIRST PIN.
nonisolated struct UpdateProfileRequest: Encodable, Sendable {
  var ownerPin: String?
  var name: String?
  var avatar: String?
  var maxAgeLevel: Int?
  var pin: PinChange?

  init(ownerPin: String?, name: String? = nil, avatar: String? = nil,
       maxAgeLevel: Int? = nil, pin: PinChange? = nil) {
    self.ownerPin = ownerPin
    self.name = name
    self.avatar = avatar
    self.maxAgeLevel = maxAgeLevel
    self.pin = pin
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(ownerPin, forKey: .ownerPin)
    try c.encodeIfPresent(name, forKey: .name)
    try c.encodeIfPresent(avatar, forKey: .avatar)
    try c.encodeIfPresent(maxAgeLevel, forKey: .maxAgeLevel)
    switch pin {
    case .set(let value): try c.encode(value, forKey: .pin)
    case .clear: try c.encodeNil(forKey: .pin)   // "pin": null clears it
    case nil: break
    }
  }
  private enum CodingKeys: String, CodingKey { case ownerPin, name, avatar, maxAgeLevel, pin }
}

nonisolated struct OwnerPinBody: Encodable, Sendable { let ownerPin: String }
nonisolated struct PinBody: Encodable, Sendable { let pin: String }
nonisolated struct OwnerPinResetRequest: Encodable, Sendable {
  let password: String
  let otp: String?
  let newPin: String
}
nonisolated struct OKResponse: Decodable, Sendable { let ok: Bool }

// MARK: - ProfileScope

/// Which profile's data the device is reading and writing, and its age ceiling.
///
/// Three kinds, decided by ActiveProfileStore.activeScope:
/// - a chosen profile: `id` is the server profile id.
/// - legacy (`id == ""`): no profile list has ever been seen. A server that predates profiles
///   (no header is sent), and the bucket that progress recorded before the v3 migration lives
///   in until the owner's id is known (FR-233). Unfiltered.
/// - unchosen: the account HAS profiles but none is chosen on this device (picker pending,
///   or the remembered one was deleted). Fails closed: it reads no progress, writes none, is
///   never claimed by the owner, sends no header, and its ceiling is the most restricted
///   profile's, which is what the server serves a header-less request (FR-221).
nonisolated struct ProfileScope: Equatable, Hashable, Sendable {
  /// The ladder's top as last stated by the server. Reads the one stored home; kept as a
  /// name here so existing call sites read naturally.
  static var unrestrictedLevel: Int { ActiveProfileStore.shared.unrestrictedLevel }
  /// Legacy scope under the stored levels.
  static var legacy: ProfileScope {
    legacy(unrestrictedLevel: ActiveProfileStore.shared.unrestrictedLevel,
           unratedLevel: ActiveProfileStore.shared.unratedLevel)
  }

  /// Unfiltered: the ceiling is whichever of the two levels is higher, so neither a title at
  /// the ladder's top nor an unrated one is hidden. Equal today; never assumed equal.
  static func legacy(unrestrictedLevel: Int = ActiveProfileStore.shared.unrestrictedLevel,
                     unratedLevel: Int) -> ProfileScope {
    ProfileScope(id: "", maxAgeLevel: max(unrestrictedLevel, unratedLevel),
                 unratedLevel: unratedLevel)
  }

  /// Not a server id: server ids are "pf_" + base62, so this can never match a stored row,
  /// a cursor of a real profile, or the legacy bucket. LocalStore refuses to write under it.
  static let unchosenID = "#unchosen"

  static func unchosen(maxAgeLevel: Int, unratedLevel: Int) -> ProfileScope {
    ProfileScope(id: unchosenID, maxAgeLevel: maxAgeLevel, unratedLevel: unratedLevel)
  }

  let id: String
  let maxAgeLevel: Int
  /// The level a title with no level counts as (FR-242), from GET /profiles/age-levels.
  /// Not the unrestricted level (ActiveProfileStore keeps the two apart).
  let unratedLevel: Int

  init(id: String, maxAgeLevel: Int,
       unratedLevel: Int = ActiveProfileStore.shared.unratedLevel) {
    self.id = id
    self.maxAgeLevel = maxAgeLevel
    self.unratedLevel = unratedLevel
  }

  init(profile: Profile, unratedLevel: Int = ActiveProfileStore.shared.unratedLevel) {
    self.init(id: profile.id, maxAgeLevel: profile.maxAgeLevel, unratedLevel: unratedLevel)
  }

  var isLegacy: Bool { id.isEmpty }
  var isUnchosen: Bool { id == Self.unchosenID }
  /// The value for `X-DSVideo-Profile`, or nil to send no header.
  var headerValue: String? { isLegacy || isUnchosen ? nil : id }

  /// The client visibility rule (FR-242) in Swift. A missing level counts as `unratedLevel`.
  /// Its SQL twin is LocalStore.sqlVisibleToScope; change one, change both (a test pins them).
  func allows(ageLevel: Int?) -> Bool {
    (ageLevel ?? unratedLevel) <= maxAgeLevel
  }
}
