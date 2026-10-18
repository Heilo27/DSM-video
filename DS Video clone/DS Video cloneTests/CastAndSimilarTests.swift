import Foundation
import Testing
@testable import DSM_Video

// FR-150 (cast photos) and FR-151 (More Like This), client half: TASK-747.
//
// These pin the decisions the detail page makes from the server's answers: which people it
// lists and with what photo, when it asks for a photo at all, and when the shelf is hidden.
// The server's own contract is pinned by the Go tests (TestFR151_*, cast_photos_test.go).

@MainActor
@Suite("Cast photos and More Like This")
struct CastAndSimilarTests {
  private func detail(_ extra: String) throws -> ItemDetail {
    let json = """
    { "id": "m1", "type": "movie", "title": "Inception"\(extra) }
    """
    return try JSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
  }

  // MARK: castMembers decoding

  @Test func castMembersDecodeInBillingOrderWithPhotoIds() throws {
    let d = try detail("""
    , "castMembers": [
      {"personId": 6193, "name": "Leonardo DiCaprio", "character": "Cobb", "imageId": "cast-6193"},
      {"personId": 24045, "name": "Joseph Gordon-Levitt", "character": "Arthur", "imageId": null}
    ]
    """)
    let list = d.castList
    #expect(list.map(\.name) == ["Leonardo DiCaprio", "Joseph Gordon-Levitt"])
    #expect(list.map(\.role) == ["Cobb", "Arthur"])
    #expect(list.map(\.photoImageID) == ["cast-6193", nil])
    #expect(list.map(\.id) == ["6193", "24045"])
  }

  @Test func castMembersTolerateNullFieldsAndDropNamelessEntries() throws {
    let d = try detail("""
    , "castMembers": [
      {"personId": null, "name": "Name Only", "character": null, "imageId": null},
      {"personId": 1, "name": "   ", "character": "Ghost", "imageId": "cast-1"},
      {"personId": 2, "character": "No Name Key"}
    ]
    """)
    #expect(d.castList.map(\.name) == ["Name Only"], "entries with no usable name are not listed")
    #expect(d.castList.first?.id == nil)
    #expect(d.castList.first?.role == nil)
  }

  @Test func legacyCastIsUsedWhenCastMembersIsAbsent() throws {
    let d = try detail("""
    , "cast": [ {"id": "p1", "name": "Old Server Actor", "role": "Director", "imageId": null} ]
    """)
    #expect(d.castMembers == nil)
    #expect(d.castList.map(\.name) == ["Old Server Actor"])
    #expect(d.castList.first?.role == "Director")
  }

  @Test func legacyCastIsUsedWhenCastMembersIsEmpty() throws {
    let d = try detail("""
    , "castMembers": [], "cast": [ {"id": null, "name": "Names Only", "role": null, "imageId": null} ]
    """)
    #expect(d.castMembers?.isEmpty == true)
    #expect(d.castList.map(\.name) == ["Names Only"])
  }

  @Test func castMembersWinOverLegacyCastWhenBothArePresent() throws {
    let d = try detail("""
    , "castMembers": [ {"personId": 9, "name": "New Shape", "character": null, "imageId": "cast-9"} ],
      "cast": [ {"id": null, "name": "Old Shape", "role": null, "imageId": null} ]
    """)
    #expect(d.castList.map(\.name) == ["New Shape"])
  }

  @Test func noCastAtAllIsAnEmptyListNotAFailure() throws {
    #expect(try detail("").castList.isEmpty)
  }

  // MARK: Photo request rule (FR-150)

  @Test func aNullImageIdMeansNoPhotoRequest() throws {
    let d = try detail("""
    , "castMembers": [ {"personId": 5, "name": "No Photo", "character": "X", "imageId": null} ]
    """)
    let person = try #require(d.castList.first)
    #expect(person.photoImageID == nil, "nil means the view draws initials and makes NO request")
  }

  @Test func aBlankImageIdIsTreatedAsNoPhoto() {
    #expect(ItemDetail.Person(id: nil, name: "A", role: nil, imageId: "").photoImageID == nil)
    #expect(ItemDetail.Person(id: nil, name: "A", role: nil, imageId: "  ").photoImageID == nil)
    #expect(ItemDetail.Person(id: nil, name: "A", role: nil, imageId: "cast-7").photoImageID == "cast-7")
  }

  @Test func aPhotoIdBuildsTheImagesRouteAndANullOneBuildsNothing() throws {
    let api = APIClient(baseURL: try #require(URL(string: "http://nas.local:8080")), token: "t")
    let withPhoto = ItemDetail.Person(id: "6193", name: "A", role: nil, imageId: "cast-6193")
    let without = ItemDetail.Person(id: nil, name: "B", role: nil, imageId: nil)
    let url = try #require(withPhoto.photoImageID.flatMap { api.imageURL(id: $0, width: 185) })
    #expect(url.path == "/api/v1/images/cast-6193")
    #expect(without.photoImageID.flatMap { api.imageURL(id: $0, width: 185) } == nil)
  }

  @Test func initialsAreTheFirstAndLastWordsCapitalised() {
    func initials(_ name: String) -> String {
      ItemDetail.Person(id: nil, name: name, role: nil, imageId: nil).initials
    }
    #expect(initials("Leonardo DiCaprio") == "LD")
    #expect(initials("joseph gordon-levitt") == "JG")
    #expect(initials("Cher") == "C")
    #expect(initials("  Ken   Watanabe ") == "KW")
    #expect(initials("Mary Jane Watson") == "MW")
    #expect(initials("") == "")
    #expect(initials("   ") == "")
  }

  // MARK: /similar response

  @Test func similarResponseDecodesAsTheStandardItemList() throws {
    let json = """
    {"items": [
      {"id": "a", "type": "movie", "title": "Interstellar", "year": 2014, "addedAt": "2026-01-01T00:00:00Z",
       "posterImageId": "p-a"},
      {"id": "b", "type": "episode", "title": "Pilot", "addedAt": "2026-02-01T00:00:00Z",
       "showName": "Fringe", "showFolderId": "fringe"}
    ]}
    """
    let response = try JSONDecoder().decode(ItemsResponse.self, from: Data(json.utf8))
    #expect(response.items.map(\.id) == ["a", "b"])
    #expect(response.total == nil, "/similar sends no total")
    #expect(response.items[1].showName == "Fringe")
  }

  // MARK: Hide rules (FR-151)

  private func summary(_ id: String) throws -> ItemSummary {
    try response([id]).items[0]
  }

  private func response(_ ids: [String]) throws -> ItemsResponse {
    let items = ids.map { #"{"id":"\#($0)","type":"movie","title":"\#($0)","addedAt":"2026-01-01T00:00:00Z"}"# }
    let json = #"{"items":[\#(items.joined(separator: ","))]}"#
    return try JSONDecoder().decode(ItemsResponse.self, from: Data(json.utf8))
  }

  @Test func theShelfShowsWhenTheServerReturnsTitles() throws {
    let outcome = MoreLikeThis.outcome(.success(try response(["a", "b"])))
    #expect(outcome == .shelf([try summary("a"), try summary("b")]))
  }

  @Test func anEmptyListHidesTheShelf() throws {
    #expect(MoreLikeThis.outcome(.success(try response([]))) == .hidden)
  }

  @Test func everyFailureHidesTheShelf() {
    let failures: [Error] = [
      APIError.http(500),
      APIError.http(403),
      APIError.server("content_restricted", status: 403),
      APIError.server("not_found", status: 404),
      APIError.network,
      APIError.connection(.timedOut),
      APIError.invalidURL,
      URLError(.cancelled),
    ]
    for failure in failures {
      #expect(MoreLikeThis.outcome(.failure(failure)) == .hidden, "\(failure) must hide the shelf")
    }
  }

  @Test func onlyTheServersOwnNoShelfAnswersAreQuietlyExpected() {
    #expect(MoreLikeThis.isExpectedHide(APIError.server("content_restricted", status: 403)))
    #expect(MoreLikeThis.isExpectedHide(APIError.server("not_found", status: 404)))
    #expect(MoreLikeThis.isExpectedHide(APIError.http(403)))
    #expect(MoreLikeThis.isExpectedHide(APIError.http(404)))
    #expect(!MoreLikeThis.isExpectedHide(APIError.http(500)))
    #expect(!MoreLikeThis.isExpectedHide(APIError.server("db_error", status: 500)))
    #expect(!MoreLikeThis.isExpectedHide(APIError.network))
    #expect(!MoreLikeThis.isExpectedHide(URLError(.timedOut)))
  }

  @Test func theShelfAsksForTheServersDefaultTwelve() {
    #expect(MoreLikeThis.limit == 12)
  }
}
