import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-945 · Manage Profiles is reachable with only the owner profile
//
// Bug report: an account with only its owner profile has no way into Manage Profiles, so a
// second profile can never be created from the iOS or tvOS app. The picker (the only host of
// the management screen) is skipped for one profile (FR-205), and the Settings entries were
// gated on "more than one profile" too. Settings now offers "Manage Profiles" whenever the
// account's owner is known; these tests pin that condition and that the picker stays skipped.

@MainActor
@Suite("Manage Profiles entry (TASK-945)")
struct ManageProfilesEntryTests {
  private func owner(hasPin: Bool = false) -> Profile {
    Profile(id: "pf_owner", name: "Ryan", avatar: "cat", maxAgeLevel: 4, hasPin: hasPin, isOwner: true)
  }
  private func kid() -> Profile {
    Profile(id: "pf_kid", name: "Maya", avatar: "cat", maxAgeLevel: 2, hasPin: false, isOwner: false)
  }

  @Test("an account with only its owner profile can open Manage Profiles")
  func ownerOnlyAccountCanManage() async {
    await withIsolatedAppState(cached: [owner()]) { state in
      #expect(state.profiles.count == 1)
      #expect(state.canManageProfiles)
      // ...and can add: one profile is below the limit, so "Add Profile" is offered inside.
      #expect(state.canAddProfile)
    }
  }

  @Test("an owner-only account with a PIN set can open Manage Profiles")
  func ownerOnlyWithPin() async {
    await withIsolatedAppState(cached: [owner(hasPin: true)]) { state in
      #expect(state.canManageProfiles)
    }
  }

  @Test("an account with several profiles can open Manage Profiles")
  func multiProfileAccountCanManage() async {
    await withIsolatedAppState(cached: [owner(), kid()]) { state in
      #expect(state.canManageProfiles)
    }
  }

  @Test("no known profile list: no entry (old server, or offline with nothing cached)")
  func unknownListHasNoEntry() async {
    await withIsolatedAppState(cached: []) { state in
      #expect(!state.canManageProfiles)
    }
  }

  @Test("a list that names no owner is malformed: no entry")
  func listWithoutOwnerHasNoEntry() async {
    await withIsolatedAppState(cached: [kid()]) { state in
      #expect(!state.canManageProfiles)
    }
  }

  @Test("FR-205: the picker is still skipped for an owner-only account on both platforms")
  func pickerStillSkippedForOneProfile() {
    for platform in [ProfilePickerPlatform.iOS, .tvOS] {
      for trigger: ProfilePickerTrigger? in [nil, .coldLaunch, .signedIn, .switchRequested,
                                              .returnedFromBackground(away: 7200)] {
        #expect(!ProfileGate.shouldShowPicker(
          platform: platform, trigger: trigger, profileIDs: ["pf_owner"], activeID: "pf_owner"))
      }
    }
  }
}
