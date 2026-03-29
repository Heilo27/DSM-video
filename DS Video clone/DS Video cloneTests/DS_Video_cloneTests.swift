import Foundation
import Testing
@testable import DSM_Video

// MARK: - normalizedBaseURL Tests

struct NormalizedBaseURLTests {

  // MARK: Scheme handling

  @Test func addsHTTPSchemeWhenMissing() {
    let url = normalizedBaseURL("myserver.local", forceHTTPS: false)
    #expect(url?.scheme == "http")
    #expect(url?.host == "myserver.local" || url?.host() == "myserver.local")
  }

  @Test func addsHTTPSSchemeWhenMissingAndForced() {
    let url = normalizedBaseURL("myserver.local", forceHTTPS: true)
    #expect(url?.scheme == "https")
  }

  @Test func preservesExistingHTTPScheme() {
    let url = normalizedBaseURL("http://myserver.local", forceHTTPS: false)
    #expect(url?.scheme == "http")
  }

  @Test func forcesHTTPSReplacesHTTP() {
    let url = normalizedBaseURL("http://myserver.local", forceHTTPS: true)
    #expect(url?.scheme == "https")
  }

  @Test func preservesExistingHTTPS() {
    let url = normalizedBaseURL("https://myserver.local", forceHTTPS: false)
    #expect(url?.scheme == "https")
  }

  @Test func preservesExistingHTTPSWithForce() {
    let url = normalizedBaseURL("https://myserver.local", forceHTTPS: true)
    #expect(url?.scheme == "https")
  }

  // MARK: Whitespace trimming

  @Test func trimsWhitespace() {
    let url = normalizedBaseURL("  http://myserver.local  ", forceHTTPS: false)
    #expect(url?.host == "myserver.local" || url?.host() == "myserver.local")
  }

  @Test func trimsNewlines() {
    let url = normalizedBaseURL("\nhttp://myserver.local\n", forceHTTPS: false)
    #expect(url?.host == "myserver.local" || url?.host() == "myserver.local")
  }

  // MARK: Default port injection

  @Test func addsDefaultPort8090WhenNoPortSpecified() {
    let url = normalizedBaseURL("192.168.1.100", forceHTTPS: false)
    #expect(url?.port == 8090)
  }

  @Test func addsDefaultPort8090ForHostname() {
    let url = normalizedBaseURL("mynas.local", forceHTTPS: false)
    #expect(url?.port == 8090)
  }

  @Test func customDefaultPortUsed() {
    let url = normalizedBaseURL("192.168.1.100", forceHTTPS: false, defaultPort: 9000)
    #expect(url?.port == 9000)
  }

  @Test func quickConnectHostSkipsDefaultPort() {
    let url = normalizedBaseURL("mynas.quickconnect.to", forceHTTPS: false)
    #expect(url?.port == nil)
  }

  // MARK: Explicit port preserved

  @Test func preservesExplicitPort() {
    let url = normalizedBaseURL("http://192.168.1.100:8080", forceHTTPS: false)
    #expect(url?.port == 8080)
  }

  @Test func preservesExplicitPortOnHostname() {
    let url = normalizedBaseURL("http://mynas.local:9000", forceHTTPS: false)
    #expect(url?.port == 9000)
  }

  // MARK: Invalid input returns nil

  @Test func returnsNilForEmptyString() {
    let url = normalizedBaseURL("", forceHTTPS: false)
    #expect(url == nil)
  }

  @Test func returnsNilForInvalidURL() {
    let url = normalizedBaseURL("://bad url with spaces", forceHTTPS: false)
    #expect(url == nil)
  }
}

// MARK: - APIClient Tests

struct APIClientTests {

  // MARK: Initialization

  @Test func initializesWithCorrectProperties() {
    let url = URL(string: "http://localhost:8090")!
    let client = APIClient(baseURL: url, token: "test-token")
    #expect(client.baseURL == url)
    #expect(client.token == "test-token")
  }

  @Test func initializesWithNilToken() {
    let url = URL(string: "http://localhost:8090")!
    let client = APIClient(baseURL: url, token: nil)
    #expect(client.token == nil)
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

// MARK: - AppState Tests

@MainActor
struct AppStateTests {

  @Test func defaultInitialization() {
    let state = AppState()
    #expect(!state.baseURL.isEmpty)
    #expect(state.isLoggingIn == false)
    #expect(state.loginError == nil)
    #expect(state.pairingCode == nil)
    #expect(state.isGeneratingPairingCode == false)
    #expect(state.pairingError == nil)
  }

  @Test func logoutClearsSessionState() {
    let state = AppState()
    state.sessionToken = "token"
    state.pairingCode = "code"

    state.logout()

    #expect(state.sessionToken == nil)
    #expect(state.pairingCode == nil)
  }

  @Test func setPasswordUpdatesPassword() {
    let state = AppState()
    state.setPassword("mysecret")
    #expect(state.savedPassword == "mysecret")
  }

  @Test func apiClientUsesHTTPSchemeByDefault() {
    let state = AppState()
    state.baseURL = "192.168.1.100"
    state.useHTTPS = false
    let client = state.api
    #expect(client.baseURL.scheme == "http")
  }

  @Test func apiClientUsesHTTPSWhenForced() {
    let state = AppState()
    state.baseURL = "192.168.1.100"
    state.useHTTPS = true
    let client = state.api
    #expect(client.baseURL.scheme == "https")
  }

  @Test func apiClientPassesToken() {
    let state = AppState()
    state.sessionToken = "my-token"
    let client = state.api
    #expect(client.token == "my-token")
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
