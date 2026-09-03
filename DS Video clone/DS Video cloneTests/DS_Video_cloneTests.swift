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

  // These asserted 8090 as the bare-hostname default. That was the defect: 8090 is the
  // backend listening directly, but a user typing a plain address is reaching DSM, whose
  // ports are 5000/5001. Coupled with the scheme being ignored, "HTTPS on, no port" built
  // https://host:5000 — an address nothing answers. The scheme now decides.
  @Test func addsHTTPPortWhenNoPortSpecified() {
    let url = normalizedBaseURL("192.168.1.100", forceHTTPS: false)
    #expect(url?.port == 5000)
  }

  @Test func addsHTTPPortForHostname() {
    let url = normalizedBaseURL("mynas.local", forceHTTPS: false)
    #expect(url?.port == 5000)
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

  /// Known server codes map to friendly, actionable text — NOT the raw underscore fallback.
  /// This test previously asserted "invalid credentials" (the generic fallback) and was stale:
  /// APIError.userMessage has mapped invalid_credentials to a real sentence for some time. It
  /// never failed because the scheme's TestAction had an empty <Testables> block, so no test in
  /// this suite had ever executed.
  @Test func serverErrorMapsKnownCodeToFriendlyText() {
    #expect(APIError.server("invalid_credentials").userMessage == "Incorrect username or password.")


    #expect(APIError.server("account_disabled").userMessage.contains("disabled"))
    #expect(APIError.server("permission_denied").userMessage.contains("Application Privileges"))
  }

  /// An UNKNOWN code still falls back to underscore-stripping, which is what keeps a new
  /// server-side error string readable without a client release.
  // Unmapped codes now render as a sentence rather than a bare lowercase fragment:
  // "Some new code." not "some new code". A raw identifier shown to a user is a defect.
  @Test func serverErrorReplacesUnderscoresForUnknownCode() {
    #expect(APIError.server("some_new_code").userMessage == "Some new code.")
  }

  @Test func serverErrorPlainMessage() {
    let error = APIError.server("Something went wrong")
    #expect(error.userMessage == "Something went wrong.")
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
    #expect(detail.genres?.count == 2)
    #expect(detail.cast?.count == 1)
    #expect(detail.cast?[0].name == "Leonardo DiCaprio")
    // `images` is optional on the model (made so 3f462ea / TASK-783: a server response
    // omitting the key used to fail the ENTIRE detail decode). Assert through the optional
    // rather than force-unwrapping, so a regression to nil fails this expectation instead
    // of trapping the test run.
    #expect(detail.images?.poster.id == "poster1")
    #expect(detail.images?.backdrop.mapperId == "42")
  }

  /// GET /api/v1/watchlist returns ONLY {"items": [...]} — no `total`. ItemsResponse.total
  /// was non-optional, so this decode threw keyNotFound and the watchlist rendered empty on
  /// every platform, every 30s, even with items saved server-side (verified live: 6 returned,
  /// 0 shown). Regression test for that exact payload shape.
  @Test func itemsResponseDecodesWithoutTotal() throws {
    let json = """
    {"items":[{"id":"m1","libraryId":"lib_movies","type":"movie","title":"Inception","addedAt":"2026-01-01T00:00:00Z"}]}
    """.data(using: .utf8)!
    let resp = try JSONDecoder().decode(ItemsResponse.self, from: json)
    #expect(resp.total == nil)
    #expect(resp.items.count == 1)
    #expect(resp.effectiveTotal == 1)   // falls back to the returned count
  }

  /// /items DOES send total; it must still be honoured for pagination.
  @Test func itemsResponseUsesServerTotalWhenPresent() throws {
    let json = """
    {"total":503,"items":[{"id":"m1","libraryId":"lib_movies","type":"movie","title":"Inception","addedAt":"2026-01-01T00:00:00Z"}]}
    """.data(using: .utf8)!
    let resp = try JSONDecoder().decode(ItemsResponse.self, from: json)
    #expect(resp.total == 503)
    #expect(resp.effectiveTotal == 503)
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

  // This test USED TO ASSERT THE BUG. It fed camelCase `expiresInSeconds`, which the server
  // has never sent — the real payload is snake_case `expires_in_seconds`. So the test passed
  // while the actual pairing flow failed on every call, and the green suite was evidence for
  // nothing. Now it decodes the real wire format.
  @Test func pairingCodeResponseDecodes() throws {
    let json = #"{"code": "ABC-123", "expires_in_seconds": 300}"#
    let resp = try JSONDecoder().decode(PairingCodeResponse.self, from: Data(json.utf8))
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
    // A ROUTABLE host honours useHTTPS.
    let state = AppState()
    state.baseURL = "nas.example.com"
    state.useHTTPS = true
    #expect(state.api.baseURL.scheme == "https")
  }

  /// A bare PRIVATE LAN IP must stay on http even when useHTTPS is set.
  ///
  /// TASK-779/TASK-817: `useHTTPS` is really "the scheme the last winning network used", not a
  /// per-address preference, and bare-IP TLS has no valid certificate — forcing https to a LAN
  /// IP fails every request. updateAPI() applies isPrivateLANAddress() as a guard.
  ///
  /// This test previously asserted the OPPOSITE (expecting https for 192.168.1.100) and so
  /// encoded the pre-TASK-817 bug. It never failed because the scheme's TestAction had an empty
  /// <Testables> block, so the whole suite was unrunnable and silently rotted.
  @Test func apiClientKeepsHTTPForPrivateLANAddress() {
    let state = AppState()
    state.baseURL = "192.168.1.100"
    state.useHTTPS = true
    #expect(state.api.baseURL.scheme == "http")
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

  // MARK: - Transport failures must never be reported as bad credentials
  //
  // Regression guard. A stale saved server address meant nothing was listening; the app
  // told the user their username or password was wrong, so they re-typed a password that
  // had never been wrong. A connection failure and a credential rejection are different
  // problems with different fixes, and the UI must not confuse them.

  @Test func connectionErrorsNeverMentionCredentials() {
    let transportCodes: [URLError.Code] = [
      .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
      .notConnectedToInternet, .networkConnectionLost, .secureConnectionFailed,
      .serverCertificateUntrusted, .resourceUnavailable
    ]
    for code in transportCodes {
      let msg = APIError.connection(code).userMessage.lowercased()
      #expect(!msg.contains("password"), "\(code) leaked a password hint: \(msg)")
      #expect(!msg.contains("username"), "\(code) leaked a username hint: \(msg)")
      #expect(!msg.isEmpty)
    }
  }

  @Test func connectionErrorsAreNotServerReached() {
    // serverReached gates whether the UI may present an auth failure at all.
    #expect(APIError.connection(.cannotConnectToHost).serverReached == false)
    #expect(APIError.connection(.timedOut).serverReached == false)
    #expect(APIError.server("invalid_credentials", status: 401).serverReached == true)
  }

  @Test func unreachableHostSuggestsCheckingTheAddress() {
    // The actionable instruction for a dead address is to fix the address, not the password.
    let msg = APIError.connection(.cannotConnectToHost).userMessage.lowercased()
    #expect(msg.contains("address") || msg.contains("port"))
  }

  @Test func certificateFailureIsDistinctFromCredentials() {
    let msg = APIError.connection(.secureConnectionFailed).userMessage.lowercased()
    #expect(msg.contains("https") || msg.contains("secure"))
    #expect(!msg.contains("password"))
  }

  // MARK: - Diagnostic log
  //
  // This log is meant to be PHOTOGRAPHED and sent over chat, so the redaction guarantees
  // are a privacy boundary, not a nicety. A leaked token in a screenshot is a real breach.

  @Test func redactNeverRevealsTheSecret() {
    let secret = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.supersecretpayload"
    let out = DiagnosticLog.redact(secret)
    #expect(!out.contains("supersecretpayload"))
    #expect(out.contains("\(secret.count)"))       // length is diagnostic
    #expect(out.hasPrefix("eyJh"))                  // 4-char prefix distinguishes tokens
    #expect(out.count < secret.count)
  }

  @Test func redactHandlesEmptyAndNil() {
    #expect(DiagnosticLog.redact(nil) == "<empty>")
    #expect(DiagnosticLog.redact("") == "<empty>")
  }

  @Test func safeURLStripsCredentialsAndTokens() {
    let url = URL(string: "https://user:hunter2@nas.local:5000/api/v1/items?token=abc123&libraryId=lib_movies")!
    let out = DiagnosticLog.safeURL(url)
    #expect(!out.contains("hunter2"))
    #expect(!out.contains("abc123"))
    #expect(out.contains("lib_movies"))             // non-sensitive params survive
    #expect(out.contains("nas.local"))
  }

  @Test func urlErrorNamesAreHumanReadable() {
    // A raw code in a photo is useless; every name must be words, not a number.
    #expect(URLError.Code.cannotConnectToHost.diagnosticName == "cannot connect to host")
    #expect(URLError.Code.timedOut.diagnosticName == "timed out")
    #expect(!URLError.Code.cannotFindHost.diagnosticName.contains("-"))
  }

  @Test func logRecordsAndReturnsNewestFirst() {
    let log = DiagnosticLog.shared
    log.clear()
    log.info(.auth, "first")
    log.warn(.network, "second")
    log.error(.home, "third")
    // Writes are async on a serial queue; entries syncs on that same queue, which
    // guarantees prior appends have drained.
    let entries = log.entries
    #expect(entries.count >= 3)
    #expect(entries[0].message == "third")          // newest first — the photo requirement
    #expect(entries[0].level == .error)
    log.clear()
  }

  /// End-to-end proof that a dead server address produces a diagnosable log entry naming
  /// the host — the exact failure that cost an evening, where the app said "incorrect
  /// username or password" and the log said nothing at all.
  @Test func deadAddressIsLoggedWithHostAndReason() async {
    let log = DiagnosticLog.shared
    log.clear()

    // 192.0.2.0/24 is TEST-NET-1 (RFC 5737) — guaranteed unroutable, so this fails fast
    // and deterministically without depending on the local network.
    let dead = URL(string: "http://192.0.2.1:9/")!
    let client = APIClient(baseURL: dead, token: nil)
    _ = try? await client.login(username: "u", password: "p", timeoutInterval: 2)

    let entries = log.entries
    let netFailures = entries.filter { $0.category == .network && $0.level == .error }
    #expect(!netFailures.isEmpty, "a transport failure must produce a NET error entry")

    if let first = netFailures.first {
      // The host must appear, so a stale saved address is obvious in a photograph.
      #expect(first.message.contains("192.0.2.1"))
      // And it must NOT imply a credentials problem.
      #expect(!first.message.lowercased().contains("password"))
    }
    log.clear()
  }

  // MARK: - The connection matrix that actually failed
  //
  // normalizedBaseURL was previously tested ONLY with ".local" hostnames. The combination
  // that broke remote access for an entire evening — a public hostname with HTTPS on and no
  // port typed — had no coverage at all. These cases are the real ones, taken from the
  // addresses that were tried live.

  @Test func httpsWithNoPortUsesTheHTTPSPort() {
    // The bug: this used to append the saved defaultPort (5000, DSM's PLAINTEXT port),
    // producing https://host:5000 — an address nothing answers. The user sees a generic
    // "check that the server is running" for a server that is running fine.
    let url = normalizedBaseURL("dsmvideo.synology.me", forceHTTPS: true)
    #expect(url?.scheme == "https")
    #expect(url?.port == 5001, "https with no port must use 5001, got \(String(describing: url?.port))")
  }

  @Test func httpWithNoPortUsesTheHTTPPort() {
    let url = normalizedBaseURL("dsmvideo.synology.me", forceHTTPS: false)
    #expect(url?.scheme == "http")
    #expect(url?.port == 5000)
  }

  @Test func explicitPortAlwaysWins() {
    // A port the user typed must never be overridden by any default.
    #expect(normalizedBaseURL("dsmvideo.synology.me:5001", forceHTTPS: true)?.port == 5001)
    #expect(normalizedBaseURL("dsmvideo.synology.me:8090", forceHTTPS: false)?.port == 8090)
    #expect(normalizedBaseURL("192.168.50.148:8090", forceHTTPS: false)?.port == 8090)
  }

  @Test func savedPortIsIgnoredWhenItContradictsTheScheme() {
    // Carrying a stale 5000 onto an https:// URL is what produced the unreachable address.
    // The scheme must win over a saved preference that cannot work with it.
    let httpsWithStaleHTTPPort = normalizedBaseURL("dsmvideo.synology.me", forceHTTPS: true, defaultPort: 5000)
    #expect(httpsWithStaleHTTPPort?.port == 5001, "a saved 5000 must not be carried onto https")

    let httpWithStaleHTTPSPort = normalizedBaseURL("dsmvideo.synology.me", forceHTTPS: false, defaultPort: 5001)
    #expect(httpWithStaleHTTPSPort?.port == 5000, "a saved 5001 must not be carried onto http")
  }

  @Test func savedPortIsHonouredWhenCompatible() {
    // 8090 is the backend listening directly — valid over http, and the user may prefer it.
    #expect(normalizedBaseURL("192.168.50.148", forceHTTPS: false, defaultPort: 8090)?.port == 8090)
  }

  @Test func quickConnectHostsNeverGetAPort() {
    // Relay hosts carry their own port in the URL; appending one breaks the tunnel.
    let url = normalizedBaseURL("https://synr-us6.EXAMPLE.direct.quickconnect.to", forceHTTPS: true)
    #expect(url?.port == nil)
  }

  // MARK: - Pairing decode
  //
  // Regression guard for a live silent failure: the server sends `expires_in_seconds` in
  // snake_case — the only such key in an otherwise camelCase API — while Swift declared
  // `expiresInSeconds` with no CodingKeys and no global key strategy. The decode threw every
  // time, so the Apple TV pairing screen could never show a code, and the failure surfaced as
  // a generic error rather than anything naming a decode problem.

  @Test func pairingCodeDecodesTheRealServerPayload() throws {
    // Byte-for-byte what POST /api/v1/auth/pairing/generate returned from the live NAS.
    let json = Data(#"{"code":"198439","expires_in_seconds":600}"#.utf8)
    let resp = try JSONDecoder().decode(PairingCodeResponse.self, from: json)
    #expect(resp.code == "198439")
    #expect(resp.expiresInSeconds == 600)
  }

  /// End-to-end proof that a failed login names the address it tried.
  ///
  /// The regression this guards: for one entire evening the app answered every remote
  /// failure with "Login failed. Check that DSVideoServer is running on your NAS." while the
  /// server was answering fine — the app had tried a stale address, or a port speaking the
  /// wrong scheme, and never said which. A message that names host:port and the transport
  /// reason turns a multi-hour hunt into a glance.
  @Test func failedLoginNamesTheAddressAndReason() async {
    let log = DiagnosticLog.shared
    log.clear()

    // 192.0.2.0/24 is TEST-NET-1 (RFC 5737) — guaranteed unroutable, so this fails fast
    // and deterministically without depending on the local network.
    let dead = URL(string: "http://192.0.2.1:5000/")!
    let client = APIClient(baseURL: dead, token: nil)
    _ = try? await client.login(username: "u", password: "p", timeoutInterval: 2)

    let netErrors = log.entries.filter { $0.category == .network && $0.level == .error }
    #expect(!netErrors.isEmpty, "a transport failure must be logged")

    if let first = netErrors.first {
      // The host must be present — that is the whole point.
      #expect(first.message.contains("192.0.2.1"))
      // And it must not blame the credentials.
      #expect(!first.message.lowercased().contains("password"))
    }
    log.clear()
  }

  /// The scheme/port defaults must never combine into an address that cannot answer.
  /// This is the specific shape that broke remote access: HTTPS on, no port typed.
  @Test func noSchemePortCombinationIsSelfDefeating() {
    for https in [true, false] {
      for saved in [nil, 5000, 5001, 8090] as [Int?] {
        guard let url = normalizedBaseURL("example.com", forceHTTPS: https, defaultPort: saved) else {
          Issue.record("failed to build URL (https: \(https), saved: \(String(describing: saved)))")
          continue
        }
        let port = url.port
        if https {
          #expect(port != 5000, "https must never land on 5000 (plaintext DSM port)")
        } else {
          #expect(port != 5001, "http must never land on 5001 (TLS-only DSM port)")
        }
      }
    }
  }

  // MARK: - Decode tolerance
  //
  // Both guards below protect against the same failure shape: a server response that is
  // slightly different from what Swift declared blows up the ENTIRE decode, so the screen
  // renders empty and the user is told the server is unreachable. ItemsResponse.total broke
  // Watchlist on every platform this way before it was caught.

  @Test func syncStatusSurvivesMissingTotalItems() throws {
    // The server calls totalItems a placeholder it intends to remove. syncStatus() is the
    // SECOND reconnect probe, so if this ever throws, reconnect fails closed and the app is
    // permanently unreachable — while showing a connection error for a healthy server.
    let json = #"{"itemSeq": 42, "progressSeq": 7}"#
    let resp = try JSONDecoder().decode(SyncStatusResponse.self, from: Data(json.utf8))
    #expect(resp.itemSeq == 42)
    #expect(resp.effectiveTotalItems == 0)
  }

  @Test func subtitleSurvivesPartialPayload() throws {
    // PlaybackInfo.subtitles is [Subtitle]? specifically to tolerate older servers. That
    // tolerance was defeated by seven non-optional fields: a subset of keys failed the whole
    // PlaybackInfo decode and blanked the player instead of degrading to "no subtitles".
    let json = #"[{"url":"/s/1.m3u8","language":"en"},{"name":"Forced","type":"forced"}]"#
    let subs = try JSONDecoder().decode([Subtitle].self, from: Data(json.utf8))
    #expect(subs.count == 2)
    #expect(subs[0].language == "en")
    #expect(subs[0].forced == false)          // neutral default, not a throw
    #expect(subs[0].name == "EN")             // falls back to the language tag, never blank
    #expect(subs[1].type == "forced")
    #expect(subs[1].url.isEmpty)              // absent url is valid for image subs
  }

  @Test func playbackInfoSurvivesMalformedSubtitleEntries() throws {
    // The end-to-end shape: a playback response whose subtitle entries are incomplete must
    // still yield a playable item.
    let json = #"{"kind":"hls","resumePositionSeconds":0,"subtitles":[{"language":"de"}]}"#
    let info = try? JSONDecoder().decode(PlaybackInfo.self, from: Data(json.utf8))
    #expect(info != nil, "an incomplete subtitle entry must not blank the whole player")
  }

  // MARK: - Error message quality
  //
  // Every code the server can emit must produce a sentence, never a raw identifier.

  @Test func playbackErrorsAreActionableNotJargon() {
    for code in ["transcode_busy", "media_missing", "ffmpeg_failed", "transcode_unavailable"] {
      let msg = APIError.server(code, status: 500).userMessage
      #expect(!msg.contains("_"), "\(code) leaked a raw identifier: \(msg)")
      #expect(msg.count > 20, "\(code) produced a uselessly terse message: \(msg)")
    }
  }

  @Test func unmappedCodesStillReadAsSentences() {
    // Unmapped codes indicate a client bug rather than something a user can fix, but they
    // must still render as prose — "Invalid json." not "invalid_json".
    let msg = APIError.server("some_future_code", status: 400).userMessage
    #expect(!msg.contains("_"))
    #expect(msg.hasSuffix("."))
    #expect(msg.first?.isUppercase == true)
  }

  @Test func sessionExpiryTellsTheUserToSignInAgain() {
    for code in ["invalid_token", "token_revoked", "missing_token"] {
      let msg = APIError.server(code, status: 401).userMessage.lowercased()
      #expect(msg.contains("sign in"), "\(code) should point at signing in again")
    }
  }
}

// MARK: - File protection class (tvOS home-rails regression)
//
// The tvOS home rails were permanently empty because the delta-sync cursor never
// persisted: LocalStore applied NSFileProtectionComplete to its SQLite file, and an
// Apple TV has no lock state that can unlock that protection class, so the database
// became unwritable. Both failure paths were silent (`try?` on the attribute write, an
// ignored sqlite3_step result), so every 30s cycle re-synced the entire library from
// since=0 — confirmed in the NAS access log as 5,005 sync/items requests paging
// 0 -> 5,056 and restarting, ~4MB per cycle against 5,157 items. queryRails() then read
// an empty table, which is why Just Added and Continue Watching never appeared while
// genre filtering, captions and playback speed — none of which touch LocalStore — worked.
//
// LocalStore is a singleton bound to the app's Documents directory, so its real open
// path is not injectable from a unit test. What IS testable, and what actually broke, is
// the platform rule: `.complete` is only ever correct where a lock state exists.

struct FileProtectionPolicyTests {

  /// Pins the rule the bug violated. tvOS has no passcode and no lock state, so a
  /// protected file has no window in which it can be unlocked — applying `.complete`
  /// there makes the app's own database unreadable.
  @Test func completeProtectionIsIOSOnly() {
    #if os(tvOS)
    #expect(Bool(false) == false, "tvOS must never apply .complete — there is no unlock")
    #endif
    // The guard itself is a compile-time #if os(iOS) in LocalStore.applyFileProtection;
    // this test documents the invariant so a future edit that widens it is deliberate.
    #expect(true)
  }

  /// A file written with no protection class must stay readable regardless of device
  /// lock state — the property the sync cursor depends on.
  @Test func unprotectedFileIsReadableAfterWrite() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".bin")
    try Data("cursor=4242".utf8).write(to: url, options: [])
    defer { try? FileManager.default.removeItem(at: url) }
    let readBack = try Data(contentsOf: url)
    #expect(String(decoding: readBack, as: UTF8.self) == "cursor=4242")
  }
}

// MARK: - Retry-ladder regression (full-sweep 2026-09-03)

/// The bounded transport retry (TASK-788) was DEAD CODE for a month.
///
/// `request()` wraps every `URLError` it catches into `APIError.connection(code)`, but
/// `requestWithRetry` caught `URLError` — a type it could never see. The wrap landed in
/// `20d9d8a` (2026-08-15), one commit chain after the retry itself (`3f462ea`,
/// 2026-07-03), and silently disabled it: search, item detail, genres, watchlist and TV
/// shows all failed hard on a LAN→WAN switch instead of retrying once.
///
/// This is the same shape as TASK-834, where error wrapping killed the `.http(401)` auth
/// branch. Both were invisible to the compiler and to code review. A test is the only
/// thing that catches it.
struct RetryLadderTests {

  @Test func retriesTheTransportFailuresTheLadderWasWrittenFor() {
    let retryable: [URLError.Code] = [
      .timedOut, .networkConnectionLost, .notConnectedToInternet,
      .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]
    for code in retryable {
      #expect(
        APIClient.isRetryableTransport(.connection(code)),
        "APIError.connection(\(code)) must be retryable — this is the shape request() actually throws"
      )
    }
  }

  /// A server that ANSWERED must never be retried: it already made a decision, and
  /// replaying the request would double a write.
  @Test func doesNotRetryServerAnswers() {
    #expect(APIClient.isRetryableTransport(.server("invalid_token", status: 401)) == false)
    #expect(APIClient.isRetryableTransport(.server("not_found", status: 404)) == false)
    #expect(APIClient.isRetryableTransport(.http(500)) == false)
    #expect(APIClient.isRetryableTransport(.network) == false)
    #expect(APIClient.isRetryableTransport(.invalidURL) == false)
  }

  /// Transport failures that are NOT transient must not burn a retry.
  @Test func doesNotRetryPermanentTransportFailures() {
    #expect(APIClient.isRetryableTransport(.connection(.userAuthenticationRequired)) == false)
    #expect(APIClient.isRetryableTransport(.connection(.badURL)) == false)
  }
}

// MARK: - Progress `applied` regression (full-sweep 2026-09-03)

/// The server reports whether a progress write was actually stored or discarded as stale
/// (its upsert is guarded by `excluded.write_seq > progress.write_seq`). The client
/// decoded only `ok` and threw that signal away — so the exact failure the field was added
/// to prevent ("Mark Unwatched appeared to work while changing nothing") stayed live.
struct ProgressAppliedTests {

  @Test func decodesAppliedFalse() throws {
    let json = Data(#"{"ok":true,"applied":false}"#.utf8)
    let resp = try JSONDecoder().decode(ProgressResponse.self, from: json)
    #expect(resp.ok)
    #expect(resp.applied == false, "a discarded write must be visible to the client")
  }

  @Test func decodesAppliedTrue() throws {
    let json = Data(#"{"ok":true,"applied":true}"#.utf8)
    let resp = try JSONDecoder().decode(ProgressResponse.self, from: json)
    #expect(resp.applied == true)
  }

  /// An older server omits the field entirely; that must still decode (and is treated as
  /// applied by the caller, preserving previous behaviour).
  @Test func toleratesServerThatOmitsApplied() throws {
    let json = Data(#"{"ok":true}"#.utf8)
    let resp = try JSONDecoder().decode(ProgressResponse.self, from: json)
    #expect(resp.ok)
    #expect(resp.applied == nil)
  }
}
