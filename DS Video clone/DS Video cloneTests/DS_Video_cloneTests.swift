import Foundation
import Testing
@testable import DS_Video_clone

// MARK: - normalizedBaseURL Tests

struct NormalizedBaseURLTests {

  // MARK: Scheme handling

  @Test func addsHTTPSchemeWhenMissing() {
    let url = normalizedBaseURL("myserver.local", forceHTTPS: false)
    #expect(url.scheme == "http")
    #expect(url.host == "myserver.local" || url.host() == "myserver.local")
  }

  @Test func addsHTTPSSchemeWhenMissingAndForced() {
    let url = normalizedBaseURL("myserver.local", forceHTTPS: true)
    #expect(url.scheme == "https")
  }

  @Test func preservesExistingHTTPScheme() {
    let url = normalizedBaseURL("http://myserver.local", forceHTTPS: false)
    #expect(url.scheme == "http")
  }

  @Test func forcesHTTPSReplacesHTTP() {
    let url = normalizedBaseURL("http://myserver.local", forceHTTPS: true)
    #expect(url.scheme == "https")
  }

  @Test func preservesExistingHTTPS() {
    let url = normalizedBaseURL("https://myserver.local", forceHTTPS: false)
    #expect(url.scheme == "https")
  }

  @Test func preservesExistingHTTPSWithForce() {
    let url = normalizedBaseURL("https://myserver.local", forceHTTPS: true)
    #expect(url.scheme == "https")
  }

  // MARK: Whitespace trimming

  @Test func trimsWhitespace() {
    let url = normalizedBaseURL("  http://myserver.local  ", forceHTTPS: false)
    #expect(url.host == "myserver.local" || url.host() == "myserver.local")
  }

  @Test func trimsNewlines() {
    let url = normalizedBaseURL("\nhttp://myserver.local\n", forceHTTPS: false)
    #expect(url.host == "myserver.local" || url.host() == "myserver.local")
  }

  // MARK: Synology NAS port detection

  @Test func addsPort5000ForSynologyIP() {
    let url = normalizedBaseURL("192.168.1.100", forceHTTPS: false)
    #expect(url.port == 5000)
  }

  @Test func addsPort5001ForSynologyIPWithHTTPS() {
    let url = normalizedBaseURL("192.168.1.100", forceHTTPS: true)
    #expect(url.port == 5001)
  }

  @Test func addsPortForSynologyMeDomain() {
    let url = normalizedBaseURL("mynas.synology.me", forceHTTPS: false)
    #expect(url.port == 5000)
  }

  @Test func addsPortForQuickConnectDomain() {
    let url = normalizedBaseURL("mynas.quickconnect.to", forceHTTPS: false)
    #expect(url.port == 5000)
  }

  @Test func addsPort5001ForSynologyMeWithHTTPS() {
    let url = normalizedBaseURL("mynas.synology.me", forceHTTPS: true)
    #expect(url.port == 5001)
  }

  // MARK: Explicit port preserved

  @Test func preservesExplicitPort() {
    let url = normalizedBaseURL("http://192.168.1.100:8080", forceHTTPS: false)
    #expect(url.port == 8080)
  }

  @Test func preservesExplicitPortOnSynologyDomain() {
    let url = normalizedBaseURL("http://mynas.synology.me:9000", forceHTTPS: false)
    #expect(url.port == 9000)
  }

  // MARK: Non-Synology hosts

  @Test func noPortForRegularDomain() {
    let url = normalizedBaseURL("http://myserver.example.com", forceHTTPS: false)
    #expect(url.port == nil)
  }

  @Test func noAutoPortForNonSynologyIP() {
    let url = normalizedBaseURL("http://10.0.0.1", forceHTTPS: false)
    #expect(url.port == nil)
  }

  // MARK: Fallback for invalid input

  @Test func fallsBackToLocalhostForInvalidURL() {
    // Characters that make URL(string:) return nil
    let url = normalizedBaseURL("://bad url with spaces", forceHTTPS: false)
    #expect(url.absoluteString.contains("localhost"))
  }

  // MARK: Sub-path in 192.168.x.x range

  @Test func addsPortForVariousSynologySubnets() {
    let url1 = normalizedBaseURL("192.168.0.1", forceHTTPS: false)
    #expect(url1.port == 5000)

    let url2 = normalizedBaseURL("192.168.50.100", forceHTTPS: false)
    #expect(url2.port == 5000)

    let url3 = normalizedBaseURL("192.168.255.1", forceHTTPS: false)
    #expect(url3.port == 5000)
  }
}

// MARK: - APIClient Tests

struct APIClientTests {

  // MARK: Initialization

  @Test func initializesWithCorrectProperties() {
    let url = URL(string: "http://localhost:8090")!
    let client = APIClient(baseURL: url, token: "test-token", tmdbAPIKey: "tmdb-key")
    #expect(client.baseURL == url)
    #expect(client.token == "test-token")
    #expect(client.tmdbAPIKey == "tmdb-key")
  }

  @Test func initializesWithNilOptionals() {
    let url = URL(string: "http://localhost:8090")!
    let client = APIClient(baseURL: url, token: nil)
    #expect(client.token == nil)
    #expect(client.tmdbAPIKey == nil)
  }

  // MARK: imageURL construction

  @Test func imageURLConstructsCorrectPath() {
    let url = URL(string: "http://localhost:8090")!
    let client = APIClient(baseURL: url, token: "tok")
    let imageURL = client.imageURL(id: "abc123")
    #expect(imageURL != nil)
    #expect(imageURL!.path.contains("/api/v1/images/abc123"))
  }

  @Test func imageURLIncludesWidthParameter() {
    let url = URL(string: "http://localhost:8090")!
    let client = APIClient(baseURL: url, token: "tok")
    let imageURL = client.imageURL(id: "abc123", width: 300)
    #expect(imageURL != nil)
    let query = imageURL!.query ?? ""
    #expect(query.contains("w=300"))
  }

  @Test func imageURLOmitsWidthWhenNil() {
    let url = URL(string: "http://localhost:8090")!
    let client = APIClient(baseURL: url, token: "tok")
    let imageURL = client.imageURL(id: "abc123")
    #expect(imageURL != nil)
    let query = imageURL?.query
    // No query items at all when width is nil
    #expect(query == nil || !query!.contains("w="))
  }
}

// MARK: - APIError Tests

struct APIErrorTests {

  @Test func networkErrorMessage() {
    let error = APIError.network
    #expect(error.userMessage == "Network error.")
  }

  @Test func httpErrorMessage() {
    let error = APIError.http(404)
    #expect(error.userMessage == "Server error (404).")
  }

  @Test func httpErrorMessage500() {
    let error = APIError.http(500)
    #expect(error.userMessage == "Server error (500).")
  }

  @Test func serverErrorReplacesUnderscores() {
    let error = APIError.server("invalid_credentials")
    #expect(error.userMessage == "invalid credentials")
  }

  @Test func serverErrorPlainMessage() {
    let error = APIError.server("Something went wrong")
    #expect(error.userMessage == "Something went wrong")
  }

  @Test func invalidURLErrorMessage() {
    let error = APIError.invalidURL
    #expect(error.userMessage == "Invalid server URL.")
  }
}

// MARK: - WebAPIError Tests

struct WebAPIErrorTests {

  @Test func invalidURLMessage() {
    let error = WebAPIError.invalidURL
    #expect(error.userMessage == "Invalid URL")
  }

  @Test func networkMessage() {
    let error = WebAPIError.network
    #expect(error.userMessage == "Network error. Check your connection and try again.")
  }

  @Test func httpMessage() {
    let error = WebAPIError.http(403)
    #expect(error.userMessage == "HTTP error (403)")
  }

  @Test func serverError101SpecificMessage() {
    let error = WebAPIError.server(101, nil)
    #expect(error.userMessage.contains("Invalid parameter"))
  }

  @Test func serverError1101SpecificMessage() {
    let error = WebAPIError.server(1101, nil)
    #expect(error.userMessage.contains("File not found"))
  }

  @Test func serverErrorGeneric() {
    let error = WebAPIError.server(500, ["Internal error"])
    #expect(error.userMessage.contains("500"))
    #expect(error.userMessage.contains("Internal error"))
  }

  @Test func loginFailedMessage() {
    let error = WebAPIError.loginFailed
    #expect(error.userMessage.contains("Login failed"))
  }

  @Test func notImplementedMessage() {
    let error = WebAPIError.notImplemented
    #expect(error.userMessage == "Not yet implemented")
  }
}

// MARK: - APIModels Encoding/Decoding Tests

struct APIModelsCodingTests {

  // MARK: LoginRequest encoding

  @Test func loginRequestEncodesCorrectly() throws {
    let req = LoginRequest(username: "admin", password: "secret", otp: nil)
    let data = try JSONEncoder().encode(req)
    let dict = try JSONDecoder().decode([String: String?].self, from: data)
    #expect(dict["username"] == "admin")
    #expect(dict["password"] == "secret")
  }

  @Test func loginRequestEncodesWithOTP() throws {
    let req = LoginRequest(username: "admin", password: "secret", otp: "123456")
    let data = try JSONEncoder().encode(req)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("123456"))
  }

  // MARK: LoginResponse decoding

  @Test func loginResponseDecodesCorrectly() throws {
    let json = """
    {
      "token": "jwt-token-123",
      "user": {
        "id": "u1",
        "username": "admin",
        "displayName": "Admin User"
      }
    }
    """
    let resp = try JSONDecoder().decode(LoginResponse.self, from: json.data(using: .utf8)!)
    #expect(resp.token == "jwt-token-123")
    #expect(resp.user.id == "u1")
    #expect(resp.user.username == "admin")
    #expect(resp.user.displayName == "Admin User")
  }

  // MARK: LibrariesResponse decoding

  @Test func librariesResponseDecodes() throws {
    let json = """
    {
      "libraries": [
        {"id": "lib1", "title": "Movies", "kind": "movie"},
        {"id": "lib2", "title": "TV Shows", "kind": "tvshow"}
      ]
    }
    """
    let resp = try JSONDecoder().decode(LibrariesResponse.self, from: json.data(using: .utf8)!)
    #expect(resp.libraries.count == 2)
    #expect(resp.libraries[0].id == "lib1")
    #expect(resp.libraries[0].title == "Movies")
    #expect(resp.libraries[0].kind == "movie")
  }

  // MARK: ItemsResponse decoding

  @Test func itemsResponseDecodes() throws {
    let json = """
    {
      "total": 1,
      "items": [{
        "id": "item1",
        "type": "movie",
        "title": "Test Movie",
        "year": 2024,
        "durationSeconds": 7200,
        "addedAt": "2024-01-01",
        "rating": 7.5,
        "posterImageId": "poster1",
        "backdropImageId": "backdrop1",
        "progress": null
      }]
    }
    """
    let resp = try JSONDecoder().decode(ItemsResponse.self, from: json.data(using: .utf8)!)
    #expect(resp.total == 1)
    #expect(resp.items.count == 1)
    #expect(resp.items[0].title == "Test Movie")
    #expect(resp.items[0].year == 2024)
    #expect(resp.items[0].durationSeconds == 7200)
    #expect(resp.items[0].rating == 7.5)
    #expect(resp.items[0].progress == nil)
  }

  @Test func itemsResponseWithProgress() throws {
    let json = """
    {
      "total": 1,
      "items": [{
        "id": "item1",
        "type": "movie",
        "title": "Test Movie",
        "year": null,
        "durationSeconds": null,
        "addedAt": "",
        "rating": null,
        "posterImageId": null,
        "backdropImageId": null,
        "progress": {
          "positionSeconds": 1800,
          "durationSeconds": 7200,
          "updatedAt": "2024-06-15T12:00:00Z"
        }
      }]
    }
    """
    let resp = try JSONDecoder().decode(ItemsResponse.self, from: json.data(using: .utf8)!)
    let item = resp.items[0]
    #expect(item.progress != nil)
    #expect(item.progress?.positionSeconds == 1800)
    #expect(item.progress?.durationSeconds == 7200)
  }

  // MARK: ItemDetail decoding

  @Test func itemDetailDecodes() throws {
    let json = """
    {
      "id": "m1",
      "type": "movie",
      "title": "Inception",
      "originalTitle": "Inception",
      "year": 2010,
      "durationSeconds": 8880,
      "contentRating": "PG-13",
      "summary": "A thief who enters dreams.",
      "genres": ["Action", "Sci-Fi"],
      "cast": [
        {"id": "p1", "name": "Leonardo DiCaprio", "role": "Cobb", "imageId": null}
      ],
      "images": {
        "poster": {"id": "poster1", "mapperId": null},
        "backdrop": {"id": "backdrop1", "mapperId": "42"}
      }
    }
    """
    let detail = try JSONDecoder().decode(ItemDetail.self, from: json.data(using: .utf8)!)
    #expect(detail.id == "m1")
    #expect(detail.title == "Inception")
    #expect(detail.year == 2010)
    #expect(detail.genres.count == 2)
    #expect(detail.cast.count == 1)
    #expect(detail.cast[0].name == "Leonardo DiCaprio")
    #expect(detail.images.poster.id == "poster1")
    #expect(detail.images.backdrop.mapperId == "42")
  }

  // MARK: PlaybackInfo decoding

  @Test func playbackInfoDecodes() throws {
    let json = """
    {
      "kind": "hls",
      "streamUrl": "http://localhost/stream.mp4",
      "hlsMasterUrl": "http://localhost/master.m3u8",
      "resumePositionSeconds": 300
    }
    """
    let info = try JSONDecoder().decode(PlaybackInfo.self, from: json.data(using: .utf8)!)
    #expect(info.kind == "hls")
    #expect(info.streamUrl?.absoluteString == "http://localhost/stream.mp4")
    #expect(info.hlsMasterUrl?.absoluteString == "http://localhost/master.m3u8")
    #expect(info.resumePositionSeconds == 300)
  }

  @Test func playbackInfoDecodesWithNullURLs() throws {
    let json = """
    {
      "kind": "direct",
      "streamUrl": null,
      "hlsMasterUrl": null,
      "resumePositionSeconds": 0
    }
    """
    let info = try JSONDecoder().decode(PlaybackInfo.self, from: json.data(using: .utf8)!)
    #expect(info.kind == "direct")
    #expect(info.streamUrl == nil)
    #expect(info.hlsMasterUrl == nil)
  }

  // MARK: ProgressRequest encoding

  @Test func progressRequestEncodes() throws {
    let req = ProgressRequest(positionSeconds: 600, durationSeconds: 7200, state: "playing")
    let data = try JSONEncoder().encode(req)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("600"))
    #expect(json.contains("7200"))
    #expect(json.contains("playing"))
  }

  // MARK: PairingCodeResponse decoding

  @Test func pairingCodeResponseDecodes() throws {
    let json = """
    {"code": "ABC-123", "expiresInSeconds": 300}
    """
    let resp = try JSONDecoder().decode(PairingCodeResponse.self, from: json.data(using: .utf8)!)
    #expect(resp.code == "ABC-123")
    #expect(resp.expiresInSeconds == 300)
  }

  // MARK: PairingCodeExchangeRequest encoding

  @Test func pairingCodeExchangeRequestEncodes() throws {
    let req = PairingCodeExchangeRequest(code: "XYZ-789")
    let data = try JSONEncoder().encode(req)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("XYZ-789"))
  }

  // MARK: APIErrorResponse decoding

  @Test func apiErrorResponseDecodes() throws {
    let json = """
    {"error": "invalid_credentials"}
    """
    let resp = try JSONDecoder().decode(APIErrorResponse.self, from: json.data(using: .utf8)!)
    #expect(resp.error == "invalid_credentials")
  }
}

// MARK: - VideoStation WebAPI Response Decoding Tests

struct WebAPIResponseDecodingTests {

  // MARK: WebAPIResponse success

  @Test func webAPIResponseDecodesSuccess() throws {
    let json = """
    {
      "success": true,
      "data": {
        "sid": "session-abc",
        "synotoken": "token-xyz",
        "did": "device-123"
      }
    }
    """
    let resp = try JSONDecoder().decode(WebAPIResponse<WebAPILoginData>.self, from: json.data(using: .utf8)!)
    #expect(resp.success == true)
    #expect(resp.data?.sid == "session-abc")
    #expect(resp.data?.synotoken == "token-xyz")
    #expect(resp.data?.did == "device-123")
    #expect(resp.error == nil)
  }

  // MARK: WebAPIResponse error

  @Test func webAPIResponseDecodesError() throws {
    let json = """
    {
      "success": false,
      "error": {
        "code": 400,
        "errors": ["Invalid request"]
      }
    }
    """
    let resp = try JSONDecoder().decode(WebAPIResponse<WebAPILoginData>.self, from: json.data(using: .utf8)!)
    #expect(resp.success == false)
    #expect(resp.data == nil)
    #expect(resp.error?.code == 400)
    #expect(resp.error?.errors?.first == "Invalid request")
  }

  // MARK: WebAPILoginData

  @Test func loginDataDecodesMinimal() throws {
    let json = """
    {"sid": "session123"}
    """
    let data = try JSONDecoder().decode(WebAPILoginData.self, from: json.data(using: .utf8)!)
    #expect(data.sid == "session123")
    #expect(data.synotoken == nil)
    #expect(data.did == nil)
  }

  // MARK: VideoStationLibrariesData - singular "library" key

  @Test func librariesDataDecodesSingularKey() throws {
    let json = """
    {
      "library": [
        {"id": 0, "name": "Movies", "type": "movie"},
        {"id": 0, "name": "TV Shows", "type": "tvshow"}
      ]
    }
    """
    let data = try JSONDecoder().decode(VideoStationLibrariesData.self, from: json.data(using: .utf8)!)
    #expect(data.libraries?.count == 2)
    #expect(data.libraries?[0].name == "Movies")
    #expect(data.libraries?[0].type == "movie")
  }

  @Test func librariesDataDecodesPluralKey() throws {
    let json = """
    {
      "libraries": [
        {"id": 1, "name": "Home Videos", "type": "homevideo"}
      ]
    }
    """
    let data = try JSONDecoder().decode(VideoStationLibrariesData.self, from: json.data(using: .utf8)!)
    #expect(data.libraries?.count == 1)
    #expect(data.libraries?[0].name == "Home Videos")
  }

  // MARK: VideoStationLibrary flexible decoding

  @Test func libraryDecodesStringId() throws {
    let json = """
    {"id": "42", "name": "Test Library"}
    """
    let lib = try JSONDecoder().decode(VideoStationLibrary.self, from: json.data(using: .utf8)!)
    #expect(lib.id == 42)
    #expect(lib.name == "Test Library")
  }

  @Test func libraryDecodesTitleFallback() throws {
    let json = """
    {"id": 0, "title": "My Movies"}
    """
    let lib = try JSONDecoder().decode(VideoStationLibrary.self, from: json.data(using: .utf8)!)
    #expect(lib.name == "My Movies")
  }

  @Test func libraryDecodesLibraryNameFallback() throws {
    let json = """
    {"id": 0, "library_name": "Shared Library"}
    """
    let lib = try JSONDecoder().decode(VideoStationLibrary.self, from: json.data(using: .utf8)!)
    #expect(lib.name == "Shared Library")
  }

  // MARK: VideoStationItemsData - different item keys

  @Test func itemsDataDecodesMovieKey() throws {
    let json = """
    {
      "total": 1,
      "movie": [
        {"id": 101, "title": "Test Movie"}
      ]
    }
    """
    let data = try JSONDecoder().decode(VideoStationItemsData.self, from: json.data(using: .utf8)!)
    #expect(data.total == 1)
    #expect(data.items.count == 1)
    #expect(data.items[0].title == "Test Movie")
  }

  @Test func itemsDataDecodesTvshowKey() throws {
    let json = """
    {
      "total": 2,
      "tvshow": [
        {"id": 1, "title": "Show A"},
        {"id": 2, "title": "Show B"}
      ]
    }
    """
    let data = try JSONDecoder().decode(VideoStationItemsData.self, from: json.data(using: .utf8)!)
    #expect(data.total == 2)
    #expect(data.items.count == 2)
  }

  @Test func itemsDataDecodesHomevideoKey() throws {
    let json = """
    {
      "total": 1,
      "homevideo": [
        {"id": 5, "title": "Vacation 2024"}
      ]
    }
    """
    let data = try JSONDecoder().decode(VideoStationItemsData.self, from: json.data(using: .utf8)!)
    #expect(data.items.count == 1)
    #expect(data.items[0].title == "Vacation 2024")
  }

  @Test func itemsDataDefaultsToEmptyWhenNoKnownKey() throws {
    let json = """
    {
      "total": 0,
      "unknown_key": []
    }
    """
    let data = try JSONDecoder().decode(VideoStationItemsData.self, from: json.data(using: .utf8)!)
    #expect(data.items.isEmpty)
  }

  // MARK: VideoStationItem decoding

  @Test func itemDecodesBasicFields() throws {
    let json = """
    {
      "id": 42,
      "title": "Blade Runner 2049",
      "type": "movie",
      "year": 2017,
      "duration": 9900,
      "rating": 8.0,
      "mapper_id": 99
    }
    """
    let item = try JSONDecoder().decode(VideoStationItem.self, from: json.data(using: .utf8)!)
    #expect(item.id == 42)
    #expect(item.title == "Blade Runner 2049")
    #expect(item.type == "movie")
    #expect(item.year == 2017)
    #expect(item.duration == 9900)
    #expect(item.rating == 8.0)
    #expect(item.mapper_id == 99)
  }

  @Test func itemDecodesStringId() throws {
    let json = """
    {"id": "123", "title": "Test"}
    """
    let item = try JSONDecoder().decode(VideoStationItem.self, from: json.data(using: .utf8)!)
    #expect(item.id == 123)
  }

  @Test func itemExtractsYearFromOriginalAvailable() throws {
    let json = """
    {"id": 1, "title": "Test", "original_available": "2010-11-12"}
    """
    let item = try JSONDecoder().decode(VideoStationItem.self, from: json.data(using: .utf8)!)
    #expect(item.year == 2010)
  }

  @Test func itemExtractsYearFromFourDigitOriginalAvailable() throws {
    let json = """
    {"id": 1, "title": "Test", "original_available": "1977"}
    """
    let item = try JSONDecoder().decode(VideoStationItem.self, from: json.data(using: .utf8)!)
    #expect(item.year == 1977)
  }

  @Test func itemUsesCreateTimeForAddedAt() throws {
    let json = """
    {"id": 1, "title": "Test", "create_time": 1700000000}
    """
    let item = try JSONDecoder().decode(VideoStationItem.self, from: json.data(using: .utf8)!)
    #expect(item.added_at == "1700000000")
  }

  @Test func itemDecodesWatchStatus() throws {
    let json = """
    {
      "id": 1,
      "title": "Test",
      "watch_status": {
        "time": 600,
        "total_time": 7200,
        "updated_at": "2024-01-01"
      }
    }
    """
    let item = try JSONDecoder().decode(VideoStationItem.self, from: json.data(using: .utf8)!)
    #expect(item.watch_status?.time == 600)
    #expect(item.watch_status?.total_time == 7200)
  }

  @Test func itemFallsBackToMapperIdForPoster() throws {
    let json = """
    {"id": 1, "title": "Test", "mapper_id": 55}
    """
    let item = try JSONDecoder().decode(VideoStationItem.self, from: json.data(using: .utf8)!)
    #expect(item.poster == "55")
    #expect(item.backdrop == "55")
  }

  @Test func itemPrefersPosterFieldOverMapperId() throws {
    let json = """
    {"id": 1, "title": "Test", "poster": "custom-poster", "backdrop": "custom-backdrop", "mapper_id": 55}
    """
    let item = try JSONDecoder().decode(VideoStationItem.self, from: json.data(using: .utf8)!)
    #expect(item.poster == "custom-poster")
    #expect(item.backdrop == "custom-backdrop")
  }

  // MARK: VideoStationItemDetailArrayData

  @Test func itemDetailArrayDecodesMovieKey() throws {
    let json = """
    {
      "movie": [{
        "id": 1,
        "title": "Test Movie",
        "type": "movie",
        "summary": "A great film",
        "genres": ["Action"],
        "actors": [{"name": "John", "role": "Hero"}]
      }]
    }
    """
    let data = try JSONDecoder().decode(VideoStationItemDetailArrayData.self, from: json.data(using: .utf8)!)
    #expect(data.item != nil)
    #expect(data.item?.title == "Test Movie")
    #expect(data.item?.summary == "A great film")
    #expect(data.item?.genres?.count == 1)
    #expect(data.item?.actors?.count == 1)
    #expect(data.item?.actors?[0].name == "John")
  }

  @Test func itemDetailArrayDecodesTvshowKey() throws {
    let json = """
    {
      "tvshow": [{
        "id": 2,
        "title": "Test Show"
      }]
    }
    """
    let data = try JSONDecoder().decode(VideoStationItemDetailArrayData.self, from: json.data(using: .utf8)!)
    #expect(data.item?.title == "Test Show")
  }

  @Test func itemDetailArrayReturnsNilForEmptyArrays() throws {
    let json = """
    {
      "movie": []
    }
    """
    let data = try JSONDecoder().decode(VideoStationItemDetailArrayData.self, from: json.data(using: .utf8)!)
    #expect(data.item == nil)
  }

  // MARK: VideoStationItemDetail

  @Test func itemDetailDecodesFullFields() throws {
    let json = """
    {
      "id": 10,
      "title": "Inception",
      "type": "movie",
      "original_title": "Inception",
      "year": 2010,
      "duration": 8880,
      "rating": "PG-13",
      "summary": "Dreams within dreams",
      "genres": ["Sci-Fi", "Action"],
      "actors": [
        {"name": "DiCaprio", "role": "Cobb"},
        {"name": "Hardy", "role": "Eames"}
      ],
      "poster": "poster-img-id",
      "backdrop": "backdrop-img-id",
      "mapper_id": 42
    }
    """
    let detail = try JSONDecoder().decode(VideoStationItemDetail.self, from: json.data(using: .utf8)!)
    #expect(detail.id == 10)
    #expect(detail.title == "Inception")
    #expect(detail.original_title == "Inception")
    #expect(detail.year == 2010)
    #expect(detail.duration == 8880)
    #expect(detail.rating == "PG-13")
    #expect(detail.genres?.count == 2)
    #expect(detail.actors?.count == 2)
    #expect(detail.poster == "poster-img-id")
    #expect(detail.backdrop == "backdrop-img-id")
    #expect(detail.mapper_id == 42)
  }

  @Test func itemDetailFallsBackToMapperIdForImages() throws {
    let json = """
    {
      "id": 10,
      "title": "No Poster",
      "mapper_id": 77
    }
    """
    let detail = try JSONDecoder().decode(VideoStationItemDetail.self, from: json.data(using: .utf8)!)
    #expect(detail.poster == "77")
    #expect(detail.backdrop == "77")
  }

  // MARK: VideoStationStreamOpenData

  @Test func streamOpenDataDecodes() throws {
    let json = """
    {"stream_id": "stream-abc-123", "format": "raw"}
    """
    let data = try JSONDecoder().decode(VideoStationStreamOpenData.self, from: json.data(using: .utf8)!)
    #expect(data.stream_id == "stream-abc-123")
    #expect(data.format == "raw")
  }

  @Test func streamOpenDataDecodesNullFields() throws {
    let json = """
    {}
    """
    let data = try JSONDecoder().decode(VideoStationStreamOpenData.self, from: json.data(using: .utf8)!)
    #expect(data.stream_id == nil)
    #expect(data.format == nil)
  }

  // MARK: WebAPIErrorResponse

  @Test func errorResponseDecodes() throws {
    let json = """
    {
      "success": false,
      "error": {
        "code": 401,
        "errors": ["Not authenticated", "Session expired"]
      }
    }
    """
    let resp = try JSONDecoder().decode(WebAPIErrorResponse.self, from: json.data(using: .utf8)!)
    #expect(resp.success == false)
    #expect(resp.error.code == 401)
    #expect(resp.error.errors?.count == 2)
  }

  @Test func errorResponseDecodesWithoutErrors() throws {
    let json = """
    {
      "success": false,
      "error": {
        "code": 500
      }
    }
    """
    let resp = try JSONDecoder().decode(WebAPIErrorResponse.self, from: json.data(using: .utf8)!)
    #expect(resp.error.code == 500)
    #expect(resp.error.errors == nil)
  }
}

// MARK: - VideoStationWebAPIClient Unit Tests

struct VideoStationWebAPIClientTests {

  // MARK: Initialization

  @Test func initWithDefaults() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url)
    #expect(client.baseURL == url)
    #expect(client.sessionID == nil)
    #expect(client.synoToken == nil)
    #expect(client.deviceID == nil)
  }

  @Test func initWithSession() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url, sessionID: "sid", synoToken: "token", deviceID: "did")
    #expect(client.sessionID == "sid")
    #expect(client.synoToken == "token")
    #expect(client.deviceID == "did")
  }

  @Test func withSessionCreatesNewClient() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url)
    let updated = client.withSession(sid: "new-sid", token: "new-token", deviceID: "new-did")
    #expect(updated.sessionID == "new-sid")
    #expect(updated.synoToken == "new-token")
    #expect(updated.deviceID == "new-did")
    #expect(updated.baseURL == url)
    // Original unchanged
    #expect(client.sessionID == nil)
  }

  // MARK: imageURL construction

  @Test func imageURLUsesOfficialPosterEndpoint() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url, sessionID: "sid123")
    let imgURL = client.imageURL(id: "42")
    #expect(imgURL.absoluteString.contains("/webapi/VideoStation/poster.cgi"))
    #expect(imgURL.absoluteString.contains("api=SYNO.VideoStation.Poster"))
    #expect(imgURL.absoluteString.contains("method=getimage"))
    #expect(imgURL.absoluteString.contains("version=3"))
    #expect(imgURL.absoluteString.contains("id=42"))
  }

  @Test func imageURLDefaultsToMovieType() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url)
    let imgURL = client.imageURL(id: "1", type: "poster")
    #expect(imgURL.absoluteString.contains("type=movie"))
  }

  @Test func imageURLNormalizesTypeTV() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url)
    let imgURL = client.imageURL(id: "1", type: "tv")
    #expect(imgURL.absoluteString.contains("type=tvshow"))
  }

  @Test func imageURLNormalizesTypeEpisode() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url)
    let imgURL = client.imageURL(id: "1", type: "episode")
    #expect(imgURL.absoluteString.contains("type=tvshow_episode"))
  }

  @Test func imageURLDoesNotIncludeSessionID() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url, sessionID: "secret-sid")
    let imgURL = client.imageURL(id: "1")
    #expect(!imgURL.absoluteString.contains("_sid"))
  }

  @Test func imageURLWithCacheBusting() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url)
    let imgURL = client.imageURL(id: "1", useCacheBusting: true)
    #expect(imgURL.absoluteString.contains("mtime="))
  }

  @Test func imageURLWithoutCacheBusting() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url)
    let imgURL = client.imageURL(id: "1", useCacheBusting: false)
    #expect(!imgURL.absoluteString.contains("mtime="))
  }

  // MARK: backdropURL construction

  @Test func backdropURLUsesCorrectEndpoint() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url, sessionID: "sid123")
    let bgURL = client.backdropURL(mapperId: "55")
    #expect(bgURL.absoluteString.contains("/webapi/entry.cgi"))
    #expect(bgURL.absoluteString.contains("api=SYNO.VideoStation.Backdrop"))
    #expect(bgURL.absoluteString.contains("method=get"))
    #expect(bgURL.absoluteString.contains("mapper_id=55"))
  }

  @Test func backdropURLIncludesSessionID() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url, sessionID: "sid123")
    let bgURL = client.backdropURL(mapperId: "55")
    #expect(bgURL.absoluteString.contains("_sid=sid123"))
  }

  @Test func backdropURLOmitsSessionIDWhenNil() {
    let url = URL(string: "http://192.168.1.100:5000")!
    let client = VideoStationWebAPIClient(baseURL: url)
    let bgURL = client.backdropURL(mapperId: "55")
    #expect(!bgURL.absoluteString.contains("_sid"))
  }
}

// MARK: - AppState Tests

@MainActor
struct AppStateTests {

  @Test func defaultInitialization() {
    let state = AppState()
    // Should have defaults (from UserDefaults or hardcoded)
    #expect(!state.baseURL.isEmpty)
    #expect(state.isLoggingIn == false)
    #expect(state.loginError == nil)
    #expect(state.sessionToken == nil)
    #expect(state.sessionID == nil)
    #expect(state.synoToken == nil)
    #expect(state.deviceID == nil)
    #expect(state.pairingCode == nil)
    #expect(state.isGeneratingPairingCode == false)
    #expect(state.pairingError == nil)
  }

  @Test func logoutClearsSessionState() {
    let state = AppState()
    state.sessionToken = "token"
    state.sessionID = "sid"
    state.synoToken = "stoken"
    state.deviceID = "did"
    state.pairingCode = "code"

    state.logout()

    #expect(state.sessionToken == nil)
    #expect(state.sessionID == nil)
    #expect(state.synoToken == nil)
    #expect(state.deviceID == nil)
    #expect(state.pairingCode == nil)
  }

  @Test func setPasswordUpdatesPassword() {
    let state = AppState()
    state.setPassword("mysecret")
    #expect(state.savedPassword == "mysecret")
  }

  @Test func apiClientUsesNormalizedBaseURL() {
    let state = AppState()
    state.baseURL = "192.168.1.100"
    state.useHTTPS = false
    let client = state.api
    #expect(client.baseURL.port == 5000)
    #expect(client.baseURL.scheme == "http")
  }

  @Test func apiClientUsesHTTPSWhenForced() {
    let state = AppState()
    state.baseURL = "192.168.1.100"
    state.useHTTPS = true
    let client = state.api
    #expect(client.baseURL.scheme == "https")
    #expect(client.baseURL.port == 5001)
  }

  @Test func apiClientPassesToken() {
    let state = AppState()
    state.sessionToken = "my-token"
    let client = state.api
    #expect(client.token == "my-token")
  }

  @Test func apiClientPassesTMDbKey() {
    let state = AppState()
    state.tmdbAPIKey = "tmdb-key-123"
    let client = state.api
    #expect(client.tmdbAPIKey == "tmdb-key-123")
  }

  @Test func apiClientPassesNilTMDbKeyWhenEmpty() {
    let state = AppState()
    state.tmdbAPIKey = ""
    let client = state.api
    #expect(client.tmdbAPIKey == nil)
  }

  @Test func videoStationAPIUsesNormalizedBaseURL() {
    let state = AppState()
    state.baseURL = "192.168.50.100"
    state.useHTTPS = false
    let client = state.videoStationAPI
    #expect(client.baseURL.port == 5000)
  }

  @Test func videoStationAPIPassesSessionCredentials() {
    let state = AppState()
    state.sessionID = "sid-abc"
    state.synoToken = "token-xyz"
    state.deviceID = "did-123"
    let client = state.videoStationAPI
    #expect(client.sessionID == "sid-abc")
    #expect(client.synoToken == "token-xyz")
    #expect(client.deviceID == "did-123")
  }

  @Test func generatePairingCodeRequiresLogin() async {
    let state = AppState()
    state.sessionToken = nil

    await state.generatePairingCode()

    #expect(state.pairingError == "Must be logged in to generate pairing code.")
    #expect(state.pairingCode == nil)
    #expect(state.isGeneratingPairingCode == false)
  }
}
