import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-975 / TASK-976 · library loading (FRD-001 FR-098, FR-082)

private func llItem(_ id: String, title: String = "Dune", year: Int? = 2021, duration: Int = 9300) -> ItemSummary {
  ItemSummary(
    id: id, type: "movie", title: title, year: year, durationSeconds: duration,
    addedAt: "2026-01-01T00:00:00Z", libraryId: "lib_ll", changeSeq: 1, ageLevel: 1)
}

@MainActor
private func llPage(total: Int?, _ items: [ItemSummary]) throws -> ItemsResponse {
  struct Body: Encodable { let total: Int?; let items: [ItemSummary] }
  let data = try JSONEncoder().encode(Body(total: total, items: items))
  return try JSONDecoder().decode(ItemsResponse.self, from: data)
}

private let llDown: any Error = APIError.connection(.cannotConnectToHost)

@MainActor
struct LibraryPagingTests {

  /// TASK-976 · three distinct server ids that share title, year and runtime all come back, across
  /// a page boundary, and the count equals the server total. Red if a client title|year|runtime
  /// dedup returns: only one of the three would survive.
  @Test func distinctIdsWithTheSameTitleYearAndRuntimeAllAppear() async throws {
    let pages = [
      try llPage(total: 3, [llItem("a"), llItem("b")]),
      try llPage(total: 3, [llItem("c")]),
    ]
    var calls: [Int] = []
    let loaded = try await LibraryPaging.loadAll(pageSize: 2) { _, offset in
      calls.append(offset)
      return pages[offset / 2]
    }
    #expect(loaded.map(\.id) == ["a", "b", "c"])
    #expect(loaded.count == pages[0].effectiveTotal)
    #expect(calls == [0, 2])
  }

  /// The one client rule left: the same id twice is one entry, and a server that keeps repeating a
  /// page cannot make the loop run forever.
  @Test func repeatedIdsCollapseAndARepeatingServerStops() async throws {
    let page = try llPage(total: 99, [llItem("a"), llItem("b")])
    var calls = 0
    let loaded = try await LibraryPaging.loadAll(pageSize: 2) { _, _ in
      calls += 1
      return page
    }
    #expect(loaded.map(\.id) == ["a", "b"])
    #expect(calls == 2, "second page added nothing new, so paging stops")
  }

  @Test func aFailingPageThrowsRatherThanReturningAPartialList() async throws {
    await #expect(throws: APIError.self) {
      try await LibraryPaging.loadAll(pageSize: 2) { _, offset in
        if offset == 0 { return try llPage(total: 4, [llItem("a"), llItem("b")]) }
        throw APIError.connection(.timedOut)
      }
    }
  }
}

@MainActor
struct LibraryListRefreshTests {
  private let movies = Library(id: "l1", title: "Movies", kind: "movie")
  private let shows = Library(id: "l2", title: "TV", kind: "tv")

  /// TASK-975 (a) · a failed pull-to-refresh keeps the list and sets a non-blocking notice.
  /// Red if the failure is made blocking while a list is loaded (the error branch before isEmpty).
  @Test func aFailedRefreshKeepsTheLoadedListAndShowsANotice() {
    var content = LibraryListContent()
    content.finish(.success([movies, shows]))

    content.finish(.failure(llDown))

    #expect(content.libraries.count == 2)
    #expect(content.blockingError == nil)
    #expect(content.noticeMessage != nil)
  }

  @Test func aFailedFirstLoadIsTheFullScreenError() {
    var content = LibraryListContent()
    content.finish(.failure(llDown))

    #expect(content.libraries.isEmpty)
    #expect(content.blockingError != nil)
    #expect(content.noticeMessage == nil)
  }

  @Test func aLaterSuccessClearsTheNotice() {
    var content = LibraryListContent()
    content.finish(.success([movies]))
    content.finish(.failure(llDown))
    content.finish(.success([movies, shows]))

    #expect(content.libraries.count == 2)
    #expect(content.noticeMessage == nil)
    #expect(content.blockingError == nil)
  }
}

@MainActor
struct LibraryGridRefreshTests {
  private let none = GenreSelection(genres: [], mode: .any)
  private let comedy = GenreSelection(genres: ["Comedy"], mode: .any)

  private func loaded(_ ids: [String], library: String = "lib", selection: GenreSelection) -> LibraryGridContent {
    var content = LibraryGridContent()
    content.finish(libraryID: library, requested: selection, result: .success(ids.map { llItem($0) }))
    return content
  }

  /// TASK-975 (b) · a failed refresh of the same library and filter keeps the grid and sets the
  /// notice (the same state drives iOS and tvOS). Red if the failure drops the items or goes
  /// blocking.
  @Test func aFailedRefreshKeepsTheGridAndSetsTheNotice() {
    var content = loaded(["a", "b", "c"], selection: none)

    content.finish(libraryID: "lib", requested: none, result: .failure(llDown))

    #expect(content.items.map(\.id) == ["a", "b", "c"])
    #expect(content.noticeMessage != nil)
    #expect(content.blockingError == nil)
  }

  @Test func aServerErrorIsTreatedTheSameAsAConnectionFailure() {
    var content = loaded(["a"], selection: none)

    content.finish(libraryID: "lib", requested: none, result: .failure(APIError.http(503)))

    #expect(content.items.count == 1)
    #expect(content.noticeMessage != nil)
  }

  /// TASK-975 (c) · the grid on screen is the unfiltered list; the Comedy reload fails. It must
  /// not stay up as if it were the Comedy result. Red if the notice path is taken here.
  @Test func aFailedGenreReloadDoesNotPresentTheUnfilteredGridAsFiltered() {
    var content = loaded(["a", "b", "c"], selection: none)

    content.finish(libraryID: "lib", requested: comedy, result: .failure(llDown))

    #expect(content.items.isEmpty)
    #expect(content.blockingError != nil)
    #expect(content.noticeMessage == nil)
  }

  /// A genre mode change with fewer than two genres changes nothing, so it is the same filter.
  @Test func modeIsIgnoredBelowTwoGenres() {
    #expect(GenreSelection(genres: ["Comedy"], mode: .all) == comedy)
    #expect(GenreSelection(genres: ["Comedy", "Drama"], mode: .all)
            != GenreSelection(genres: ["Comedy", "Drama"], mode: .any))
  }

  /// Another library's grid is not this library's content either (iPad sidebar swap).
  @Test func aFailedLoadOfAnotherLibraryDropsThePreviousLibrarysGrid() {
    var content = loaded(["a"], library: "movies", selection: none)

    content.finish(libraryID: "shows", requested: none, result: .failure(llDown))

    #expect(content.items.isEmpty)
    #expect(content.blockingError != nil)
  }

  @Test func theOfflineCatalogMayOnlyAnswerAnUnfilteredRequest() {
    #expect(LibraryGridContent.cacheMayAnswer(none))
    #expect(!LibraryGridContent.cacheMayAnswer(comedy))
  }

  @Test func aSuccessfulReloadClearsTheNotice() {
    var content = loaded(["a"], selection: none)
    content.finish(libraryID: "lib", requested: none, result: .failure(llDown))
    content.finish(libraryID: "lib", requested: none, result: .success([llItem("a"), llItem("b")]))

    #expect(content.items.count == 2)
    #expect(content.noticeMessage == nil)
  }
}
