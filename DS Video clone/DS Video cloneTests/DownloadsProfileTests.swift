import Foundation
import Testing
@testable import DSM_Video

// MARK: - Downloads × profiles (TASK-927 FR-262/AC-002-43, TASK-936 FR-233, TASK-938 OC-2041)
//
// Downloads belong to the account (FRD-002); what a profile may SEE and PLAY of them, and
// where each profile is in them, are per profile. Every manager here owns its container and
// its own ActiveProfileStore, so nothing touches the device's library or the app's profile.

private let owner = Profile(id: "pf_owner", name: "Owner", avatar: "moon", maxAgeLevel: 4,
                            hasPin: true, isOwner: true)
private let littleKid = Profile(id: "pf_kid", name: "Kid", avatar: "cat", maxAgeLevel: 1,
                                hasPin: false, isOwner: false)
private let teen = Profile(id: "pf_teen", name: "Teen", avatar: "bolt", maxAgeLevel: 3,
                           hasPin: false, isOwner: false)

/// A profile store in its own defaults suite, with `active` chosen and `cached` listed.
private func isolatedStore(active: Profile?, cached: [Profile]) -> ActiveProfileStore {
  let store = ActiveProfileStore(
    defaults: UserDefaults(suiteName: "DownloadsProfileTests.\(UUID().uuidString)") ?? .standard)
  store.setCachedProfiles(cached)
  store.setActive(active)
  return store
}

private func makeContainer(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-dlprof-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Writes `manifestJSON` as downloads.json and a backing file for each id, so the read path
/// does not drop an entry as missing. Raw JSON on purpose: it is what an older build left on
/// disk, so a missing key is genuinely missing rather than encoded as null.
private func seed(_ manifestJSON: String, ids: [String], in container: URL) throws {
  let dir = container.appendingPathComponent("Downloads", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  for id in ids {
    try Data("fake-mp4-bytes".utf8).write(to: dir.appendingPathComponent("\(id).mp4"))
  }
  try Data(manifestJSON.utf8).write(to: container.appendingPathComponent("downloads.json"))
}

/// One manifest entry as JSON. `ageLevel` nil omits the key (a pre-FR-262 download).
private func entry(_ id: String, ageLevel: Int?, resume: Int = 0) -> String {
  let level = ageLevel.map { #","ageLevel":\#($0)"# } ?? ""
  return #"{"id":"\#(id)","title":"\#(id)","year":2020,"videoPath":"\#(id).mp4","fileSize":14,"downloadedAt":700000000,"resumePositionSeconds":\#(resume),"durationSeconds":7200\#(level)}"#
}

@MainActor
struct DownloadsProfileTests {

  /// TASK-927 AC-3 · FR-262 · AC-002-43. The owner downloads an R film (level 4) and a G film
  /// (level 1). On a level-1 profile the R film is neither listed nor playable; the G film is
  /// both. The gate reads only local state, so it holds with no server in reach.
  @Test func anOwnerDownloadedRTitleIsNotListedOrPlayableOnALevel1Profile() throws {
    let container = try makeContainer("r-on-kid")
    defer { try? FileManager.default.removeItem(at: container) }
    try seed("[\(entry("mv-r", ageLevel: 4)),\(entry("mv-g", ageLevel: 1))]",
             ids: ["mv-r", "mv-g"], in: container)

    let kid = DownloadManager(containerForTesting: container,
                              profileStore: isolatedStore(active: littleKid, cached: [owner, littleKid]))
    #expect(kid.visibleDownloadedItems().map(\.id) == ["mv-g"])
    #expect(kid.playableDownloadedItem(itemId: "mv-r") == nil, "the R film must not play on level 1")
    #expect(kid.playableDownloadedItem(itemId: "mv-g")?.id == "mv-g")
    #expect(kid.getDownloadedItems().count == 2, "hidden, not deleted: downloads are the account's")

    let ownerView = DownloadManager(containerForTesting: container,
                                    profileStore: isolatedStore(active: owner, cached: [owner, littleKid]))
    #expect(Set(ownerView.visibleDownloadedItems().map(\.id)) == ["mv-r", "mv-g"])
    #expect(ownerView.playableDownloadedItem(itemId: "mv-r")?.id == "mv-r")
  }

  /// TASK-927 AC-1. A download made before levels were stored decodes as unknown, which is
  /// hidden on a restricted profile (fail closed) yet still the owner's to see. Once the local
  /// catalog supplies the level it is backfilled, persisted, and the title appears.
  @Test func aLegacyDownloadWithNoAgeLevelIsHiddenOnARestrictedProfileUntilBackfilled() async throws {
    let container = try makeContainer("legacy-level")
    defer { try? FileManager.default.removeItem(at: container) }
    try seed("[\(entry("mv-old", ageLevel: nil))]", ids: ["mv-old"], in: container)

    let teenStore = isolatedStore(active: teen, cached: [owner, teen])
    let unknown = DownloadManager(containerForTesting: container, profileStore: teenStore)
    #expect(unknown.getDownloadedItem(itemId: "mv-old")?.ageLevel == nil, "missing key decodes as unknown")
    #expect(unknown.visibleDownloadedItems().isEmpty, "unknown is unrated: hidden on level 3")
    #expect(unknown.playableDownloadedItem(itemId: "mv-old") == nil)
    await unknown.refreshAgeLevels()   // catalog knows nothing either: still hidden
    #expect(unknown.visibleDownloadedItems().isEmpty)

    let ownerView = DownloadManager(containerForTesting: container,
                                    profileStore: isolatedStore(active: owner, cached: [owner, teen]))
    #expect(ownerView.visibleDownloadedItems().map(\.id) == ["mv-old"])

    let backfilling = DownloadManager(containerForTesting: container, profileStore: teenStore,
                                      ageLevelLookup: { $0 == "mv-old" ? 2 : nil })
    await backfilling.refreshAgeLevels()
    #expect(backfilling.visibleDownloadedItems().map(\.id) == ["mv-old"])

    let relaunched = DownloadManager(containerForTesting: container, profileStore: teenStore)
    #expect(relaunched.getDownloadedItem(itemId: "mv-old")?.ageLevel == 2, "the backfill is on disk")
  }

  /// TASK-936 (offline part) · FR-233. The pre-profiles position (600s) migrates to the owner
  /// and is never lost; a kid starts at 0 and neither profile's save moves the other's.
  @Test func offlineResumePositionsAreIndependentPerProfile() throws {
    let container = try makeContainer("resume-per-profile")
    defer { try? FileManager.default.removeItem(at: container) }
    try seed("[\(entry("mv-film", ageLevel: 1, resume: 600))]", ids: ["mv-film"], in: container)
    let ownerStore = isolatedStore(active: owner, cached: [owner, littleKid])
    let kidStore = isolatedStore(active: littleKid, cached: [owner, littleKid])

    let asOwner = DownloadManager(containerForTesting: container, profileStore: ownerStore)
    let asKid = DownloadManager(containerForTesting: container, profileStore: kidStore)
    let film = { (m: DownloadManager) throws -> DownloadedItem in
      try #require(m.getDownloadedItem(itemId: "mv-film"))
    }
    #expect(asOwner.resumePosition(of: try film(asOwner)) == 600, "the legacy value is the owner's")
    #expect(asKid.resumePosition(of: try film(asKid)) == 0, "a kid never inherits someone's place")

    asKid.updateResumePosition(itemId: "mv-film", positionSeconds: 120, profileID: littleKid.id)
    #expect(asOwner.resumePosition(of: try film(asOwner)) == 600)
    asOwner.updateResumePosition(itemId: "mv-film", positionSeconds: 900, profileID: owner.id)

    let ownerAgain = DownloadManager(containerForTesting: container, profileStore: ownerStore)
    let kidAgain = DownloadManager(containerForTesting: container, profileStore: kidStore)
    #expect(ownerAgain.resumePosition(of: try film(ownerAgain)) == 900)
    #expect(kidAgain.resumePosition(of: try film(kidAgain)) == 120)
    #expect(try film(ownerAgain).resumePositionSeconds == 600, "the pre-profiles value is kept on disk")
  }

  /// TASK-938 OC-2041 · FR-206. Given completed downloads and a profile B, deleting B leaves
  /// every download listed, playable and on disk; the count is unchanged. Simulates what the
  /// app does after the server confirms the delete: B leaves the cached list and, if it was
  /// active, stops being active.
  @Test func deletingAProfileLeavesOnDeviceDownloadsIntact() throws {
    let container = try makeContainer("oc2041")
    defer { try? FileManager.default.removeItem(at: container) }
    let ids = ["mv-a", "mv-b", "mv-c"]
    try seed("[\(entry("mv-a", ageLevel: 1)),\(entry("mv-b", ageLevel: 4)),\(entry("mv-c", ageLevel: nil))]",
             ids: ids, in: container)
    let store = isolatedStore(active: teen, cached: [owner, teen])
    let manager = DownloadManager(containerForTesting: container, profileStore: store)
    manager.updateResumePosition(itemId: "mv-a", positionSeconds: 300, profileID: teen.id)
    #expect(manager.getDownloadedItems().count == 3, "precondition: 3 downloads")

    store.setCachedProfiles([owner])   // profile B (teen) deleted
    store.setActive(owner)

    let after = DownloadManager(containerForTesting: container, profileStore: store)
    #expect(after.getDownloadedItems().count == 3, "download count unchanged")
    #expect(Set(after.visibleDownloadedItems().map(\.id)) == Set(ids))
    for id in ids {
      let item = try #require(after.playableDownloadedItem(itemId: id), "\(id) still plays")
      #expect(FileManager.default.fileExists(atPath: item.videoPath), "\(id) still on disk")
    }
  }
}
