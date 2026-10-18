import Foundation
import Testing
@testable import DSM_Video

// FRD-002 §9 (TASK-918, client half): FR-270, FR-274, FR-275, FR-276, AC-002-65, FR-261.

@Suite("Collections browse")
@MainActor
struct CollectionsBrowseTests {
  private func c(_ id: String, _ count: Int = 3) -> MediaCollection {
    MediaCollection(id: id, title: id.capitalized, kind: "studio", itemCount: count, posterImageId: nil)
  }

  private struct Boom: Error {}

  // MARK: Decision table

  @Test func kidsWithCollectionsSeeThemInServerOrder() {
    // Server order is definition order; the client must not re-sort (FR-274).
    let list = [c("holiday"), c("pixar"), c("animation")]
    #expect(CollectionsBrowse.decide(collections: list, load: .loaded, isKids: true, offersCollections: true, isOffline: false)
            == .collections(list))
  }

  @Test func kidsWithNoneSayNoneYetAndFailureIsDistinct() {
    let none = CollectionsBrowse.decide(collections: [], load: .loaded, isKids: true, offersCollections: true, isOffline: false)
    let failed = CollectionsBrowse.decide(collections: [], load: .failed, isKids: true, offersCollections: true, isOffline: false)
    #expect(none == .noneYet)
    #expect(failed == .failed)
    #expect(none != failed, "AC-002-65: none-yet must be distinct from a load failure")
  }

  // REWRITTEN (TASK-1054, Ryan 2026-10-18): was `teensAndAdultsGetAnExtraRowOrNothing`. Adult
  // is no longer offered collections, so this is Teens only; Adult is pinned just below.
  @Test func teensGetAnExtraRowOrNothing() {
    let list = [c("pixar")]
    #expect(CollectionsBrowse.decide(collections: list, load: .loaded, isKids: false, offersCollections: true, isOffline: false)
            == .collections(list))
    #expect(CollectionsBrowse.decide(collections: [], load: .loaded, isKids: false, offersCollections: true, isOffline: false) == .hidden)
    #expect(CollectionsBrowse.decide(collections: [], load: .failed, isKids: false, offersCollections: true, isOffline: false) == .hidden)
  }

  @Test func aProfileOfferedNoCollectionsSeesNoneWhateverTheServerSent() {
    // FR-274 defence in depth: an older server may still list collections for Adult.
    let list = [c("pixar"), c("holiday")]
    for load in [CollectionsLoadState.loaded, .failed, .notLoaded] {
      #expect(CollectionsBrowse.decide(collections: list, load: load, isKids: false,
                                       offersCollections: false, isOffline: false) == .hidden)
      #expect(CollectionsBrowse.decide(collections: [], load: load, isKids: false,
                                       offersCollections: false, isOffline: false) == .hidden)
    }
  }

  @Test func theActiveProfilesFlagDrivesWhatAppStateShows() async {
    let list = [c("pixar")]
    let tiers: [(name: String, profile: Profile, shows: CollectionsBrowse)] = [
      ("kids", Profile(id: "k", name: "K", avatar: "fox", maxAgeLevel: 2, hasPin: false, isOwner: false,
                       kids: true, offersCollections: true), .collections(list)),
      ("teens", Profile(id: "t", name: "T", avatar: "owl", maxAgeLevel: 3, hasPin: false, isOwner: false,
                        kids: false, offersCollections: true), .collections(list)),
      ("adult", Profile(id: "a", name: "A", avatar: "owl", maxAgeLevel: 4, hasPin: false, isOwner: true,
                        kids: false, offersCollections: false), .hidden),
    ]
    for tier in tiers {
      await withIsolatedAppState(cached: [tier.profile], active: tier.profile) { state in
        state.applyCollections(.success(list), startedAt: state.homeStateGeneration)
        #expect(state.collectionsBrowse == tier.shows, "\(tier.name)")
      }
    }
  }

  @Test func kidsKeepCollectionsAndGetNoGenreBar() {
    let kid = Profile(id: "k", name: "K", avatar: "fox", maxAgeLevel: 1, hasPin: false, isOwner: false,
                      kids: true, offersCollections: true)
    let list = [c("pixar"), c("disney")]
    #expect(CollectionsBrowse.decide(collections: list, load: .loaded, isKids: kid.kids,
                                     offersCollections: kid.offersCollections, isOffline: false)
            == .collections(list))
    #expect(!CollectionsBrowse.showsGenres(isKids: kid.kids), "collections replace the genre filter")
  }

  @Test func adultKeepsTheGenreFilterAndGetsNoCollections() {
    let adult = Profile(id: "a", name: "A", avatar: "owl", maxAgeLevel: 4, hasPin: false, isOwner: true,
                        kids: false, offersCollections: false)
    #expect(CollectionsBrowse.showsGenres(isKids: adult.kids))
    #expect(CollectionsBrowse.decide(collections: [c("pixar")], load: .loaded, isKids: adult.kids,
                                     offersCollections: adult.offersCollections, isOffline: false) == .hidden)
  }

  @Test func profileDecodesOffersCollectionsAndFallsBackToKidsWhenAbsent() throws {
    func decode(_ extra: String) throws -> Profile {
      let json = Data("""
        {"id":"p","name":"P","avatar":"fox","maxAgeLevel":3,"hasPin":false,"isOwner":false\(extra)}
        """.utf8)
      return try JSONDecoder().decode(Profile.self, from: json)
    }
    #expect(try decode(#","kids":false,"offersCollections":true"#).offersCollections)
    #expect(try !decode(#","kids":false,"offersCollections":false"#).offersCollections)
    // A server that predates the field: kids still get collections, nobody else gets a row.
    #expect(try decode(#","kids":true"#).offersCollections)
    #expect(try !decode(#","kids":false"#).offersCollections)
    #expect(try !decode("").offersCollections)
  }

  @Test func offlineHidesCollectionsForEveryProfile() {
    let list = [c("pixar")]
    for kids in [true, false] {
      for load in [CollectionsLoadState.loaded, .failed, .notLoaded] {
        #expect(CollectionsBrowse.decide(collections: list, load: load, isKids: kids, offersCollections: true, isOffline: true) == .hidden)
      }
    }
  }

  @Test func notLoadedRendersNothing() {
    #expect(CollectionsBrowse.decide(collections: [], load: .notLoaded, isKids: true, offersCollections: true, isOffline: false) == .hidden)
  }

  @Test func kidsReplaceGenresTeensKeepThem() {
    // Who is a kid is the server's `kids` flag (TASK-921), not a level the client compares.
    let olderKids = Profile(id: "k", name: "K", avatar: "fox", maxAgeLevel: 2, hasPin: false, isOwner: false, kids: true)
    let teens = Profile(id: "t", name: "T", avatar: "owl", maxAgeLevel: 3, hasPin: false, isOwner: false, kids: false)
    #expect(!CollectionsBrowse.showsGenres(isKids: olderKids.kids))
    #expect(CollectionsBrowse.showsGenres(isKids: teens.kids))
  }

  // MARK: Wire shape

  @Test func decodesTheCollectionsEnvelope() throws {
    let json = Data("""
      {"collections":[
        {"id":"pixar","title":"Pixar","kind":"studio","itemCount":14,"posterImageId":"img_p_88"},
        {"id":"halloween","title":"Halloween","kind":"theme","itemCount":2,"posterImageId":null}
      ]}
      """.utf8)
    let resp = try JSONDecoder().decode(CollectionsResponse.self, from: json)
    #expect(resp.collections.map(\.id) == ["pixar", "halloween"])
    #expect(resp.collections[0].itemCount == 14)
    #expect(resp.collections[1].posterImageId == nil)
  }

  @Test func decodesAnEmptyCollectionPage() throws {
    // FR-275: an offered collection with nothing visible is 200 total 0, not an error.
    let resp = try JSONDecoder().decode(ItemsResponse.self, from: Data(#"{"total":0,"items":[]}"#.utf8))
    #expect(resp.effectiveTotal == 0)
  }

  // MARK: Generation fence (FR-261)

  @Test func staleCollectionsResultIsDropped() {
    let state = AppState()
    let started = state.homeStateGeneration
    state.clearHomeState()
    #expect(!state.applyCollections(.success([c("pixar")]), startedAt: started))
    #expect(state.homeCollections.isEmpty)
    #expect(state.homeCollectionsLoad == .notLoaded)

    #expect(state.applyCollections(.success([c("pixar")]), startedAt: state.homeStateGeneration))
    #expect(state.homeCollections.map(\.id) == ["pixar"])
    #expect(state.homeCollectionsLoad == .loaded)
  }

  @Test func clearingStateEmptiesCollections() {
    let state = AppState()
    state.applyCollections(.success([c("pixar")]), startedAt: state.homeStateGeneration)
    state.clearHomeState()
    #expect(state.homeCollections.isEmpty)
    #expect(state.homeCollectionsLoad == .notLoaded)
  }

  @Test func failedRefreshKeepsShownCollectionsButFirstFailureIsRecorded() {
    let state = AppState()
    state.applyCollections(.failure(Boom()), startedAt: state.homeStateGeneration)
    #expect(state.homeCollectionsLoad == .failed)

    state.applyCollections(.success([c("pixar")]), startedAt: state.homeStateGeneration)
    state.applyCollections(.failure(Boom()), startedAt: state.homeStateGeneration)
    #expect(state.homeCollections.map(\.id) == ["pixar"])
    #expect(state.homeCollectionsLoad == .loaded)
  }
}
