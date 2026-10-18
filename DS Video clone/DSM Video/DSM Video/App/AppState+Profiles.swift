import Foundation

// MARK: - Profile screens' actions (FRD-002 §8, docs/api/ProfilesAPI.md)
//
// The picker, PIN pad and management screens call only these. Each mutation refreshes the
// profile list afterwards, so every screen reads the server's answer rather than a local
// guess. PINs are passed straight through to the server, which is the only thing that
// checks them (FR-213); nothing here keeps one.

extension AppState {
  /// Whether the picker and management screens offer "Add Profile": the account holds fewer
  /// profiles than the server's limit (4 today). The one home for that rule; the server
  /// still refuses a fifth with `profile_limit_reached`.
  var canAddProfile: Bool { profiles.count < maxProfiles }

  /// Whether Settings offers "Manage Profiles" (FR-205, FR-211, FR-212). It does as soon as
  /// the account's profile list is known to name its owner, whatever the count: a
  /// single-profile account has no picker, so Settings is the only way in, and without it a
  /// second profile could never be created. An unknown list (old server, or offline with
  /// nothing cached) has nothing to manage yet, so no entry. The picker's own "Manage
  /// Profiles" button is separate: it only exists once the picker does (more than one profile).
  var canManageProfiles: Bool { profiles.contains(where: \.isOwner) }

  /// FR-213: asks the server to check `pin` for `profile`, every time it is entered.
  func verifyProfilePin(_ profile: Profile, pin: String) async -> Result<Void, Error> {
    do {
      try await api.verifyPin(profileID: profile.id, pin: pin)
      return .success(())
    } catch {
      dlog.warn(.app, "verifyProfilePin: \(profile.id) refused — \(error.localizedDescription)")
      return .failure(error)
    }
  }

  /// FR-211: create a profile under the owner PIN. `pin` nil = no PIN.
  func createProfile(ownerPin: String, name: String, avatar: String,
                     maxAgeLevel: Int, pin: String?) async -> Result<Profile, Error> {
    do {
      let created = try await api.createProfile(CreateProfileRequest(
        ownerPin: ownerPin, name: name, avatar: avatar, maxAgeLevel: maxAgeLevel, pin: pin))
      await refreshProfiles()
      return .success(created)
    } catch {
      dlog.warn(.app, "createProfile failed — \(error.localizedDescription)")
      return .failure(error)
    }
  }

  /// FR-211, FR-212: edit a profile. `ownerPin` nil only for the owner's first PIN.
  func updateProfile(id: String, _ change: UpdateProfileRequest) async -> Result<Profile, Error> {
    do {
      let updated = try await api.updateProfile(id: id, change)
      await refreshProfiles()
      return .success(updated)
    } catch {
      dlog.warn(.app, "updateProfile \(id) failed — \(error.localizedDescription)")
      return .failure(error)
    }
  }

  /// DESTRUCTIVE (FR-206): the server permanently deletes the profile's progress, history
  /// and watchlist. Callers confirm with `ProfileText.deleteConfirmation` first (FR-266).
  func deleteProfile(id: String, ownerPin: String) async -> Result<Void, Error> {
    do {
      try await api.deleteProfile(id: id, ownerPin: ownerPin)
      dlog.info(.app, "deleteProfile: \(id) deleted")
      await refreshProfiles()
      return .success(())
    } catch {
      dlog.warn(.app, "deleteProfile \(id) failed — \(error.localizedDescription)")
      return .failure(error)
    }
  }
}

// MARK: - Wording (one home for the profile screens' user-facing text)

nonisolated enum ProfileText {
  /// FR-263: why a PIN-protected profile cannot be entered offline.
  static let pinNeedsNAS = "Your NAS needs to be reachable to check this PIN."
  static let saveNeedsNAS = "Couldn't reach your NAS, so nothing was changed. Check your connection and try again."

  /// The real cause of a failed PIN check (FR-266, AC-002-41): wrong PIN with tries left,
  /// locked with the time remaining (both from the server's own error body via
  /// APIError.userMessage), or an unreachable NAS, which is never reported as a wrong PIN.
  static func pinFailure(_ error: Error) -> String {
    guard let api = error as? APIError, api.serverReached else { return pinNeedsNAS }
    return api.userMessage
  }

  /// A failed create/edit/delete: the server's reason, or the NAS named as unreachable.
  static func saveFailure(_ error: Error) -> String {
    guard let api = error as? APIError, api.serverReached else { return saveNeedsNAS }
    return api.userMessage
  }

  /// FR-206, AC-002-46: the deletion confirmation names exactly what is lost.
  static func deleteConfirmation(name: String) -> String {
    "\(name)'s watch history, progress and watchlist will be permanently deleted. "
      + "Your videos and other profiles are not affected. This can't be undone."
  }

  /// FR-265: the `place` for a restricted profile's empty Home (no one library is meant).
  static let homeEmptyPlace = "your library"

  /// FR-265, AC-002-47: an empty grid on a restricted profile names the profile's level, so
  /// it reads differently from an empty library and from a load failure.
  static func restrictedEmpty(levelLabel: String?, place: String) -> String {
    if let levelLabel {
      return "No \(levelLabel) titles in \(place) yet."
    }
    return "No titles for this profile's age rating in \(place) yet."
  }
}
