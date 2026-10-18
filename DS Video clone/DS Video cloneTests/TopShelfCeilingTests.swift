import Foundation
import Testing
@testable import DSM_Video

// FR-264 / AC-002-44, TASK-923 + TASK-928. Friday's ruling (2026-10-17): on an account with
// any restricted profile the tvOS Top Shelf shows ONLY titles at or below the MOST restricted
// profile's level and nothing from any profile's watch history (no Continue Watching). It is
// the shared TV's home screen with no chosen viewer, so the rule holds while the picker is
// pending and after an adult session. Accounts with no restricted profile keep the original
// behavior: Continue Watching, falling back to Just Added.
//
// Every test drives the real writer (AppState.writeTopShelfSnapshot, called by the rails'
// didSet) into a file it owns and reads that file back. A test that expects content REQUIRES
// the file: an absent topshelf.json fails it rather than passing vacuously.

@Suite("Top Shelf ceiling")
@MainActor
struct TopShelfCeilingTests {

  // MARK: Fixtures

  private func profile(_ id: String, _ level: Int, owner: Bool = false) -> Profile {
    Profile(id: id, name: id, avatar: "fox", maxAgeLevel: level, hasPin: false, isOwner: owner)
  }
  private var owner: Profile { profile("p-owner", 4, owner: true) }
  private var teen: Profile { profile("p-teen", 3) }
  private var kid: Profile { profile("p-kid", 1) }

  private func item(_ id: String, level: Int?, progress: (Int, Int)? = nil) -> ItemSummary {
    ItemSummary(id: id, type: "movie", title: "Title \(id)", year: 2024,
                addedAt: "2026-01-01T00:00:00Z", backdropImageId: "img-\(id)",
                progress: progress.map {
                  ItemProgress(positionSeconds: $0.0, durationSeconds: $0.1,
                               updatedAt: "2026-01-01T00:00:00Z")
                },
                ageLevel: level)
  }

  /// An AppState whose shelf writer reads `profiles` from an isolated store and writes to a
  /// fresh temp file, so no test touches the process-wide store or the real app group file.
  /// `unrestrictedLevel` / `unratedLevel` nil = never stated by the server (store fallbacks).
  private func makeState(profiles: [Profile], active: Profile? = nil,
                         unrestrictedLevel: Int? = nil,
                         unratedLevel: Int? = nil) -> (AppState, URL, ActiveProfileStore) {
    let suite = "TopShelfCeilingTests.\(UUID().uuidString)"
    let store = ActiveProfileStore(defaults: UserDefaults(suiteName: suite)!)
    store.setCachedProfiles(profiles, unrestrictedLevel: unrestrictedLevel)
    if let unratedLevel { store.setUnratedLevel(unratedLevel) }
    store.setActive(active)
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TopShelfCeilingTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("topshelf.json")
    let state = AppState(profileStore: store)
    state.topShelfSnapshotURL = url
    return (state, url, store)
  }

  /// The snapshot as the extension would read it. Fails the test when the file is absent.
  private func readShelf(_ url: URL) throws -> TopShelfSnapshot {
    let data = try #require(try? Data(contentsOf: url),
                            "topshelf.json is absent; the shelf would show nothing")
    return try JSONDecoder().decode(TopShelfSnapshot.self, from: data)
  }

  private var adultHistory: [ItemSummary] {
    [item("cw-adult", level: 4, progress: (600, 6000)),
     item("cw-kid", level: 1, progress: (300, 3000))]
  }
  private var mixedJustAdded: [ItemSummary] {
    [item("ja-4", level: 4), item("ja-1", level: 1, progress: (100, 1000)),
     item("ja-2", level: 2), item("ja-unrated", level: nil), item("ja-1b", level: 1)]
  }

  // MARK: Restricted account

  @Test func restrictedAccountShowsOnlyTitlesAtOrBelowTheMostRestrictedLevel() throws {
    let (state, url, _) = makeState(profiles: [owner, teen, kid], active: owner)
    state.homeJustAdded = mixedJustAdded

    let shelf = try readShelf(url)
    #expect(shelf.items.map(\.id) == ["ja-1", "ja-1b"],
            "only level-1 titles: the kid is the most restricted profile; unrated is hidden")
    #expect(shelf.ceiling == TopShelfCeiling(maxAgeLevel: 1, unrestrictedLevel: 4, unratedLevel: 4))
    #expect(shelf.items.allSatisfy { $0.ageLevel == 1 }, "every item carries its level for the reader")
  }

  @Test func restrictedAccountNeverShowsContinueWatchingOrResumeBars() throws {
    let (state, url, _) = makeState(profiles: [owner, kid], active: owner)
    state.homeContinueWatching = adultHistory
    state.homeJustAdded = mixedJustAdded

    let shelf = try readShelf(url)
    #expect(shelf.rail == .justAdded)
    #expect(shelf.sectionTitle == "Just Added")
    #expect(!shelf.items.contains { $0.id.hasPrefix("cw-") },
            "no Continue Watching entry, not even one the kid may see")
    #expect(shelf.items.allSatisfy { $0.playbackProgress == nil },
            "a resume bar is a profile's watch history")
  }

  @Test func restrictedAccountWithOnlyHistoryClearsTheShelf() throws {
    let (state, url, _) = makeState(profiles: [owner, kid], active: owner)
    try Data("stale".utf8).write(to: url)
    state.homeContinueWatching = adultHistory
    state.homeJustAdded = [item("ja-4", level: 4)]

    #expect(!FileManager.default.fileExists(atPath: url.path),
            "nothing may be shown, so the previous file must be removed, not left advertised")
  }

  /// TASK-928: the picker is pending (no active profile) with an adult's rails still loaded.
  /// The shelf is the same as with the adult active: it never depends on who was last chosen.
  @Test func pickerPendingAfterAnAdultSessionShowsOnlyTheCeiling() throws {
    let (pending, pendingURL, _) = makeState(profiles: [owner, kid], active: nil)
    pending.homeContinueWatching = adultHistory
    pending.homeJustAdded = mixedJustAdded
    let (adult, adultURL, _) = makeState(profiles: [owner, kid], active: owner)
    adult.homeContinueWatching = adultHistory
    adult.homeJustAdded = mixedJustAdded

    let whilePending = try readShelf(pendingURL)
    let afterAdult = try readShelf(adultURL)
    #expect(whilePending.items.map(\.id) == ["ja-1", "ja-1b"])
    #expect(afterAdult.items.map(\.id) == whilePending.items.map(\.id))
    #expect(whilePending.rail == .justAdded && afterAdult.rail == .justAdded)
  }

  /// refreshProfiles rewrites the shelf when the list changes: a kid profile added on another
  /// device turns an adult's Continue Watching shelf into the ceiling shelf.
  @Test func addingARestrictedProfileReplacesAnAdultShelf() throws {
    let (state, url, store) = makeState(profiles: [owner], active: owner)
    state.homeContinueWatching = adultHistory
    state.homeJustAdded = mixedJustAdded
    #expect(try readShelf(url).rail == .continueWatching, "precondition: adult shelf on disk")

    store.setCachedProfiles([owner, kid])
    state.writeTopShelfSnapshot()  // what refreshProfiles' success path calls

    let shelf = try readShelf(url)
    #expect(shelf.rail == .justAdded)
    #expect(shelf.items.map(\.id) == ["ja-1", "ja-1b"])
  }

  /// The 10-item cap applies to what may be shown, not before filtering: kid titles after
  /// ten adult ones must still reach the shelf.
  @Test func capAppliesAfterTheCeilingFilter() throws {
    let (state, url, _) = makeState(profiles: [owner, kid])
    let adults = (0..<12).map { item("adult-\($0)", level: 4) }
    let kids = (0..<3).map { item("kid-\($0)", level: 1) }
    state.homeJustAdded = adults + kids

    #expect(try readShelf(url).items.map(\.id) == ["kid-0", "kid-1", "kid-2"])
  }

  // MARK: Accounts with no restricted profile (today's behavior)

  @Test func allAdultAccountKeepsContinueWatchingWithResumeBars() throws {
    let (state, url, _) = makeState(profiles: [owner, profile("p-adult2", 4)], active: nil)
    state.homeJustAdded = mixedJustAdded
    state.homeContinueWatching = adultHistory

    let shelf = try readShelf(url)
    #expect(shelf.rail == .continueWatching)
    #expect(shelf.sectionTitle == "Continue Watching")
    #expect(shelf.items.map(\.id) == ["cw-adult", "cw-kid"])
    #expect(shelf.items[0].playbackProgress == 0.1)
    #expect(!shelf.ceiling.isRestricted)
  }

  @Test func allAdultAccountFallsBackToJustAddedUnfiltered() throws {
    let (state, url, _) = makeState(profiles: [owner])
    state.homeJustAdded = mixedJustAdded

    let shelf = try readShelf(url)
    #expect(shelf.rail == .justAdded)
    #expect(shelf.items.map(\.id) == mixedJustAdded.map(\.id), "no ceiling: unrated titles included")
  }

  @Test func serverWithoutProfilesKeepsTodaysBehavior() throws {
    let (state, url, _) = makeState(profiles: [])
    state.homeContinueWatching = adultHistory

    let shelf = try readShelf(url)
    #expect(shelf.rail == .continueWatching)
    #expect(shelf.items.map(\.id) == ["cw-adult", "cw-kid"])
  }

  // MARK: The two server levels are separate questions (TASK-922)

  /// "Restricted account" is decided by unrestrictedLevel alone; unratedLevel only filters.
  /// A profile at 4 under a ladder topping at 5 is restricted, and an unrated title (level 4)
  /// is within its ceiling of 4, so it is shown.
  @Test func restrictionComesFromUnrestrictedLevelAndUnratedTitlesUseUnratedLevel() throws {
    let (state, url, _) = makeState(
      profiles: [profile("p-owner", 5, owner: true), profile("p-teen", 4)],
      unrestrictedLevel: 5, unratedLevel: 4)
    state.homeContinueWatching = adultHistory
    state.homeJustAdded = [item("ja-5", level: 5), item("ja-4", level: 4),
                           item("ja-unrated", level: nil)]

    let shelf = try readShelf(url)
    #expect(shelf.ceiling == TopShelfCeiling(maxAgeLevel: 4, unrestrictedLevel: 5, unratedLevel: 4))
    #expect(shelf.ceiling.isRestricted, "a profile below the ladder's top makes the account restricted")
    #expect(shelf.rail == .justAdded, "no Continue Watching on a restricted account")
    #expect(shelf.items.map(\.id) == ["ja-4", "ja-unrated"],
            "unrated counts as level 4, within the ceiling; level 5 is above it")
  }

  /// An unrated level above every profile's ceiling does not make the account restricted:
  /// all profiles are at the ladder's top, so today's shelf (Continue Watching) is kept.
  @Test func unratedLevelAboveTheLadderTopDoesNotRestrictTheAccount() throws {
    let (state, url, _) = makeState(
      profiles: [owner, profile("p-adult2", 4)], unrestrictedLevel: 4, unratedLevel: 5)
    state.homeContinueWatching = adultHistory
    state.homeJustAdded = mixedJustAdded

    let shelf = try readShelf(url)
    #expect(!shelf.ceiling.isRestricted)
    #expect(shelf.rail == .continueWatching)
    #expect(shelf.items.map(\.id) == ["cw-adult", "cw-kid"])
  }

  // MARK: Files from older builds

  /// A topshelf.json from an older build carries no ceiling and no age levels, so it cannot
  /// be checked. Neither older form decodes as the current snapshot (the extension's copy has
  /// the same required keys), so the reader shows nothing rather than a possibly adult shelf.
  @Test func olderFormatSnapshotsAreRejected() {
    let legacyArray = Data("""
    [{"id":"x","title":"Old Film","year":2001,"imageURL":null,"deepLinkURL":"dsvideo://item/x"}]
    """.utf8)
    let unstampedObject = Data("""
    {"sectionTitle":"Continue Watching","items":[{"id":"x","title":"Adult Film","year":2001,
     "imageURL":null,"deepLinkURL":"dsvideo://item/x","playbackProgress":0.5}]}
    """.utf8)
    #expect((try? JSONDecoder().decode(TopShelfSnapshot.self, from: legacyArray)) == nil)
    #expect((try? JSONDecoder().decode(TopShelfSnapshot.self, from: unstampedObject)) == nil)
  }

  @Test func staleOlderBuildFileIsReplacedOnTheNextWrite() throws {
    let (state, url, _) = makeState(profiles: [owner, kid])
    try Data("""
    {"sectionTitle":"Continue Watching","items":[{"id":"cw-adult","title":"Adult Film","year":2001,
     "imageURL":null,"deepLinkURL":"dsvideo://item/cw-adult","playbackProgress":0.5}]}
    """.utf8).write(to: url)

    state.homeJustAdded = [item("ja-1", level: 1)]

    let shelf = try readShelf(url)
    #expect(shelf.items.map(\.id) == ["ja-1"])
    #expect(shelf.ceiling.isRestricted)
  }
}
