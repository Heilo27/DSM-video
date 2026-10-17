import Foundation

// MARK: - Profiles (FRD-002, docs/api/ProfilesAPI.md)
//
// Shared by the iOS and tvOS targets. The server owns every rule here: the ladder, the
// unrated rule, the profile limit and PIN checks. The client's whole visibility check is
// `item.ageLevel <= profile.maxAgeLevel` (FR-242), done in exactly one place:
// `ProfileScope.allows(ageLevel:)`.

/// One viewer within an account (FR-203). The PIN itself is never sent, only `hasPin`.
nonisolated struct Profile: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  /// Opaque key from the apps' built-in avatar set.
  let avatar: String
  /// 1...4 on the server's ladder. The owner is always 4 (FR-204).
  let maxAgeLevel: Int
  let hasPin: Bool
  let isOwner: Bool
  let createdAt: String?

  init(id: String, name: String, avatar: String, maxAgeLevel: Int,
       hasPin: Bool, isOwner: Bool, createdAt: String? = nil) {
    self.id = id
    self.name = name
    self.avatar = avatar
    self.maxAgeLevel = maxAgeLevel
    self.hasPin = hasPin
    self.isOwner = isOwner
    self.createdAt = createdAt
  }

  /// Restricted = below Adult; unrated titles are hidden from it (FRD-002 §1).
  var isRestricted: Bool { maxAgeLevel < ProfileScope.unrestrictedLevel }
  /// Kids' profile = Older Kids or below (FRD-002 §1, §9).
  var isKids: Bool { maxAgeLevel <= 2 }
}

/// GET /profiles
nonisolated struct ProfilesResponse: Codable, Sendable {
  let maxProfiles: Int
  let activeProfileId: String?
  let profiles: [Profile]
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
  let unratedLevel: Int
  let levels: [Level]
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
/// `id` is the server profile id, or `""` for the legacy scope: a server that predates
/// profiles (no header is sent), and the bucket that progress recorded before the v3
/// migration lives in until the owner's id is known (FR-233).
nonisolated struct ProfileScope: Equatable, Hashable, Sendable {
  static let unrestrictedLevel = 4
  static let legacy = ProfileScope(id: "", maxAgeLevel: unrestrictedLevel)

  let id: String
  let maxAgeLevel: Int

  init(id: String, maxAgeLevel: Int) {
    self.id = id
    self.maxAgeLevel = maxAgeLevel
  }

  init(profile: Profile) {
    self.init(id: profile.id, maxAgeLevel: profile.maxAgeLevel)
  }

  var isLegacy: Bool { id.isEmpty }
  /// The value for `X-DSVideo-Profile`, or nil to send no header.
  var headerValue: String? { isLegacy ? nil : id }

  /// THE client-side visibility rule (FR-242). A missing level is unrated, which is 4:
  /// fail closed. LocalStore's SQL mirrors this as `COALESCE(age_level, 4) <= ?`.
  func allows(ageLevel: Int?) -> Bool {
    (ageLevel ?? Self.unrestrictedLevel) <= maxAgeLevel
  }
}
