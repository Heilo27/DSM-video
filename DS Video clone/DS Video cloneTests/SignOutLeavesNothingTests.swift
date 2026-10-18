import Testing
import Foundation
import Security
@testable import DSM_Video

// MARK: - Oracle core · sign-out is complete (FRD-001 FR-122)
//
// OC-1124  Sign out; relaunch -> sign-in screen, library unreachable, still signed out after relaunch
// OC-1125  Inspect keychain, app-group container and extension data -> no usable session credential
//          or active-profile id remains anywhere; Top Shelf shows no content fetched for the account
//
// The existing logoutClearsSessionState asserts two in-memory fields. A relaunch reads the
// Keychain, the app-group defaults, the Top Shelf file and the catalog database, so this test
// reads exactly those, each from where a fresh launch would read it, after logout().
// Expected values are literals: nothing is derived from AppState's own clear list.

private let soService = "com.heiloprojects.dsreel"  // AppState.Keys.keychainService (private to AppState)

private func soKeychainWrite(_ value: String, account: String) -> Bool {
  let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: soService, kSecAttrAccount as String: account]
  SecItemDelete(key as CFDictionary)
  var add = key
  add[kSecValueData as String] = Data(value.utf8)
  add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
}

/// What a fresh launch would find: nil when no item exists for the account.
private func soKeychainRead(account: String) -> String? {
  let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                              kSecAttrService as String: soService, kSecAttrAccount as String: account,
                              kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
  var out: AnyObject?
  guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
  return String(data: d, encoding: .utf8)
}

private func soDeleteKeychain() {
  for account in ["sessionToken", "savedPassword"] {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                   kSecAttrService as String: soService, kSecAttrAccount as String: account] as CFDictionary)
  }
}

@MainActor
@Suite("FR-122 · sign-out leaves nothing behind", .serialized)
struct SignOutLeavesNothingTests {
  private let ryan = Profile(id: "pf_so_ryan", name: "Ryan", avatar: "moon", maxAgeLevel: 4,
                             hasPin: false, isOwner: true)
  private let maya = Profile(id: "pf_so_maya", name: "Maya", avatar: "cat", maxAgeLevel: 2,
                             hasPin: false, isOwner: false)

  // OC-1124 + OC-1125 · given a signed-in account with a stored token and password, an active
  // profile, a Top Shelf file in the app group, and a populated offline catalog, when the user
  // signs out, then a fresh launch finds: no keychain token, no keychain password, no active
  // profile id, no cached profile list, no Top Shelf file, no catalog rows, no saved password.
  // Red if: logout() stops deleting either Keychain item, stops calling profileStore.clearAll,
  // stops deleting the Top Shelf file, or stops clearing the catalog. Each is one line in logout().
  @Test func signingOutRemovesEveryCredentialAndEveryTraceOfTheAccount() async throws {
    defer { soDeleteKeychain() }
    #expect(soKeychainWrite("oc1125-sentinel-token", account: "sessionToken"), "precondition: keychain writable")
    #expect(soKeychainWrite("oc1125-sentinel-password", account: "savedPassword"))

    let shelf = FileManager.default.temporaryDirectory
      .appendingPathComponent("oc1125-topshelf-\(UUID().uuidString).json")
    try Data(#"{"items":[{"title":"Heat"}]}"#.utf8).write(to: shelf)
    defer { try? FileManager.default.removeItem(at: shelf) }

    await withIsolatedAppState(cached: [ryan, maya], active: ryan) { state in
      state.topShelfSnapshotURL = shelf
      state.sessionToken = "oc1125-sentinel-token"
      state.savedPassword = "oc1125-sentinel-password"
      state.username = "ryan"
      await state.localStore.upsertItems([
        ItemSummary(id: "heat", type: "movie", title: "Heat", addedAt: "2026-01-01T00:00:00Z",
                    libraryId: "lib_so", changeSeq: 1, ageLevel: 1)])
      await state.localStore.upsertProgress(
        ["heat": ItemProgress(positionSeconds: 900, durationSeconds: 7200, updatedAt: "2026-10-01T09:00:00Z")],
        profileID: "pf_so_ryan")
      #expect(await state.localStore.hasItems(), "precondition: the catalog is populated")
      #expect(FileManager.default.fileExists(atPath: shelf.path), "precondition: the Top Shelf file exists")
      #expect(state.profileStore.activeProfileID == "pf_so_ryan", "precondition: a profile is active")

      state.logout()

      // The catalog clear is dispatched from logout(); wait for it (bounded) rather than sleeping.
      var catalogEmpty = false
      for _ in 0..<40 {
        if await !state.localStore.hasItems() { catalogEmpty = true; break }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }

      // What a relaunch reads:
      #expect(soKeychainRead(account: "sessionToken") == nil, "session token left in the Keychain")
      #expect(soKeychainRead(account: "savedPassword") == nil, "password left in the Keychain")
      #expect(state.sessionToken == nil)
      #expect(state.savedPassword == "")
      #expect(state.username == "")
      #expect(state.profileStore.activeProfileID == nil, "active-profile id survived sign-out")
      #expect(state.profileStore.cachedProfiles.isEmpty, "the account's profile list survived sign-out")
      #expect(!FileManager.default.fileExists(atPath: shelf.path), "Top Shelf still advertises the account's titles")
      #expect(catalogEmpty, "the offline catalog still holds the account's titles")
      #expect(await state.localStore.queryRails().continueWatching.isEmpty)
    }
  }
}
