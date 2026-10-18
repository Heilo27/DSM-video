import Testing
import Foundation
@testable import DSM_Video

// MARK: - P9 (shift 2) · FRD-002 client oracle assertions that no earlier suite reached
//
// Each test names its OC-NNNN (docs oracle: .claude/scratch/diagnostic-dsvideo-oracle-frd-002.json),
// the code change that turns it red, and observes at the layer the user (or the wire) sees.
// Expected values are literals from the FRD / ProfilesAPI.md, never recomputed from production
// code. Every AppState here runs over its own stores (withIsolatedAppState); nothing touches
// ActiveProfileStore.shared, the app-group defaults, or the app's database.
//
// What unit tests cannot reach (SwiftUI branch choice, navigation stacks, a live Siri
// invocation) is listed in .claude/scratch/p9-worf-profiles.md as XCUITest-only.

private let kid = Profile(id: "pf_oc_kid", name: "Maya", avatar: "cat", maxAgeLevel: 1,
                          hasPin: false, isOwner: false)
private let older = Profile(id: "pf_oc_older", name: "Leo", avatar: "bolt", maxAgeLevel: 2,
                            hasPin: false, isOwner: false)
private let owner = Profile(id: "pf_oc_owner", name: "Ryan", avatar: "moon", maxAgeLevel: 4,
                            hasPin: true, isOwner: true)
private let pinned = Profile(id: "pf_oc_pinned", name: "Zed", avatar: "fox", maxAgeLevel: 3,
                             hasPin: true, isOwner: false)

private func ocItem(_ id: String, level: Int?, rating: String? = nil, library: String = "lib_oc",
                    day: Int = 1) -> ItemSummary {
  ItemSummary(id: id, type: "movie", title: "Title \(id)", year: 2020, durationSeconds: 7200,
              addedAt: "2026-01-0\(day)T00:00:00Z", libraryId: library, changeSeq: 1,
              contentRating: rating, ageLevel: level)
}

/// Runs `body` on a signed-in AppState over the profile stub server, holding ProfileStateGate
/// for the stub's process-wide route table.
@MainActor
private func ocAccount(
  cached: [Profile] = [], active: Profile? = nil,
  routes: [String: ProfileStubServer.Reply] = [:],
  _ body: (AppState) async -> Void
) async {
  await ProfileStateGate.shared.run {
    ProfileStubServer.reset(routes)
    await withIsolatedAppState(cached: cached, active: active,
                               stubHost: ProfileStubServer.host, body)
  }
}

private let ageLevelsJSON = """
{"unratedLevel":4,"levels":[
 {"level":1,"key":"littleKids","label":"Little Kids","movie":["G"],"tv":["TV-Y","TV-G"]},
 {"level":2,"key":"olderKids","label":"Older Kids","movie":["PG"],"tv":["TV-Y7","TV-PG"]},
 {"level":3,"key":"teens","label":"Teens","movie":["PG-13"],"tv":["TV-14"]},
 {"level":4,"key":"adult","label":"Adult","movie":["R","NC-17"],"tv":["TV-MA"]}]}
"""

// MARK: - OC-2134 / 2186 / 2190 · the ceiling-empty copy names the level (FR-265, AC-002-47)

@Suite("FR-265 · ceiling-empty copy", .serialized)
@MainActor
struct CeilingEmptyCopyTests {

  /// OC-2186 · given the Little Kids profile and the server's ladder, when the Movies grid is
  /// empty, then the copy is "No Little Kids titles in Movies yet." and it is not any of the
  /// other two empty/failed states' wording.
  /// Red if: ageLevelLabel looks up the wrong level, restrictedEmpty drops the level or the
  /// library name, or the ladder fetch stops filling the labels.
  @Test func littleKidsCopyNamesTheLevelAndTheLibrary() async {
    await ocAccount(active: kid, routes: [
      "GET /api/v1/profiles/age-levels": .json(200, ageLevelsJSON)
    ]) { state in
      await state.loadAgeLevelsIfNeeded()
      let text = ProfileText.restrictedEmpty(
        levelLabel: state.ageLevelLabel(kid.maxAgeLevel), place: "Movies")
      #expect(text == "No Little Kids titles in Movies yet.")
      #expect(text != "This library has no videos yet.", "differs from the empty-library state")
      #expect(!text.localizedCaseInsensitiveContains("couldn't load"), "differs from load failure")
    }
  }

  /// OC-2186 / 2190 · the level in the copy follows the profile, and the place follows the
  /// screen (a collection title for OC-2190, a library title otherwise).
  /// Red if: the label is taken from a fixed level instead of the profile's own.
  @Test func copyFollowsTheProfilesLevelAndThePlace() async {
    await ocAccount(active: older, routes: [
      "GET /api/v1/profiles/age-levels": .json(200, ageLevelsJSON)
    ]) { state in
      await state.loadAgeLevelsIfNeeded()
      #expect(ProfileText.restrictedEmpty(
        levelLabel: state.ageLevelLabel(older.maxAgeLevel), place: "Pixar")
        == "No Older Kids titles in Pixar yet.")
      #expect(ProfileText.restrictedEmpty(
        levelLabel: state.ageLevelLabel(3), place: "TV Shows") == "No Teens titles in TV Shows yet.")
    }
  }

  /// FR-241 editor · each level the editor offers names the ratings it allows, from the
  /// server's ladder; the unrated level also says "Unrated" (FR-242). No ladder, no list.
  /// Red if: the ratings come from a hard-coded table, a tier's movie or TV list is dropped,
  /// or "Unrated" lands on the wrong level.
  @Test func eachLevelNamesTheRatingsItAllows() async {
    await ocAccount(active: kid, routes: [
      "GET /api/v1/profiles/age-levels": .json(200, ageLevelsJSON)
    ]) { state in
      #expect(state.ageLevelRatings(1) == nil, "precondition: no ladder yet")
      await state.loadAgeLevelsIfNeeded()
      #expect(state.ageLevelRatings(1) == "G · TV-Y, TV-G")
      #expect(state.ageLevelRatings(2) == "PG · TV-Y7, TV-PG")
      #expect(state.ageLevelRatings(3) == "PG-13 · TV-14")
      #expect(state.ageLevelRatings(4) == "R, NC-17 · TV-MA · Unrated")
    }
  }

  /// OC-2186 negative · before the ladder has loaded the level cannot be named, and the copy
  /// must then say so honestly (no invented or stale level) while still not claiming the
  /// library is empty.
  /// Red if: the fallback invents a level name, or reuses the empty-library sentence.
  @Test func withoutTheLadderTheCopyInventsNoLevel() async {
    await ocAccount(active: kid) { state in
      #expect(state.ageLevelLabel(1) == nil, "precondition: no ladder yet")
      let text = ProfileText.restrictedEmpty(levelLabel: state.ageLevelLabel(1), place: "Movies")
      #expect(text == "No titles for this profile's age rating in Movies yet.")
    }
  }

  /// OC-2186 (TASK-968) · given the ladder was fetched in an earlier session, when the app is
  /// cold-launched with the NAS unreachable, then the level is still named: the label comes
  /// from the ladder the device kept, and the (failing) fetch does not blank it.
  /// Red if: the ladder is held in memory only again, or a failed fetch clears the label.
  @Test func aColdLaunchOfflineStillNamesTheLevel() async {
    await ocAccount(active: kid, routes: [
      "GET /api/v1/profiles/age-levels": .json(200, ageLevelsJSON)
    ]) { first in
      await first.loadAgeLevelsIfNeeded()
      #expect(first.ageLevelLabel(1) == "Little Kids", "precondition: the ladder was fetched online")

      // Cold launch: a new AppState over the same on-device stores, the NAS unreachable.
      ProfileStubServer.reset(["GET /api/v1/profiles/age-levels": .unreachable])
      let relaunched = AppState(profileStore: first.profileStore, localStore: first.localStore)
      relaunched.baseURL = ProfileStubServer.host
      relaunched.useHTTPS = false
      relaunched.rememberMe = false
      relaunched.sessionToken = "stub-token"
      await relaunched.loadAgeLevelsIfNeeded()

      // (requestWithRetry sends a failed transport GET twice; only "it was attempted" matters here.)
      #expect(ProfileStubServer.count("GET /api/v1/profiles/age-levels") >= 1, "the fetch ran and failed")
      #expect(ProfileText.restrictedEmpty(
        levelLabel: relaunched.ageLevelLabel(kid.maxAgeLevel),
        place: ProfileText.homeEmptyPlace) == "No Little Kids titles in your library yet.")
    }
  }

  /// OC-2188 · an unrestricted profile never gets the level-named state: the view's branch is
  /// `profile.isRestricted`, so the adult owner must not be restricted.
  /// Red if: isRestricted becomes true for the top level (the adult would see "No Adult titles").
  @Test func theOwnerAtTheTopLevelIsNotRestricted() async {
    await ocAccount(cached: [owner, kid], active: owner) { state in
      #expect(state.activeProfile?.isRestricted(in: state.profileStore) == false)
      #expect(kid.isRestricted(in: state.profileStore) == true)
    }
  }
}

// MARK: - OC-2130 · the client decides by ageLevel and never parses the certification

@Suite("OC-2130 · ageLevel, not certification")
@MainActor
struct CertificationIsDisplayOnlyTests {

  private func tempDB() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel-oc2130-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// OC-2130 · given X {contentRating G, ageLevel 4}, Y {no rating, ageLevel 1}, Z {contentRating R,
  /// ageLevel 1} and W {contentRating G, no level}, when the level-1 profile reads the library
  /// offline, then only Y and Z are listed (X hidden despite "G", Z shown despite "R", W hidden:
  /// unrated). The unrestricted scope sees all four, so the filter is what removed them.
  /// Red if: the offline filter reads contentRating (X would show, Z would hide).
  @Test func levelOneSeesYAndZButNeverXOrW() async throws {
    let dir = try tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
    await store.upsertItems([
      ocItem("x-g-level4", level: 4, rating: "G"),
      ocItem("y-none-level1", level: 1, rating: nil),
      ocItem("z-r-level1", level: 1, rating: "R"),
      ocItem("w-g-nolevel", level: nil, rating: "G"),
    ])

    await store.setActiveProfile(ProfileScope(id: "pf_oc_kid", maxAgeLevel: ProfileScope.unrestrictedLevel))
    #expect(await store.fetchItems(forLibraryId: "lib_oc").count == 4, "precondition: all four stored")

    await store.setActiveProfile(ProfileScope(id: "pf_oc_kid", maxAgeLevel: 1))
    let visible = await store.fetchItems(forLibraryId: "lib_oc")
    #expect(Set(visible.map(\.id)) == ["y-none-level1", "z-r-level1"])
    #expect(visible.count == 2)
  }

  /// OC-2130 online half · the wire keeps contentRating for display and ageLevel for the
  /// decision as two independent fields; neither is derived from the other on decode.
  /// Red if: decoding fills ageLevel from contentRating (or drops either field).
  @Test func theWireKeepsCertificationAndLevelIndependent() throws {
    let json = Data(#"""
    {"items":[
     {"id":"x","type":"movie","title":"X","addedAt":"2026-01-01T00:00:00Z","contentRating":"G","ageLevel":4},
     {"id":"y","type":"movie","title":"Y","addedAt":"2026-01-01T00:00:00Z","contentRating":null,"ageLevel":1}],
     "total":2}
    """#.utf8)
    let decoded = try JSONDecoder().decode(ItemsResponse.self, from: json)
    #expect(decoded.items.map(\.id) == ["x", "y"])
    #expect(decoded.items[0].contentRating == "G")
    #expect(decoded.items[0].ageLevel == 4)
    #expect(decoded.items[1].contentRating == nil)
    #expect(decoded.items[1].ageLevel == 1)
  }
}

// MARK: - OC-2146 · a refused title says why, and never signs the user out

@Suite("OC-2146 · content_restricted is named", .serialized)
@MainActor
struct RestrictedTitleMessageTests {

  /// OC-2146 · given a level-1 profile and an adult title H reached by deep link, when the
  /// detail and the playback request are refused with 403 content_restricted, then the message
  /// names the age rating, is not the not-found or session-expired wording, and is not an auth
  /// failure (which would clear the session). One request each: a refusal is not retried.
  /// Red if: userMessage maps content_restricted to the not-found/expired text, or
  /// isAuthFailure starts treating 403 content_restricted as a credential problem.
  @Test func detailAndPlaybackRefusalNameTheRestriction() async {
    let refused = ProfileStubServer.Reply.json(403, #"{"error":"content_restricted"}"#)
    await ocAccount(cached: [owner, kid], active: kid, routes: [
      "GET /api/v1/items/adult-h": refused,
      "GET /api/v1/items/adult-h/playback": refused,
      "GET /api/v1/items/ghost": .json(404, #"{"error":"not_found"}"#),
    ]) { state in
      var detailError: APIError?
      do { _ = try await state.api.itemDetail(id: "adult-h") } catch { detailError = error as? APIError }
      var playbackError: APIError?
      do { _ = try await state.api.playback(id: "adult-h") } catch { playbackError = error as? APIError }
      var ghostError: APIError?
      do { _ = try await state.api.itemDetail(id: "ghost") } catch { ghostError = error as? APIError }

      for error in [detailError, playbackError] {
        #expect(error?.userMessage == "This title is above this profile's age rating.")
        #expect(error?.isAuthFailure == false, "a restriction must not sign the user out")
      }
      #expect(ghostError?.userMessage == "That item is no longer in your library.")
      #expect(ghostError?.userMessage != detailError?.userMessage, "restricted differs from not found")
      #expect(ProfileStubServer.count("GET /api/v1/items/adult-h") == 1)
      #expect(ProfileStubServer.count("GET /api/v1/items/adult-h/playback") == 1)
      #expect(state.activeProfile?.id == "pf_oc_kid", "the kid stays the active profile")
    }
  }
}

// MARK: - OC-2192 · the three PIN failures are distinct and none signs out

@Suite("OC-2192 · PIN failures never sign out", .serialized)
@MainActor
struct PinFailuresKeepTheSessionTests {

  /// OC-2192 · given wrong, locked and unreachable PIN checks, then the three messages are
  /// pairwise different and none of the errors is an auth failure (the no-sign-out clause).
  /// Red if: pin_incorrect/pin_locked (403/429) get classified as auth failures, or two of the
  /// three causes collapse into one message.
  @Test func wrongLockedAndUnreachableAreDistinctAndKeepTheSession() async {
    let routes: [String: ProfileStubServer.Reply] = [
      "POST /api/v1/profiles/pf_oc_pinned/pin/verify": .json(403, #"{"error":"pin_incorrect","attemptsRemaining":3}"#)
    ]
    var messages: [String] = []
    var anyAuthFailure = false
    func take(_ result: Result<Void, Error>) {
      if case .failure(let error) = result {
        messages.append(ProfileText.pinFailure(error))
        anyAuthFailure = anyAuthFailure || ((error as? APIError)?.isAuthFailure ?? false)
      } else {
        messages.append("<success>")
      }
    }
    await ocAccount(routes: routes) { state in
      take(await state.verifyProfilePin(pinned, pin: "1111"))
      ProfileStubServer.reset([
        "POST /api/v1/profiles/pf_oc_pinned/pin/verify":
          .json(429, #"{"error":"pin_locked","retryAfterSeconds":300}"#)])
      take(await state.verifyProfilePin(pinned, pin: "1111"))
      ProfileStubServer.reset(["POST /api/v1/profiles/pf_oc_pinned/pin/verify": .unreachable])
      take(await state.verifyProfilePin(pinned, pin: "1111"))
      #expect(state.sessionToken == "stub-token", "still signed in after all three")
    }
    #expect(messages == [
      "Incorrect PIN. 3 tries left before this profile locks.",
      "Too many incorrect PINs. Try again in 5 minutes.",
      "Your NAS needs to be reachable to check this PIN.",
    ])
    #expect(Set(messages).count == 3)
    #expect(!anyAuthFailure)
  }
}

// MARK: - OC-2177 / 2178 / 2180 · offline picker and a dropped connection

@Suite("FR-263 · offline profile handling", .serialized)
@MainActor
struct OfflineProfileTests {

  /// OC-2177 + 2178 · given a three-profile account cached from an earlier online session and
  /// the device offline with no profile chosen, then the picker's list is the cached names in
  /// order, and entering the PIN-less profile works with no network.
  /// Red if: the list stops being served from the cache offline, or switchProfile needs the
  /// network to make a profile active.
  @Test func cachedListShowsAndAPinlessProfileIsEnteredOffline() async {
    await ocAccount(cached: [owner, kid, pinned], active: nil) { state in
      state.isOffline = true
      ProfileStubServer.reset(["GET /api/v1/profiles": .unreachable])
      #expect(state.profiles.map(\.name) == ["Ryan", "Maya", "Zed"])
      state.notePickerTrigger(.coldLaunch)
      #expect(state.needsProfilePicker, "precondition: several profiles, none chosen -> picker")

      await state.switchProfile(to: kid)

      #expect(state.activeProfile?.id == "pf_oc_kid")
      #expect(state.profileStore.activeProfileID == "pf_oc_kid")
      #expect(await state.localStore.activeScope.id == "pf_oc_kid", "offline reads now scoped to Maya")
      #expect(!state.needsProfilePicker)
    }
  }

  /// OC-2180 · given Maya active and the connection drops (device offline, NAS unreachable,
  /// the profile-list refresh fails), then Maya stays active and the picker does not return.
  /// Red if: a failed refreshProfiles clears the active profile or raises the picker.
  @Test func aDroppedConnectionKeepsTheActiveProfile() async {
    await ocAccount(cached: [owner, kid], active: kid, routes: [
      "GET /api/v1/profiles": .unreachable
    ]) { state in
      state.isOffline = true
      state.serverUnreachable = true

      await state.refreshProfiles()
      state.evaluateProfilePicker(listIsFresh: false)

      // APIClient retries a transport failure once (requestWithRetry), so a failed GET is 2 requests.
      #expect(ProfileStubServer.count("GET /api/v1/profiles") >= 1, "the refresh really ran and failed")
      #expect(state.activeProfile?.id == "pf_oc_kid")
      #expect(state.profileStore.activeProfileID == "pf_oc_kid")
      #expect(!state.needsProfilePicker)
      #expect(await state.localStore.activeScope.maxAgeLevel == 1, "still filtering at Maya's ceiling")
    }
  }
}

// MARK: - OC-2174 / 2176 · the local fallback never exceeds the ceiling, through AppState

@Suite("FR-262 · home fallback through AppState", .serialized)
@MainActor
struct HomeFallbackCeilingTests {

  private func seed(_ state: AppState) async {
    var items: [ItemSummary] = []
    for (suffix, level) in [("l1", 1), ("l4", 4)] as [(String, Int)] {
      items.append(ocItem("cw-\(suffix)", level: level, library: "lib_oc_other", day: 1))
      items.append(ocItem("rw-\(suffix)", level: level, library: "lib_oc_other", day: 2))
      items.append(ocItem("ja-\(suffix)", level: level, library: "lib_oc_new", day: 3))
    }
    await state.localStore.upsertItems(items)
    for suffix in ["l1", "l4"] {
      await state.localStore.upsertSingleProgress(itemId: "cw-\(suffix)", positionSeconds: 1800,
                                                  durationSeconds: 7200, profileID: "pf_oc_kid")
      await state.localStore.upsertSingleProgress(itemId: "rw-\(suffix)", positionSeconds: 7000,
                                                  durationSeconds: 7200, profileID: "pf_oc_kid")
    }
  }

  private func ids(_ items: [ItemSummary]) -> Set<String> { Set(items.map(\.id)) }

  /// OC-2174 · given a level-1 profile, the device offline and a cached catalog holding both
  /// level-1 and level-4 titles in every rail, when home loads, then Continue Watching, Just
  /// Added and Recently Watched hold only the level-1 titles.
  /// Red if: homeLoad's cold-start path reads the catalog without the active profile's scope.
  @Test func offlineHomeShowsOnlyTitlesAtOrBelowTheCeiling() async {
    await ocAccount(cached: [owner, kid], active: kid) { state in
      await seed(state)
      state.isOffline = true

      await state.homeLoad()

      #expect(ids(state.homeContinueWatching) == ["cw-l1"])
      #expect(ids(state.homeJustAdded) == ["ja-l1"])
      #expect(ids(state.homeRecentlyWatched) == ["rw-l1"])
    }
  }

  /// OC-2176 · given a level-1 profile online whose server is slow (Just Added fails), then the
  /// rail left on screen is the local fallback, filtered at the ceiling.
  /// Red if: a failed server Just Added replaces the fallback with an unfiltered list, or the
  /// fallback itself is unfiltered.
  @Test func slowServerLeavesAFilteredJustAddedFallback() async {
    await ocAccount(cached: [owner, kid], active: kid, routes: [
      "GET /api/v1/just-added": .unreachable
    ]) { state in
      await seed(state)
      let rails = await state.localStore.queryRails()
      #expect(state.applyRails(rails, startedAt: state.homeStateGeneration))
      await state.loadJustAddedRail()
      #expect(ProfileStubServer.count("GET /api/v1/just-added") >= 1, "the server was asked and failed")
      #expect(ids(state.homeJustAdded) == ["ja-l1"])
    }
  }

  /// OC-2176 boundary · the server answering an EMPTY Just Added (nothing visible to a
  /// level-1 profile) keeps the filtered local fallback, never an unfiltered one.
  /// Red if: the empty-answer branch swaps in unfiltered local rows.
  @Test func anEmptyServerAnswerKeepsTheFilteredFallback() async {
    await ocAccount(cached: [owner, kid], active: kid, routes: [
      "GET /api/v1/just-added": .json(200, #"{"items":[],"total":0}"#)
    ]) { state in
      await seed(state)
      let rails = await state.localStore.queryRails()
      #expect(state.applyRails(rails, startedAt: state.homeStateGeneration))
      await state.loadJustAddedRail()
      #expect(ProfileStubServer.count("GET /api/v1/just-added") >= 1)
      #expect(ids(state.homeJustAdded) == ["ja-l1"])
    }
  }
}

// MARK: - OC-2183 / 2185 · intents ask the server as the active profile

@Suite("FR-264 · intents act for the active profile", .serialized)
@MainActor
struct IntentsActForTheActiveProfileTests {

  private let searchPath = "GET /api/v1/search"

  /// OC-2183 · given Maya (level 1) active and an adult title H that the server withholds from
  /// her search, when Siri's PlayVideoIntent names H, then the search carried Maya's profile
  /// header, nothing is opened for H, the user lands on search, and the intent reports no match.
  /// Red if: the intent searches with a client not bound to the active profile (no/old header
  /// means the server would answer for another ceiling) or opens an item it did not resolve.
  @Test func playIntentForAWithheldTitleOpensNothingAndSendsMayasHeader() async {
    await ocAccount(cached: [owner, kid], active: kid, routes: [
      searchPath: .json(200, #"{"items":[],"total":0}"#)
    ]) { state in
      AppStateHolder.register(state)
      let intent = PlayItemIntent()
      intent.term = "Adult Movie"
      var threwNoMatch = false
      do { _ = try await intent.perform() } catch MediaIntentError.noMatch(let term) {
        threwNoMatch = (term == "Adult Movie")
      } catch {}

      let searches = ProfileStubServer.requests.filter { "\($0.method) \($0.path)" == searchPath }
      #expect(searches.count == 1)
      #expect(searches.first?.profileHeader == "pf_oc_kid")
      #expect(threwNoMatch)
      #expect(state.pendingDeepLinkItemID == nil, "H was never opened")
      #expect(state.pendingSearchTerm == "Adult Movie", "falls back to the search screen")
    }
  }

  /// OC-2183 positive control · a title the server does return for Maya is resolved and opened.
  /// Red if: the intent stops routing a resolved item to the detail deep link (so the negative
  /// test above could pass only because nothing ever opens).
  @Test func playIntentForAVisibleTitleOpensItsDetail() async {
    await ocAccount(cached: [owner, kid], active: kid, routes: [
      searchPath: .json(200, #"{"items":[{"id":"kid-1","type":"movie","title":"Kid Movie","addedAt":"2026-01-01T00:00:00Z","ageLevel":1}],"total":1}"#)
    ]) { state in
      AppStateHolder.register(state)
      let intent = PlayItemIntent()
      intent.term = "Kid Movie"
      _ = try? await intent.perform()
      #expect(state.pendingDeepLinkItemID == "kid-1")
      #expect(state.pendingSearchTerm == nil)
    }
  }

  /// OC-2185 · given no known active profile (picker not yet completed), when an intent runs,
  /// then the request names no profile at all (the server then serves the most restricted
  /// ceiling, FR-221) and nothing from a remembered profile is attached.
  /// Red if: the intent's client falls back to a remembered/last profile id.
  @Test func withNoActiveProfileTheIntentSendsNoProfileHeader() async {
    await ocAccount(cached: [owner, kid], active: nil, routes: [
      searchPath: .json(200, #"{"items":[],"total":0}"#)
    ]) { state in
      AppStateHolder.register(state)
      _ = await MediaIntentRouter.resolveItemID(for: "Anything")
      let searches = ProfileStubServer.requests.filter { "\($0.method) \($0.path)" == searchPath }
      #expect(searches.count == 1)
      #expect(searches.first?.profileHeader == nil)
    }
  }
}

// MARK: - OC-2156 · a play after a switch is a new request under the new profile

@Suite("OC-2156 · playback after a profile switch", .serialized)
@MainActor
struct PlaybackAfterSwitchTests {

  private func playbackJSON(session: String) -> String {
    #"{"kind":"direct","sessionId":"\#(session)","streamUrl":"http://profiles.stub.test/api/v1/playback/\#(session)/stream","resumePositionSeconds":0}"#
  }

  /// OC-2156 · given a play under A (session s_a), when the user switches to B and plays again,
  /// then a NEW playback request goes out carrying B's header, answered with B's own session,
  /// and no request to A's session path carries B's header.
  /// Red if: the client caches the playback answer per item across a switch (no second request),
  /// or the second request still names A.
  @Test func theSecondPlayStartsANewSessionUnderB() async {
    let a = Profile(id: "pf_oc_a", name: "A", avatar: "moon", maxAgeLevel: 4, hasPin: false, isOwner: true)
    let b = Profile(id: "pf_oc_b", name: "B", avatar: "cat", maxAgeLevel: 4, hasPin: false, isOwner: false)
    await ocAccount(cached: [a, b], active: a, routes: [
      "GET /api/v1/items/m1/playback": .json(200, playbackJSON(session: "s_a"))
    ]) { state in
      let first = try? await state.api.playback(id: "m1")
      #expect(first?.resolvedSessionID == "s_a")
      let underA = ProfileStubServer.requests
        .filter { $0.path == "/api/v1/items/m1/playback" }.map(\.profileHeader)
      #expect(underA == ["pf_oc_a"])

      ProfileStubServer.reset([
        "GET /api/v1/items/m1/playback": .json(200, playbackJSON(session: "s_b"))
      ])
      await state.switchProfile(to: b)
      let second = try? await state.api.playback(id: "m1")

      #expect(second?.resolvedSessionID == "s_b")
      let underB = ProfileStubServer.requests
        .filter { $0.path == "/api/v1/items/m1/playback" }.map(\.profileHeader)
      #expect(underB == ["pf_oc_b"], "exactly one new playback request, naming B")
      let touchedASession = ProfileStubServer.requests.filter { $0.path.contains("s_a") }
      #expect(touchedASession.isEmpty, "nothing was requested on A's session after the switch")
    }
  }
}
