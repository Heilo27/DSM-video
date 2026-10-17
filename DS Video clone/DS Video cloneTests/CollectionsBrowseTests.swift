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
    #expect(CollectionsBrowse.decide(collections: list, load: .loaded, isKids: true, isOffline: false)
            == .collections(list))
  }

  @Test func kidsWithNoneSayNoneYetAndFailureIsDistinct() {
    let none = CollectionsBrowse.decide(collections: [], load: .loaded, isKids: true, isOffline: false)
    let failed = CollectionsBrowse.decide(collections: [], load: .failed, isKids: true, isOffline: false)
    #expect(none == .noneYet)
    #expect(failed == .failed)
    #expect(none != failed, "AC-002-65: none-yet must be distinct from a load failure")
  }

  @Test func teensAndAdultsGetAnExtraRowOrNothing() {
    let list = [c("pixar")]
    #expect(CollectionsBrowse.decide(collections: list, load: .loaded, isKids: false, isOffline: false)
            == .collections(list))
    #expect(CollectionsBrowse.decide(collections: [], load: .loaded, isKids: false, isOffline: false) == .hidden)
    #expect(CollectionsBrowse.decide(collections: [], load: .failed, isKids: false, isOffline: false) == .hidden)
  }

  @Test func offlineHidesCollectionsForEveryProfile() {
    let list = [c("pixar")]
    for kids in [true, false] {
      for load in [CollectionsLoadState.loaded, .failed, .notLoaded] {
        #expect(CollectionsBrowse.decide(collections: list, load: load, isKids: kids, isOffline: true) == .hidden)
      }
    }
  }

  @Test func notLoadedRendersNothing() {
    #expect(CollectionsBrowse.decide(collections: [], load: .notLoaded, isKids: true, isOffline: false) == .hidden)
  }

  @Test func kidsReplaceGenresTeensKeepThem() {
    let olderKids = Profile(id: "k", name: "K", avatar: "fox", maxAgeLevel: 2, hasPin: false, isOwner: false)
    let teens = Profile(id: "t", name: "T", avatar: "owl", maxAgeLevel: 3, hasPin: false, isOwner: false)
    #expect(!CollectionsBrowse.showsGenres(isKids: olderKids.isKids))
    #expect(CollectionsBrowse.showsGenres(isKids: teens.isKids))
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
