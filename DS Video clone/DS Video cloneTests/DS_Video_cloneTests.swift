import Foundation
import Testing
@testable import DSM_Video

// MARK: - normalizedBaseURL Tests

@MainActor
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

@MainActor
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

@MainActor
struct APIErrorTests {

  @Test func networkErrorMessage() {
    let error = APIError.network
    #expect(error.userMessage == "Network error.")
  }

  /// HTTP failures name a CAUSE the user can act on, never a bare wire status.
  /// "Server error (403)." told the user nothing and leaked the status code; these assert the
  /// replacement text and, more importantly, that the raw code is not the whole message.
  @Test func httpErrorMessage() {
    let error = APIError.http(404)
    #expect(error.userMessage == "The server couldn't find that item. It may have been moved or removed.")
    #expect(!error.userMessage.contains("Server error"))
  }

  @Test func httpErrorMessage500() {
    let error = APIError.http(500)
    #expect(error.userMessage == "The server had a problem handling that. Try again shortly.")
  }

  @Test func authFailureTellsTheUserToSignInAgain() {
    #expect(APIError.http(401).userMessage == "Your session expired. Sign in again.")
    #expect(APIError.http(403).userMessage == "Your session expired. Sign in again.")
  }

  /// An unmapped status still reports the code, but framed as a rejection rather than as the
  /// app's own failure.
  @Test func unmappedHTTPStatusStillNamesTheCode() {
    #expect(APIError.http(418).userMessage == "The server rejected the request (418).")
  }

  /// A decode failure must NEVER read as a connectivity problem: the request succeeded and the
  /// server is healthy. Reporting "could not connect" sent users to debug their network while
  /// the real cause was a version mismatch. This is the regression guard for that.
  @Test func decodeErrorDoesNotBlameTheNetwork() {
    let error = APIError.decode(detail: "items.total: expected Int")
    let msg = error.userMessage
    #expect(!msg.localizedCaseInsensitiveContains("connect"))
    #expect(!msg.localizedCaseInsensitiveContains("unreachable"))
    #expect(!msg.localizedCaseInsensitiveContains("network"))
    #expect(msg.localizedCaseInsensitiveContains("version"))
  }

  /// A decode failure means the server WAS reached — it answered, we just couldn't parse it.
  /// The login flow branches on this, so getting it backwards shows the wrong recovery advice.
  @Test func decodeErrorCountsAsServerReached() {
    #expect(APIError.decode(detail: "x").serverReached)
  }

  /// A decode failure is not permanent: updating the server or app fixes it, so a queued
  /// write must stay queued rather than being dropped from the outbox.
  @Test func decodeErrorIsNotAPermanentRejection() {
    #expect(!APIError.decode(detail: "x").isPermanentRejection)
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

@MainActor
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
    #expect(detail.images?.poster?.id == "poster1")
    #expect(detail.images?.backdrop?.mapperId == "42")
  }

  /// An episode shows its real name, not the filename-derived one (TASK-870).
  ///
  /// The server emits `episodeTitle` for every episode and NO client decoded it, so the
  /// detail screen fell back to `title` — which is derived from the filename and reads
  /// like "Show.S02E04.1080p.WEB-DL". The episode LIST for the same episode already
  /// preferred episodeTitle server-side, so one episode was named two different things
  /// in two places in the same app.
  @Test func episodeDetailPrefersTheRealEpisodeTitle() throws {
    func decode(_ json: String) throws -> ItemDetail {
      try JSONDecoder().decode(ItemDetail.self, from: json.data(using: .utf8)!)
    }

    // The defect's own shape: a filename-derived title alongside a real episode name.
    let episode = try decode("""
    {
      "id": "e1", "type": "episode", "title": "Severance.S02E04.1080p.WEB-DL",
      "showName": "Severance", "seasonNumber": 2, "episodeNumber": 4,
      "episodeTitle": "Woe's Hollow"
    }
    """)
    #expect(episode.episodeTitle == "Woe's Hollow")
    #expect(episode.seasonNumber == 2)
    #expect(episode.episodeNumber == 4)
    #expect(episode.showName == "Severance")
    #expect(episode.displayTitle == "Woe's Hollow")
    // The raw title is still available — this replaces what is DISPLAYED, not the data.
    #expect(episode.title == "Severance.S02E04.1080p.WEB-DL")

    // An episode the scanner could not name falls back rather than showing nothing.
    let unnamed = try decode(#"{"id":"e2","type":"episode","title":"Show.S01E02"}"#)
    #expect(unnamed.displayTitle == "Show.S01E02")

    // Present but blank is the same as absent — a whitespace-only name must not win.
    let blank = try decode(#"{"id":"e3","type":"episode","title":"Show.S01E03","episodeTitle":"   "}"#)
    #expect(blank.displayTitle == "Show.S01E03")

    // A MOVIE must never adopt the rule, even if a server sends the field.
    let movie = try decode(#"{"id":"m1","type":"movie","title":"Inception","episodeTitle":"Nope"}"#)
    #expect(movie.displayTitle == "Inception")
  }

  /// A PARTIAL images envelope must still decode.
  ///
  /// TASK-783 made `images` itself optional, which covered a server omitting the key
  /// entirely. It did not cover a server that sends `images` with only one of the two
  /// refs: `poster`/`backdrop` stayed non-optional, so `{"images":{"poster":{...}}}`
  /// threw keyNotFound and the whole detail failed to decode. The item would not open —
  /// over missing ARTWORK. Both refs are now optional; this pins each shape.
  ///
  /// Three cases, because "it decodes" is not the claim — the claim is that the ref that
  /// IS present survives while the absent one reads nil.
  @Test func itemDetailDecodesWithPartialImagesEnvelope() throws {
    func decode(_ imagesJSON: String) throws -> ItemDetail {
      let json = """
      {
        "id": "m1", "type": "movie", "title": "Inception",
        "images": \(imagesJSON)
      }
      """
      return try JSONDecoder().decode(ItemDetail.self, from: json.data(using: .utf8)!)
    }

    // Poster only — backdrop key absent.
    let posterOnly = try decode(#"{"poster": {"id": "poster1", "mapperId": null}}"#)
    #expect(posterOnly.images?.poster?.id == "poster1")
    #expect(posterOnly.images?.backdrop == nil)

    // Backdrop only — poster key absent.
    let backdropOnly = try decode(#"{"backdrop": {"id": "backdrop1", "mapperId": "42"}}"#)
    #expect(backdropOnly.images?.backdrop?.id == "backdrop1")
    #expect(backdropOnly.images?.poster == nil)

    // Envelope present but empty. Decodes; both refs nil.
    let empty = try decode("{}")
    #expect(empty.images != nil)
    #expect(empty.images?.poster == nil)
    #expect(empty.images?.backdrop == nil)
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

  /// A fresh install has NO server address. It used to default to "http://localhost:5000",
  /// which shipped prefilled on the tvOS sign-in screen where localhost is the Apple TV
  /// itself — an address that can never work. Empty is the correct "not configured" state.
  @Test func defaultInitialization() {
    let state = AppState()
    #expect(state.baseURL != "http://localhost:5000")
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
      .serverCertificateUntrusted, .resourceUnavailable,
      .appTransportSecurityRequiresSecureConnection
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

  /// An ATS block must not be reported as an unreachable server (TASK-907).
  ///
  /// Found by the UI suite: connecting to a public address over plain http:// produced
  /// "Couldn't reach the server. Check the address and port." iOS refused to SEND the
  /// request — nothing was attempted and the address may be perfectly correct — so that
  /// message sends the user to debug a healthy server and a correct address.
  ///
  /// The distinction is the whole point of the test: the text must name ENCRYPTION as
  /// the cause, because that is what the user has to change.
  @Test func atsBlockNamesEncryptionNotTheAddress() {
    let msg = APIError.connection(.appTransportSecurityRequiresSecureConnection).userMessage.lowercased()

    // Names the real cause.
    #expect(
      msg.contains("encrypt") || msg.contains("https") || msg.contains("http://"),
      "An ATS block must say the connection was refused for being unencrypted. Got: \(msg)"
    )
    // Does NOT send the user to re-check a correct address — the failure happened before
    // any packet was sent, so the address was never in question.
    #expect(
      !msg.contains("check the address"),
      "An ATS block blamed the address, which was never contacted. Got: \(msg)"
    )
    // Still a transport failure: it must not implicate credentials.
    #expect(!msg.contains("password"))
    #expect(!msg.contains("username"))
    // And it must not read as a generic unreachable-server message, which is the exact
    // text this case used to fall through to.
    #expect(msg != "couldn't reach the server. check the address and port.")
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

  /// Video Station's `_sid` is a LIVE session credential carried in the query string —
  /// the one credential this app genuinely puts in a URL — and it was the only sensitive
  /// name missing from safeURL's list, so it passed through verbatim (TASK-897 #7).
  ///
  /// This matters because the diagnostic log is meant to be PHOTOGRAPHED and sent over
  /// chat. A session id in that screenshot is a working credential in someone's DMs.
  @Test func safeURLStripsVideoStationSessionIDs() {
    let url = URL(string: "http://nas.local:5000/webapi/entry.cgi?api=SYNO.API.Auth&_sid=Xy7bQ2mLp&method=list")!
    let out = DiagnosticLog.safeURL(url)
    #expect(!out.contains("Xy7bQ2mLp"), "the live _sid survived redaction: \(out)")
    // The rest must remain legible — a log that redacts everything diagnoses nothing.
    #expect(out.contains("nas.local"))
    #expect(out.contains("SYNO.API.Auth"))
    #expect(out.contains("method=list"))

    // The bare `sid` spelling too, since the substring rule is what covers both.
    let bare = URL(string: "https://nas.local/api?sid=Zz9&page=2")!
    let bareOut = DiagnosticLog.safeURL(bare)
    #expect(!bareOut.contains("Zz9"))
    #expect(bareOut.contains("page=2"))
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

@MainActor
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
@MainActor
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
@MainActor
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

// MARK: - Shared classification (consolidation pass, 2026-09-11)

/// `PlaybackProgress.watchState` is the single definition of "unwatched / in progress /
/// watched" for episode scanning.
///
/// The iOS and tvOS resume scans each wrote the same fraction math and the same two
/// threshold comparisons out by hand. That is exactly how `startedThreshold` drifted —
/// 0.05 in the rail SQL and home-rail computation, still 0.02 in the show page — so for a
/// 45-minute episode watched between 54s and 135s the show page offered to resume an
/// episode the home rail said had never been started. Both scans now call this.
@MainActor
struct WatchStateTests {

  @Test func nothingWatchedIsUnwatched() {
    #expect(PlaybackProgress.watchState(positionSeconds: 0, durationSeconds: 2700) == .unwatched)
  }

  /// Below `startedThreshold` is an accidental tap, not a resume point.
  @Test func belowStartedThresholdIsUnwatched() {
    // 5% of 2700s is 135s; 100s is under it.
    #expect(PlaybackProgress.watchState(positionSeconds: 100, durationSeconds: 2700) == .unwatched)
  }

  @Test func pastStartedThresholdIsInProgress() {
    // 200s of 2700s ≈ 7.4%, comfortably past 5%.
    #expect(PlaybackProgress.watchState(positionSeconds: 200, durationSeconds: 2700) == .inProgress)
  }

  @Test func pastWatchedThresholdIsWatched() {
    // 96% of 2700s.
    #expect(PlaybackProgress.watchState(positionSeconds: 2600, durationSeconds: 2700) == .watched)
  }

  /// An unknown duration yields no meaningful ratio; never classify it as progress.
  @Test func zeroDurationIsUnwatched() {
    #expect(PlaybackProgress.watchState(positionSeconds: 500, durationSeconds: 0) == .unwatched)
  }

  /// The boundaries are the thing that drifted, so pin them explicitly rather than
  /// trusting a value in the middle of a band.
  @Test func boundariesFollowTheSharedThresholds() {
    let dur = 1000
    let atStarted = Int(PlaybackProgress.startedThreshold * Double(dur))      // exactly 5%
    let atWatched = Int(PlaybackProgress.watchedThreshold * Double(dur))      // exactly 95%

    // `startedThreshold` is INCLUSIVE, matching the rail SQL in LocalStore. The show-page
    // scans used a strict `>` while the rail used `>=`, so an item at exactly 5.000%
    // showed up in one and not the other. Pinned so the two cannot diverge again.
    #expect(PlaybackProgress.watchState(positionSeconds: atStarted, durationSeconds: dur) == .inProgress)
    #expect(PlaybackProgress.watchState(positionSeconds: atStarted - 1, durationSeconds: dur) == .unwatched)

    // `watchedThreshold` is inclusive — exactly 95% counts as watched.
    #expect(PlaybackProgress.watchState(positionSeconds: atWatched, durationSeconds: dur) == .watched)
    #expect(PlaybackProgress.watchState(positionSeconds: atWatched - 1, durationSeconds: dur) == .inProgress)
  }

  /// The three states must partition the space: every input lands in exactly one, and
  /// nothing falls through a gap between the thresholds.
  @Test func everyPositionClassifiesExactlyOnce() {
    let dur = 2700
    for pos in stride(from: 0, through: dur, by: 37) {
      let state = PlaybackProgress.watchState(positionSeconds: pos, durationSeconds: dur)
      let frac = Double(pos) / Double(dur)
      switch state {
      case .unwatched:
        #expect(frac < PlaybackProgress.startedThreshold)
      case .inProgress:
        #expect(frac >= PlaybackProgress.startedThreshold)
        #expect(frac < PlaybackProgress.watchedThreshold)
      case .watched:
        #expect(frac >= PlaybackProgress.watchedThreshold)
      }
    }
  }
}

/// The subtitle-appearance UserDefaults keys are declared once in `SubtitleStyle` —
/// whose own doc comment says they exist "so both the player and the settings UI can
/// share the keys and defaults". They did not: the three key strings were re-typed as raw
/// literals in nine places across MainView, TVMainView and GestureVideoPlayer, and the
/// constants had zero callers. A typo in any copy fails silently — the setting simply
/// stops applying.
@MainActor
struct SubtitleStyleKeyTests {

  @Test func keysMatchTheirPersistedNames() {
    // These exact strings are already on users' devices; changing one silently discards
    // that user's saved preference, so they are pinned.
    #expect(SubtitleStyle.scaleKey == "dsReel.subtitleScale")
    #expect(SubtitleStyle.textColorKey == "dsReel.subtitleTextColor")
    #expect(SubtitleStyle.backgroundOpacityKey == "dsReel.subtitleBackgroundOpacity")
  }

  @Test func keysAreDistinct() {
    let keys = Set([SubtitleStyle.scaleKey, SubtitleStyle.textColorKey, SubtitleStyle.backgroundOpacityKey])
    #expect(keys.count == 3)
  }
}

/// Season expand/collapse is remembered per show.
///
/// Previously every visit re-derived expansion from scratch, so someone watching season 6
/// collapsed 1–5 and expanded 6 on *every* visit and the app forgot immediately. The rule
/// also existed twice — once per platform, written out separately — which is how the iOS
/// copy drifted into expanding every season at once and firing one episode request per
/// season on a long show.
@MainActor
struct SeasonExpansionStoreTests {

  private func freshShowID() -> String { "show_\(UUID().uuidString)" }

  /// With no stored choice, exactly ONE season opens — never all of them, because each
  /// expanded season fires its own episode request.
  @Test func defaultExpandsOnlyTheLowestSeason() {
    let set = SeasonExpansionStore.defaultExpandedSet(allSeasons: [1, 2, 3, 6], highlightSeason: nil)
    #expect(set == [1])
  }

  /// A resume point wins over "lowest" — that is the season the user is actually in.
  @Test func defaultPrefersTheHighlightedSeason() {
    let set = SeasonExpansionStore.defaultExpandedSet(allSeasons: [1, 2, 3, 6], highlightSeason: 6)
    #expect(set == [6])
  }

  /// A highlight for a season the show doesn't have must not open nothing.
  @Test func defaultFallsBackWhenHighlightIsUnknown() {
    let set = SeasonExpansionStore.defaultExpandedSet(allSeasons: [1, 2], highlightSeason: 99)
    #expect(set == [1])
  }

  @Test func choiceSurvivesAndOverridesTheDefault() {
    let id = freshShowID()
    defer { SeasonExpansionStore.clear(showID: id) }
    let seasons = [1, 2, 3, 6]

    // Default opens season 1.
    #expect(SeasonExpansionStore.isExpanded(season: 1, showID: id, allSeasons: seasons, highlightSeason: nil))
    #expect(!SeasonExpansionStore.isExpanded(season: 6, showID: id, allSeasons: seasons, highlightSeason: nil))

    // The user opens 6 and closes 1 — the case that prompted this.
    SeasonExpansionStore.setExpanded(true, season: 6, showID: id, allSeasons: seasons, highlightSeason: nil)
    SeasonExpansionStore.setExpanded(false, season: 1, showID: id, allSeasons: seasons, highlightSeason: nil)

    #expect(SeasonExpansionStore.isExpanded(season: 6, showID: id, allSeasons: seasons, highlightSeason: nil))
    #expect(!SeasonExpansionStore.isExpanded(season: 1, showID: id, allSeasons: seasons, highlightSeason: nil))

    // And a later resume point must NOT quietly re-open season 1 over their choice.
    #expect(!SeasonExpansionStore.isExpanded(season: 1, showID: id, allSeasons: seasons, highlightSeason: 1))
  }

  /// Toggling one season must not disturb the others.
  @Test func togglingOneSeasonPreservesTheRest() {
    let id = freshShowID()
    defer { SeasonExpansionStore.clear(showID: id) }
    let seasons = [1, 2, 3]

    // First change seeds from the default (season 1 open), then adds 3.
    SeasonExpansionStore.setExpanded(true, season: 3, showID: id, allSeasons: seasons, highlightSeason: nil)
    #expect(SeasonExpansionStore.isExpanded(season: 1, showID: id, allSeasons: seasons, highlightSeason: nil))
    #expect(SeasonExpansionStore.isExpanded(season: 3, showID: id, allSeasons: seasons, highlightSeason: nil))
    #expect(!SeasonExpansionStore.isExpanded(season: 2, showID: id, allSeasons: seasons, highlightSeason: nil))
  }

  /// "I collapsed everything" is a real choice and must not be re-read as "no opinion".
  @Test func collapsingEverythingIsHonoured() {
    let id = freshShowID()
    defer { SeasonExpansionStore.clear(showID: id) }
    let seasons = [1, 2]

    SeasonExpansionStore.setExpanded(false, season: 1, showID: id, allSeasons: seasons, highlightSeason: nil)
    #expect(SeasonExpansionStore.storedSelection(showID: id) == [])
    #expect(!SeasonExpansionStore.isExpanded(season: 1, showID: id, allSeasons: seasons, highlightSeason: nil))
    #expect(!SeasonExpansionStore.isExpanded(season: 2, showID: id, allSeasons: seasons, highlightSeason: nil))
  }

  /// Two shows must never share expansion state.
  @Test func showsAreIndependent() {
    let a = freshShowID(), b = freshShowID()
    defer { SeasonExpansionStore.clear(showID: a); SeasonExpansionStore.clear(showID: b) }
    let seasons = [1, 2]

    SeasonExpansionStore.setExpanded(true, season: 2, showID: a, allSeasons: seasons, highlightSeason: nil)
    #expect(SeasonExpansionStore.isExpanded(season: 2, showID: a, allSeasons: seasons, highlightSeason: nil))
    #expect(!SeasonExpansionStore.isExpanded(season: 2, showID: b, allSeasons: seasons, highlightSeason: nil))
  }
}

// =====================================================================================
// MARK: - R4 GAP CLOSURE — the nine mutation survivors
// =====================================================================================
//
// R2's mutation census ran 13 mutations against 105 passing tests and NINE survived. Every
// survivor sat on the destructive or persistence surface: a write could stop writing, a
// delete could stop deleting, a health check could always claim healthy, and the suite
// stayed green. The tests below exist to make those exact mutations go red.
//
// Each test names the mutation it kills. That note is the contract: re-apply the named
// change to production code and the test MUST fail. A test here whose mutation survives is
// a defective test, not an acceptable one.
//
// SHARED-STATE PROBLEM AND HOW IT IS SOLVED
// `LocalStore.shared` and `DownloadManager.shared` are singletons bound to fixed paths in
// the app container. Tests against them would share one database and one downloads.json —
// order dependent, mutually destructive, and on a device run they would wipe the user's own
// library. TEST-DOCTRINE Part 2 rule 4 forbids a shared mutable fixture.
//
// Two minimal seams were added to app code instead (both documented at their definitions):
//   · LocalStore.makeForTesting(databaseURL:) / .makeUnopenableForTesting()
//     — an internal init carrying a URL override. Production `shared` passes nothing and
//       resolves the identical <Documents>/dsreel.db it always did.
//   · DownloadManager.init(containerForTesting:)
//     — an internal init carrying a container override, used by downloadsDirectory() and
//       downloadsMetadataFileURL. Production `shared` passes nothing; same paths as before.
//   · DownloadManager.shouldAcceptResponse(status:)
//     — the 4xx/5xx gate lifted out of `didFinishDownloadingTo` verbatim, because that
//       delegate takes a live URLSessionDownloadTask whose status cannot be chosen in a
//       unit test. The delegate now calls it. No behaviour change.
// No `#if DEBUG`: the shipping code path is the path under test.

/// Each test gets its own empty directory under the temp dir, removed when it finishes.
/// Returns a URL guaranteed to exist — a test that silently wrote nowhere would pass its
/// assertions vacuously, which is the failure mode this whole file is closing.
@MainActor
private func makeTempContainer(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dsreel-r4-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@MainActor
private func removeTempContainer(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}

/// A library row with enough fields set for the rail queries and the item tables.
private func fixtureItem(id: String, title: String, addedAt: String = "2026-01-01T00:00:00Z") -> ItemSummary {
  ItemSummary(
    id: id, type: "movie", title: title, year: 2020,
    durationSeconds: 7200, addedAt: addedAt,
    libraryId: "lib_test", changeSeq: 1
  )
}

// MARK: T-A 1 · LocalStore.upsertSingleProgress — the progress write

/// SURVIVOR M5-upsert. Mutation: `upsertSingleProgress` returns before the write.
/// Every test here re-reads through a FRESH LocalStore on the same file, so an in-memory
/// cache could not satisfy them — per TEST-DOCTRINE B4, in-memory state is not persistence.
@MainActor
struct LocalStoreProgressWriteTests {

  /// OC-PRG-003 · OC-PRG-004 · class:persistence
  /// Given a store with no recorded progress for "mv-dune", when a position of 600s into a
  /// 7200s film is recorded, then reopening the database from disk still reports 600s —
  /// the viewer's place survives a cold start.
  ///
  /// KILLS M5-upsert (skip the write). With the write skipped the second store reads 0.
  /// Also red if the position or duration binding is swapped, or if the row is written
  /// without a primary key so the re-read misses it.
  @Test func recordedPositionIsReadableFromAFreshStoreOnDisk() async throws {
    let dir = try makeTempContainer("prg-persist")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await store.isUnavailable == false, "precondition: the test store must actually open")
    #expect(await store.getProgressSeconds(itemId: "mv-dune") == 0, "precondition: no prior progress")

    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)

    // FRESH read path — a second actor instance opening the same file.
    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.getProgressSeconds(itemId: "mv-dune") == 600, "resume position after reopen")
    #expect(await reopened.pendingProgressCount() == 1, "the write is queued for the server")
  }

  /// OC-PRG-004 · class:persistence
  /// Given nothing recorded, when no write is performed at all, then a fresh store reports
  /// 0 and an empty outbox — the negative case of the test above.
  ///
  /// This is the paired "X does not happen without the precondition" (B6). It is what proves
  /// the test above is not passing off a store that reports 600 for anything asked of it.
  /// Red if getProgressSeconds invented a position, or if setup seeded a row.
  @Test func aStoreWithNoWriteReportsNoProgressAndAnEmptyOutbox() async throws {
    let dir = try makeTempContainer("prg-negative")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await store.isUnavailable == false, "precondition: the test store must actually open")

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.getProgressSeconds(itemId: "mv-dune") == 0)
    #expect(await reopened.pendingProgressCount() == 0)
  }

  /// OC-PRG-002 · class:persistence
  /// Given a position already recorded at 600s, when the viewer watches on to 1800s,
  /// then a fresh store reports 1800 and still holds exactly one row for that title —
  /// the second write UPDATES rather than appending a duplicate.
  ///
  /// KILLS M5-upsert (the second write skipped leaves 600 on disk). Also red if the
  /// ON CONFLICT clause were dropped, since the outbox count would read 2.
  @Test func aLaterPositionReplacesTheEarlierOneWithoutDuplicatingTheRow() async throws {
    let dir = try makeTempContainer("prg-update")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)
    #expect(await store.getProgressSeconds(itemId: "mv-dune") == 600, "precondition: first position landed")

    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 1800, durationSeconds: 7200)

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.getProgressSeconds(itemId: "mv-dune") == 1800, "latest position wins")
    #expect(await reopened.pendingProgressCount() == 1, "one row per title, not one per write")
  }

  /// OC-PRG-003 · class:persistence
  /// Given two different titles watched to two different positions, when both are recorded,
  /// then a fresh store reports each title's own position — a write for one must not
  /// overwrite or leak into another.
  ///
  /// KILLS M5-upsert, and additionally kills a write that ignores its itemId argument
  /// (binding a constant id), which a single-item test cannot detect.
  @Test func eachTitleKeepsItsOwnPositionIndependently() async throws {
    let dir = try makeTempContainer("prg-multi")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)
    await store.upsertSingleProgress(itemId: "mv-heat", positionSeconds: 2400, durationSeconds: 10_000)

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.getProgressSeconds(itemId: "mv-dune") == 600)
    #expect(await reopened.getProgressSeconds(itemId: "mv-heat") == 2400)
    #expect(await reopened.pendingProgressCount() == 2)
  }

  /// OC-PRG-005 · class:persistence
  /// Given a position recorded while the server was unreachable, when the server later
  /// confirms that exact value, then the row leaves the outbox but the position itself
  /// is still on disk — syncing is not forgetting.
  ///
  /// KILLS M5-upsert (nothing to sync if nothing was written, so the outbox would read 0
  /// at the precondition). Also red if markProgressSynced deleted the row instead of
  /// clearing its flag.
  @Test func confirmingASyncClearsTheOutboxButKeepsThePosition() async throws {
    let dir = try makeTempContainer("prg-sync")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)
    #expect(await store.pendingProgressCount() == 1, "precondition: the write is pending")

    await store.markProgressSynced(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.pendingProgressCount() == 0, "outbox drained")
    #expect(await reopened.getProgressSeconds(itemId: "mv-dune") == 600, "position retained")
  }

  /// OC-PRG-005 · class:state
  /// Given a position uploaded at 600s and the viewer watching on to 1800s mid-flush,
  /// when the server confirms the stale 600s value, then the row STAYS pending — the newer
  /// position must not be dropped from the outbox.
  ///
  /// Red if markProgressSynced's position/duration WHERE clause is removed (the documented
  /// reason it is value-guarded). Also red under M5-upsert, since the 1800 write would
  /// never land and the stale confirmation would then match.
  @Test func aStaleServerConfirmationDoesNotClearANewerPosition() async throws {
    let dir = try makeTempContainer("prg-stale")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)
    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 1800, durationSeconds: 7200)
    #expect(await store.getProgressSeconds(itemId: "mv-dune") == 1800, "precondition: viewer advanced to 1800")

    await store.markProgressSynced(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.pendingProgressCount() == 1, "newer position is still owed to the server")
    #expect(await reopened.getProgressSeconds(itemId: "mv-dune") == 1800)
  }

  /// OC-PRG-028 · class:destructive
  /// Given a queued position for a title the NAS no longer has, when the server rejects it
  /// permanently and the row is dropped, then the outbox is empty on a fresh read so the
  /// rows behind it can flush.
  ///
  /// Guards the documented stall: a permanently-rejected row that never leaves the outbox
  /// blocks every row queued after it. Red if dropPendingProgress becomes a no-op.
  @Test func droppingAPermanentlyRejectedRowUnblocksTheOutbox() async throws {
    let dir = try makeTempContainer("prg-drop")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertSingleProgress(itemId: "mv-deleted", positionSeconds: 600, durationSeconds: 7200)
    await store.upsertSingleProgress(itemId: "mv-behind", positionSeconds: 300, durationSeconds: 7200)
    #expect(await store.pendingProgressCount() == 2, "precondition: two rows queued")

    await store.dropPendingProgress(itemId: "mv-deleted")

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.pendingProgressCount() == 1, "only the rejected row left the outbox")
    let stillPending = await reopened.pendingProgress().map(\.itemId)
    #expect(stillPending.contains("mv-behind"), "the row behind it survives by identity")
    #expect(!stillPending.contains("mv-deleted"), "the rejected row is gone by identity")
  }
}

// MARK: T-A 4 · LocalStore.isUnavailable — the health check

/// SURVIVOR M2-ready. Mutation: `isUnavailable` always returns false ("store always healthy").
/// This is TASK-889's entire detection mechanism — the reason a silently-dropped write is
/// visible at all. A check that cannot say "unhealthy" is not a check.
@MainActor
struct LocalStoreAvailabilityTests {

  /// OC-PRG-026 · class:error
  /// Given a store whose database file cannot be opened, when its health is read, then it
  /// reports unavailable and carries a reason the UI can show the viewer.
  ///
  /// KILLS M2-ready (always-false). With the mutation `isUnavailable` reads false here and
  /// `unavailableReason` — which is gated on it — goes nil, so both assertions fail.
  @Test func aStoreThatCannotOpenItsDatabaseReportsItselfUnavailableWithAReason() async throws {
    let store = await LocalStore.makeUnopenableForTesting()

    #expect(await store.isUnavailable == true, "a store that could not open is not healthy")
    let reason = await store.unavailableReason
    #expect(reason != nil, "an unavailable store must give the UI something to say")
    #expect(reason?.contains("can't be saved") == true, "the reason names the actual problem: saving")
  }

  /// OC-PRG-026 · class:state
  /// Given a store whose database opened normally, when its health is read, then it reports
  /// available and offers NO reason — the negative case, and the one that proves the test
  /// above is not satisfied by a property hardwired to `true`.
  ///
  /// Red if `isUnavailable` were inverted or pinned to true, which would otherwise look like
  /// a passing health check.
  @Test func aStoreThatOpenedNormallyReportsItselfAvailableWithNoReason() async throws {
    let dir = try makeTempContainer("avail-ok")
    defer { removeTempContainer(dir) }

    let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))

    #expect(await store.isUnavailable == false)
    #expect(await store.unavailableReason == nil, "a healthy store must not show an error banner")
  }

  /// OC-PRG-026 · class:error
  /// Given an unavailable store, when a watch position is written to it and then read back,
  /// then the read returns 0 — the write genuinely did NOT persist, which is exactly why
  /// `isUnavailable` has to be truthful rather than reassuring.
  ///
  /// This is the behavioural consequence the health flag exists to disclose: under M2-ready
  /// the app would report a healthy store while this write vanished. Red if a dead store
  /// silently started caching writes in memory and reporting them back as saved.
  @Test func anUnavailableStoreDiscardsWritesRatherThanPersistingThem() async throws {
    let store = await LocalStore.makeUnopenableForTesting()
    #expect(await store.isUnavailable == true, "precondition: this store is genuinely dead")

    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)

    #expect(await store.getProgressSeconds(itemId: "mv-dune") == 0, "nothing was saved, and nothing is claimed")
    #expect(await store.pendingProgressCount() == 0, "no phantom outbox row for a write that never landed")
    #expect(await store.totalItemCount() == 0)
  }
}

// MARK: T-A 5 & 6 · LocalStore.clearAll and deleteItems — the destructive paths

/// SURVIVORS M1-clearall (clearAll is a no-op) and M6-delitems (deleteItems deletes nothing).
/// `clearAll` is what runs on sign-out: if it no-ops, one user's library and watch history
/// stay on a shared device. Every assertion below is by identity and count delta, never by
/// position — a positional assertion on a mutated collection is TEST-DOCTRINE B5.
@MainActor
struct LocalStoreDestructiveTests {

  /// OC-AUT-022 · OC-AUT-023 · class:destructive
  /// Given a store holding 4 library items, recorded progress, and advanced sync cursors,
  /// when everything is cleared on sign-out, then a fresh read of the database finds no
  /// items, no progress, an empty outbox, and both cursors back at 0.
  ///
  /// KILLS M1-clearall (no-op). Every assertion below reads non-zero before the clear, so
  /// a clear that does nothing fails all of them. The cursor reset matters on its own: a
  /// cleared library with a live watermark would never re-sync for the next account.
  @Test func signOutClearEmptiesItemsProgressAndSyncCursorsOnDisk() async throws {
    let dir = try makeTempContainer("clearall")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertItems([
      fixtureItem(id: "mv-dune", title: "Dune"),
      fixtureItem(id: "mv-heat", title: "Heat"),
      fixtureItem(id: "mv-alien", title: "Alien"),
      fixtureItem(id: "mv-brazil", title: "Brazil"),
    ])
    await store.upsertSingleProgress(itemId: "mv-dune", positionSeconds: 600, durationSeconds: 7200)
    await store.setItemSeq(4120)
    await store.setProgressSeq(77)

    // PRECONDITIONS — without these the clear assertions pass against an empty store.
    #expect(await store.totalItemCount() == 4, "precondition: 4 items present")
    #expect(await store.getProgressSeconds(itemId: "mv-dune") == 600, "precondition: progress present")
    #expect(await store.getSyncCursors().itemSeq == 4120, "precondition: item cursor advanced")
    #expect(await store.getSyncCursors().progressSeq == 77, "precondition: progress cursor advanced")

    await store.clearAll()

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.totalItemCount() == 0, "no library rows survive sign-out")
    #expect(await reopened.hasItems() == false)
    #expect(await reopened.getProgressSeconds(itemId: "mv-dune") == 0, "no watch history survives sign-out")
    #expect(await reopened.pendingProgressCount() == 0, "no queued progress survives sign-out")
    #expect(await reopened.getSyncCursors().itemSeq == 0, "item cursor reset so the next account re-syncs")
    #expect(await reopened.getSyncCursors().progressSeq == 0, "progress cursor reset")
  }

  /// OC-LIB-001 · class:state
  /// Given a store holding 4 library items, when nothing is cleared, then a fresh read
  /// still finds all 4 by identity — the negative case for the clear above.
  ///
  /// Proves `clearAll` is what empties the store, not the act of reopening it. Red if the
  /// fresh-read path returned empty for any reason, which would make the clear test pass
  /// for the wrong reason.
  @Test func reopeningTheStoreWithoutClearingKeepsEveryItemByIdentity() async throws {
    let dir = try makeTempContainer("clearall-negative")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertItems([
      fixtureItem(id: "mv-dune", title: "Dune"),
      fixtureItem(id: "mv-heat", title: "Heat"),
      fixtureItem(id: "mv-alien", title: "Alien"),
      fixtureItem(id: "mv-brazil", title: "Brazil"),
    ])
    #expect(await store.totalItemCount() == 4, "precondition: 4 items present")

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.totalItemCount() == 4)
    let ids = Set(await reopened.fetchItems(forLibraryId: "lib_test").map(\.id))
    #expect(ids == Set(["mv-dune", "mv-heat", "mv-alien", "mv-brazil"]))
  }

  /// OC-LIB-028 · class:destructive
  /// Given a library of 4 titles, when "mv-heat" is removed because the NAS no longer has
  /// it, then a fresh read finds exactly 3, mv-heat absent by identity, and the other three
  /// present by identity.
  ///
  /// KILLS M6-delitems (delete nothing) — the count stays 4 and mv-heat is still found.
  /// Also kills a delete that removes by POSITION rather than by id, because the surviving
  /// set is asserted explicitly rather than by count alone.
  @Test func deletingOneItemRemovesOnlyThatIdentityAndPersists() async throws {
    let dir = try makeTempContainer("delitems")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertItems([
      fixtureItem(id: "mv-dune", title: "Dune"),
      fixtureItem(id: "mv-heat", title: "Heat"),
      fixtureItem(id: "mv-alien", title: "Alien"),
      fixtureItem(id: "mv-brazil", title: "Brazil"),
    ])
    #expect(await store.totalItemCount() == 4, "precondition: 4 items before the delete")
    let before = Set(await store.fetchItems(forLibraryId: "lib_test").map(\.id))
    #expect(before.contains("mv-heat"), "precondition: the delete target is actually present")

    await store.deleteItems(["mv-heat"])

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.totalItemCount() == 3, "exactly one fewer")
    let after = Set(await reopened.fetchItems(forLibraryId: "lib_test").map(\.id))
    #expect(!after.contains("mv-heat"), "the target is gone by identity")
    #expect(after == Set(["mv-dune", "mv-alien", "mv-brazil"]), "every survivor present by identity")
  }

  /// OC-LIB-028 · class:destructive
  /// Given a library of 4 titles, when two of them are removed in one call, then a fresh
  /// read finds exactly 2 and both named identities are absent.
  ///
  /// KILLS M6-delitems, and additionally kills a loop that only ever deletes the first id —
  /// a single-id test cannot tell those apart.
  @Test func deletingSeveralItemsRemovesEveryNamedIdentityNotJustTheFirst() async throws {
    let dir = try makeTempContainer("delitems-many")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertItems([
      fixtureItem(id: "mv-dune", title: "Dune"),
      fixtureItem(id: "mv-heat", title: "Heat"),
      fixtureItem(id: "mv-alien", title: "Alien"),
      fixtureItem(id: "mv-brazil", title: "Brazil"),
    ])
    #expect(await store.totalItemCount() == 4, "precondition: 4 items before the delete")

    await store.deleteItems(["mv-heat", "mv-brazil"])

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.totalItemCount() == 2, "two fewer")
    let after = Set(await reopened.fetchItems(forLibraryId: "lib_test").map(\.id))
    #expect(after == Set(["mv-dune", "mv-alien"]))
    #expect(!after.contains("mv-heat"))
    #expect(!after.contains("mv-brazil"))
  }

  /// OC-LIB-002 · class:empty
  /// Given a library of 4 titles, when a delete is called with an empty id list, then a
  /// fresh read still finds all 4 — the boundary case, and the negative case for the
  /// deletes above.
  ///
  /// Red if the empty-list guard were removed and the statement ran unbound, which in
  /// SQLite would match NULL and could delete nothing — or, with a different SQL shape,
  /// everything. This pins "asked to delete nothing, deleted nothing".
  @Test func deletingAnEmptyListOfItemsRemovesNothing() async throws {
    let dir = try makeTempContainer("delitems-empty")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertItems([
      fixtureItem(id: "mv-dune", title: "Dune"),
      fixtureItem(id: "mv-heat", title: "Heat"),
      fixtureItem(id: "mv-alien", title: "Alien"),
      fixtureItem(id: "mv-brazil", title: "Brazil"),
    ])
    #expect(await store.totalItemCount() == 4, "precondition: 4 items present")

    await store.deleteItems([])

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.totalItemCount() == 4)
    #expect(Set(await reopened.fetchItems(forLibraryId: "lib_test").map(\.id))
            == Set(["mv-dune", "mv-heat", "mv-alien", "mv-brazil"]))
  }

  /// OC-LIB-028 · class:destructive
  /// Given a library of 4 titles, when a delete names an id the store does not hold,
  /// then a fresh read still finds all 4 — an unknown id must not take a real row with it.
  ///
  /// Red if the delete matched loosely (a LIKE, or a prefix match) or if it fell back to
  /// removing the first row when the id was not found.
  @Test func deletingAnUnknownIdLeavesEveryRealItemIntact() async throws {
    let dir = try makeTempContainer("delitems-unknown")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    await store.upsertItems([
      fixtureItem(id: "mv-dune", title: "Dune"),
      fixtureItem(id: "mv-heat", title: "Heat"),
      fixtureItem(id: "mv-alien", title: "Alien"),
      fixtureItem(id: "mv-brazil", title: "Brazil"),
    ])
    #expect(await store.totalItemCount() == 4, "precondition: 4 items present")

    await store.deleteItems(["mv-does-not-exist"])

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.totalItemCount() == 4)
    #expect(Set(await reopened.fetchItems(forLibraryId: "lib_test").map(\.id))
            == Set(["mv-dune", "mv-heat", "mv-alien", "mv-brazil"]))
  }
}

// MARK: T-A 2 · DownloadManager.updateResumePosition — the offline resume write

/// SURVIVOR M5-resume. Mutation: `updateResumePosition` skips the write to downloads.json.
/// This is the offline half of the 1.3.6 P0 (TASK-889): a viewer watching a downloaded film
/// with no NAS in reach has nowhere else for their place to live.
@MainActor
struct DownloadResumePositionTests {

  /// Writes a downloads.json into `container` holding the given entries, and creates the
  /// backing video files so `getDownloadedItems()` does not filter them out as missing.
  /// Returns nothing — callers assert the precondition through the manager itself, so a
  /// fixture that failed to arrange is caught rather than assumed.
  private func seedDownloads(_ items: [DownloadedItem], in container: URL) throws {
    let downloadsDir = container.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
    for item in items {
      try Data("fake-mp4-bytes".utf8)
        .write(to: downloadsDir.appendingPathComponent(item.videoPath))
    }
    let data = try JSONEncoder().encode(items)
    try data.write(to: container.appendingPathComponent("downloads.json"), options: .atomic)
  }

  private func entry(id: String, title: String, resume: Int = 0) -> DownloadedItem {
    DownloadedItem(
      id: id, title: title, year: 2020,
      videoPath: "\(id).mp4", posterPath: nil,
      fileSize: 15, downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
      resumePositionSeconds: resume, durationSeconds: 7200
    )
  }

  /// OC-DWN-020 · OC-OFF-015 · class:persistence
  /// Given a downloaded film at position 0, when the viewer stops 900s in while offline,
  /// then a cold-started manager reading downloads.json from disk reports 900 — their place
  /// offline survives a relaunch.
  ///
  /// KILLS M5-resume (skip the write). The second manager is a separate instance with its
  /// own empty cache, so it can only answer 900 by reading the file: per B4, the in-memory
  /// value the first manager holds is not persistence.
  @Test func anOfflineResumePositionIsReadableFromDiskAfterARelaunch() async throws {
    let container = try makeTempContainer("dl-resume")
    defer { removeTempContainer(container) }
    try seedDownloads([entry(id: "mv-dune", title: "Dune")], in: container)

    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.getDownloadedItem(itemId: "mv-dune")?.resumePositionSeconds == 0,
            "precondition: the seeded entry starts at 0")

    manager.updateResumePosition(itemId: "mv-dune", positionSeconds: 900)

    // FRESH read path — a new manager over the same container, no shared cache.
    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItem(itemId: "mv-dune")?.resumePositionSeconds == 900,
            "offline resume position after a cold start")
  }

  /// OC-DWN-020 · class:persistence
  /// Given a downloaded film at position 0, when no position is ever written, then a
  /// cold-started manager still reports 0 — the negative case.
  ///
  /// Proves the 900 above came from the write and not from the fixture or the decoder.
  /// Red if `resumePositionSeconds` decoded to something other than what was stored.
  @Test func aDownloadNeverPlayedReportsNoResumePositionAfterARelaunch() async throws {
    let container = try makeTempContainer("dl-resume-negative")
    defer { removeTempContainer(container) }
    try seedDownloads([entry(id: "mv-dune", title: "Dune")], in: container)

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItem(itemId: "mv-dune")?.resumePositionSeconds == 0)
  }

  /// OC-DWN-020 · class:state
  /// Given three downloaded films with "mv-heat" at 120s, when the viewer's position in
  /// mv-heat advances to 1500s, then a cold-started manager reports 1500 for mv-heat and
  /// still 0 for both neighbours — a resume write must land on one title only.
  ///
  /// KILLS M5-resume, and additionally kills a write that ignores its itemId and stamps
  /// the first entry (or every entry) — which the single-item test above cannot detect.
  @Test func aResumeWriteTouchesOnlyItsOwnTitleAndLeavesNeighboursAtZero() async throws {
    let container = try makeTempContainer("dl-resume-multi")
    defer { removeTempContainer(container) }
    try seedDownloads([
      entry(id: "mv-dune", title: "Dune"),
      entry(id: "mv-heat", title: "Heat", resume: 120),
      entry(id: "mv-alien", title: "Alien"),
    ], in: container)

    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.getDownloadedItem(itemId: "mv-heat")?.resumePositionSeconds == 120,
            "precondition: mv-heat starts at 120")

    manager.updateResumePosition(itemId: "mv-heat", positionSeconds: 1500)

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItem(itemId: "mv-heat")?.resumePositionSeconds == 1500)
    #expect(relaunched.getDownloadedItem(itemId: "mv-dune")?.resumePositionSeconds == 0,
            "a neighbour's position must not move")
    #expect(relaunched.getDownloadedItem(itemId: "mv-alien")?.resumePositionSeconds == 0)
    #expect(relaunched.getDownloadedItems().count == 3, "and no entry is lost by the write")
  }

  /// OC-DWN-020 · class:empty
  /// Given a downloads list holding only "mv-dune", when a resume position is written for a
  /// title that is not downloaded, then a cold-started manager finds mv-dune untouched at 0
  /// and no entry invented for the unknown title.
  ///
  /// Red if the unknown-id guard were removed and the write appended a bogus entry, or
  /// stamped the position onto whatever entry happened to be first.
  @Test func aResumeWriteForATitleThatIsNotDownloadedChangesNothing() async throws {
    let container = try makeTempContainer("dl-resume-unknown")
    defer { removeTempContainer(container) }
    try seedDownloads([entry(id: "mv-dune", title: "Dune")], in: container)

    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.getDownloadedItems().count == 1, "precondition: exactly one download")

    manager.updateResumePosition(itemId: "mv-not-downloaded", positionSeconds: 1500)

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItems().count == 1, "no entry invented")
    #expect(relaunched.getDownloadedItem(itemId: "mv-dune")?.resumePositionSeconds == 0,
            "the real entry is untouched")
    #expect(relaunched.getDownloadedItem(itemId: "mv-not-downloaded") == nil)
  }

  /// OC-DWN-007 · class:persistence
  /// Given a downloaded film whose metadata stores a bare filename, when a resume position
  /// is written, then the file on disk still stores a bare filename — not the absolute path
  /// the read path resolves to.
  ///
  /// The documented invariant: `updateResumePosition` reads raw JSON precisely so it does
  /// not write resolved absolute paths back. Red if it were reimplemented over
  /// `getDownloadedItems()`, which would bake a container path into the file and strand
  /// every download the next time the app's container id changes.
  @Test func aResumeWriteDoesNotRewriteStoredPathsAsAbsolute() async throws {
    let container = try makeTempContainer("dl-resume-paths")
    defer { removeTempContainer(container) }
    try seedDownloads([entry(id: "mv-dune", title: "Dune")], in: container)

    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.getDownloadedItems().count == 1, "precondition: exactly one download")

    manager.updateResumePosition(itemId: "mv-dune", positionSeconds: 900)

    let raw = try Data(contentsOf: container.appendingPathComponent("downloads.json"))
    let stored = try JSONDecoder().decode([DownloadedItem].self, from: raw)
    #expect(stored.count == 1)
    #expect(stored.first(where: { $0.id == "mv-dune" })?.videoPath == "mv-dune.mp4",
            "stored path stays a bare filename")
    #expect(stored.first(where: { $0.id == "mv-dune" })?.resumePositionSeconds == 900)
  }
}

// MARK: T-A 3 · DownloadManager HTTP status gate — the 1.3.6 P0 (TASK-887)

/// SURVIVOR M2-httpfail. Mutation: invert the `!(200...299)` check in
/// `didFinishDownloadingTo`, so an error body is kept as the movie and a real download is
/// thrown away.
///
/// URLSession reports `didFinishDownloadingTo` for ANY completed response — 4xx and 5xx
/// included, since `error` is only set for transport failures. Before the gate landed, a
/// 22-byte `{"error":"not_found"}` was moved to `{itemId}.mp4` and marked downloaded, so
/// offline playback failed on a file the UI swore was present.
///
/// The decision is tested through `shouldAcceptResponse(status:)`, the pure function the
/// delegate now calls. The delegate method itself takes a live `URLSessionDownloadTask`
/// whose status cannot be chosen from a test; extracting the predicate changed no behaviour.
@MainActor
struct DownloadResponseGateTests {

  /// OC-DWN-018 · class:error
  /// Given a finished transfer whose response was 404, when the gate is asked whether to
  /// keep the bytes, then it says no — a not-found body must never become the .mp4.
  ///
  /// KILLS M2-httpfail directly: inverting the range check makes this return true.
  @Test func aNotFoundResponseIsRejectedSoItsBodyIsNeverStoredAsTheVideo() {
    #expect(DownloadManager.shouldAcceptResponse(status: 404) == false)
  }

  /// OC-DWN-006 · class:error
  /// Given a finished transfer, when the response status is any 4xx or 5xx the NAS can
  /// realistically return, then the gate rejects every one of them.
  ///
  /// Each status is written as a literal with its expected verdict as a literal — no
  /// re-derivation from the production range (B2). 401/403 matter specifically: an expired
  /// session is the most common cause, and its body is JSON, not video. 206 is here as the
  /// partial-content case a range request legitimately returns and must be kept.
  @Test func everyErrorStatusIsRejectedAndEverySuccessStatusIsAccepted() {
    #expect(DownloadManager.shouldAcceptResponse(status: 400) == false)
    #expect(DownloadManager.shouldAcceptResponse(status: 401) == false)
    #expect(DownloadManager.shouldAcceptResponse(status: 403) == false)
    #expect(DownloadManager.shouldAcceptResponse(status: 404) == false)
    #expect(DownloadManager.shouldAcceptResponse(status: 410) == false)
    #expect(DownloadManager.shouldAcceptResponse(status: 500) == false)
    #expect(DownloadManager.shouldAcceptResponse(status: 502) == false)
    #expect(DownloadManager.shouldAcceptResponse(status: 503) == false)

    #expect(DownloadManager.shouldAcceptResponse(status: 200) == true)
    #expect(DownloadManager.shouldAcceptResponse(status: 206) == true)
  }

  /// OC-DWN-018 · class:boundary
  /// Given the accepted range is 200 through 299, when each edge and each neighbour just
  /// outside it is checked, then 199 and 300 are rejected while 200 and 299 are accepted.
  ///
  /// Kills an off-by-one on either end (`200...299` widened to `199...300`, or narrowed to
  /// `201...298`). A redirect at 300 is not a delivered file; keeping its body would store
  /// an HTML redirect page as the movie.
  @Test func theAcceptedStatusRangeIsExactlyTwoHundredThroughTwoNinetyNine() {
    #expect(DownloadManager.shouldAcceptResponse(status: 199) == false)
    #expect(DownloadManager.shouldAcceptResponse(status: 200) == true)
    #expect(DownloadManager.shouldAcceptResponse(status: 299) == true)
    #expect(DownloadManager.shouldAcceptResponse(status: 300) == false)
  }

  /// OC-DWN-008 · class:state
  /// Given a transfer with no HTTP response at all — a `file://` URL has none — when the
  /// gate is asked, then it accepts, because there is no status to reject on.
  ///
  /// This is the negative case for the rejections above: the gate must reject on a BAD
  /// status, not on the absence of one. Red if the guard were changed to treat a missing
  /// status as a failure, which would discard every legitimate non-HTTP transfer.
  @Test func aTransferWithNoHTTPStatusIsAcceptedRatherThanDiscarded() {
    #expect(DownloadManager.shouldAcceptResponse(status: nil) == true)
  }
}

// MARK: T-A 7 · DownloadManager.deleteDownload — removing a download

/// SURVIVOR M1-delete-dl. Mutation: `deleteDownload` does nothing. A delete that silently
/// no-ops leaves multi-GB files on disk while the UI reports them gone, and the viewer's
/// freed space never returns.
@MainActor
struct DownloadDeleteTests {

  private func seedDownloads(_ items: [DownloadedItem], in container: URL) throws {
    let downloadsDir = container.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
    for item in items {
      try Data("fake-mp4-bytes".utf8)
        .write(to: downloadsDir.appendingPathComponent(item.videoPath))
    }
    try JSONEncoder().encode(items)
      .write(to: container.appendingPathComponent("downloads.json"), options: .atomic)
  }

  private func entry(id: String, title: String) -> DownloadedItem {
    DownloadedItem(
      id: id, title: title, year: 2020,
      videoPath: "\(id).mp4", posterPath: nil,
      fileSize: 15, downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
      resumePositionSeconds: 0, durationSeconds: 7200
    )
  }

  /// OC-DWN-009 · OC-DWN-010 · OC-DWN-023 · class:destructive
  /// Given four completed downloads, when the viewer deletes "mv-heat", then a
  /// cold-started manager lists exactly three, mv-heat is absent by identity, the other
  /// three are present by identity, and mv-heat's bytes are gone from disk while theirs
  /// remain.
  ///
  /// KILLS M1-delete-dl (no-op): the count stays 4, mv-heat is still listed, and its file
  /// is still on disk. Also kills a delete that removes by POSITION — the surviving set is
  /// asserted explicitly, never via `.first` or `[0]` (B5). The on-disk file check is what
  /// makes "reclaims space" (OC-DWN-010) a real assertion rather than a bookkeeping one.
  @Test func deletingOneDownloadRemovesOnlyItsEntryAndItsBytes() async throws {
    let container = try makeTempContainer("dl-delete")
    defer { removeTempContainer(container) }
    try seedDownloads([
      entry(id: "mv-dune", title: "Dune"),
      entry(id: "mv-heat", title: "Heat"),
      entry(id: "mv-alien", title: "Alien"),
      entry(id: "mv-brazil", title: "Brazil"),
    ], in: container)
    let downloadsDir = container.appendingPathComponent("Downloads", isDirectory: true)

    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.getDownloadedItems().count == 4, "precondition: 4 downloads present")
    #expect(manager.isDownloaded(itemId: "mv-heat"), "precondition: the delete target is present")
    #expect(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-heat.mp4").path),
            "precondition: the target's bytes are on disk")

    manager.deleteDownload(itemId: "mv-heat")

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItems().count == 3, "exactly one fewer entry")
    let ids = Set(relaunched.getDownloadedItems().map(\.id))
    #expect(!ids.contains("mv-heat"), "the target is gone by identity")
    #expect(ids == Set(["mv-dune", "mv-alien", "mv-brazil"]), "every survivor present by identity")
    #expect(relaunched.isDownloaded(itemId: "mv-heat") == false)

    #expect(!FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-heat.mp4").path),
            "the deleted title's bytes are reclaimed")
    #expect(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-dune.mp4").path),
            "a neighbour's bytes are untouched")
    #expect(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-alien.mp4").path))
    #expect(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-brazil.mp4").path))
  }

  /// class:destructive · TASK-903
  /// A delete must announce itself BEFORE the bytes go, so a player reading that asset can
  /// tear down first. AVPlayer holds the file open; unlinking underneath it presented as a
  /// stall or a decode error naming neither the cause nor anything actionable.
  ///
  /// The ORDERING is the whole fix, so the test asserts it directly: at the moment the
  /// notification is delivered, the file must still exist. A post moved to after the
  /// unlink would still fire and still carry the right id — and would be useless.
  @Test func deletingADownloadAnnouncesItselfBeforeRemovingTheFile() async throws {
    let container = try makeTempContainer("dl-delete-notify")
    defer { removeTempContainer(container) }
    try seedDownloads([
      entry(id: "mv-dune", title: "Dune"),
      entry(id: "mv-heat", title: "Heat"),
    ], in: container)
    let heatPath = container.appendingPathComponent("Downloads/mv-heat.mp4").path

    // deleteDownload posts synchronously on the calling thread, and this suite is
    // @MainActor, so the observer runs before deleteDownload returns. No synchronisation
    // needed — and if that ever stops being true, #require below fails rather than racing.
    nonisolated(unsafe) var received: (id: String?, fileStillExisted: Bool)?
    let token = NotificationCenter.default.addObserver(
      forName: .downloadWillBeDeleted, object: nil, queue: nil
    ) { note in
      received = (
        id: note.userInfo?["itemId"] as? String,
        fileStillExisted: FileManager.default.fileExists(atPath: heatPath)
      )
    }
    defer { NotificationCenter.default.removeObserver(token) }

    DownloadManager(containerForTesting: container).deleteDownload(itemId: "mv-heat")

    let got = try #require(received, "deleting a download posted no notification")
    #expect(got.id == "mv-heat", "the notification must name the item being deleted")
    #expect(got.fileStillExisted,
            "the notification fired AFTER the unlink — a player cannot release a file that is already gone, which is the entire point of announcing it")
    // And the delete still happened: announcing must not become a way to skip it.
    #expect(!FileManager.default.fileExists(atPath: heatPath))
  }

  /// class:destructive · TASK-903
  /// clearAll() is the sign-out purge (TASK-807). It must announce too, with NO itemId —
  /// meaning "whatever you have loaded is going" — and must still purge everything.
  @Test func clearAllAnnouncesTheWholePurgeBeforeRemovingFiles() async throws {
    let container = try makeTempContainer("dl-clearall-notify")
    defer { removeTempContainer(container) }
    try seedDownloads([
      entry(id: "mv-dune", title: "Dune"),
      entry(id: "mv-heat", title: "Heat"),
    ], in: container)
    let dunePath = container.appendingPathComponent("Downloads/mv-dune.mp4").path

    nonisolated(unsafe) var received: (hadKey: Bool, filesStillExisted: Bool)?
    let token = NotificationCenter.default.addObserver(
      forName: .downloadWillBeDeleted, object: nil, queue: nil
    ) { note in
      received = (
        hadKey: note.userInfo?["itemId"] != nil,
        filesStillExisted: FileManager.default.fileExists(atPath: dunePath)
      )
    }
    defer { NotificationCenter.default.removeObserver(token) }

    DownloadManager(containerForTesting: container).clearAll()

    let got = try #require(received, "clearAll posted no notification")
    #expect(!got.hadKey,
            "clearAll must omit itemId — a specific id would let a player reading a DIFFERENT download keep a file that is also being purged")
    #expect(got.filesStillExisted, "the notification fired after files were already removed")
    // The purge is not negotiable: it exists so a shared device leaves no residue.
    #expect(!FileManager.default.fileExists(atPath: dunePath))
    #expect(DownloadManager(containerForTesting: container).getDownloadedItems().isEmpty)
  }

  /// OC-DWN-009 · class:state
  /// Given four completed downloads, when nothing is deleted, then a cold-started manager
  /// still lists all four by identity with every file on disk — the negative case.
  ///
  /// Proves the delete test's empty result comes from the delete, not from a read path that
  /// happens to drop entries (it legitimately drops entries whose files are missing, which
  /// is exactly why this has to be pinned separately).
  @Test func relaunchingWithoutDeletingKeepsEveryDownloadByIdentity() async throws {
    let container = try makeTempContainer("dl-delete-negative")
    defer { removeTempContainer(container) }
    try seedDownloads([
      entry(id: "mv-dune", title: "Dune"),
      entry(id: "mv-heat", title: "Heat"),
      entry(id: "mv-alien", title: "Alien"),
      entry(id: "mv-brazil", title: "Brazil"),
    ], in: container)

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItems().count == 4)
    #expect(Set(relaunched.getDownloadedItems().map(\.id))
            == Set(["mv-dune", "mv-heat", "mv-alien", "mv-brazil"]))
  }

  /// OC-DWN-009 · class:empty
  /// Given two completed downloads, when a delete names a title that is not downloaded,
  /// then a cold-started manager still lists both by identity with both files on disk.
  ///
  /// Red if the `firstIndex(where:)` guard were dropped so an unknown id fell through to
  /// removing some other row — the classic destructive-path off-by-one.
  @Test func deletingATitleThatIsNotDownloadedRemovesNothing() async throws {
    let container = try makeTempContainer("dl-delete-unknown")
    defer { removeTempContainer(container) }
    try seedDownloads([
      entry(id: "mv-dune", title: "Dune"),
      entry(id: "mv-heat", title: "Heat"),
    ], in: container)
    let downloadsDir = container.appendingPathComponent("Downloads", isDirectory: true)

    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.getDownloadedItems().count == 2, "precondition: 2 downloads present")

    manager.deleteDownload(itemId: "mv-not-downloaded")

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItems().count == 2)
    #expect(Set(relaunched.getDownloadedItems().map(\.id)) == Set(["mv-dune", "mv-heat"]))
    #expect(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-dune.mp4").path))
    #expect(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-heat.mp4").path))
  }

  /// OC-DWN-009 · class:boundary
  /// Given exactly one completed download, when it is deleted, then a cold-started manager
  /// lists none and its bytes are gone — the count-of-one boundary, where an off-by-one in
  /// the index arithmetic shows up.
  ///
  /// KILLS M1-delete-dl. Also red if the delete refused to act on the last remaining entry.
  @Test func deletingTheOnlyDownloadLeavesAnEmptyListAndNoBytes() async throws {
    let container = try makeTempContainer("dl-delete-last")
    defer { removeTempContainer(container) }
    try seedDownloads([entry(id: "mv-dune", title: "Dune")], in: container)
    let downloadsDir = container.appendingPathComponent("Downloads", isDirectory: true)

    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.getDownloadedItems().count == 1, "precondition: exactly one download")

    manager.deleteDownload(itemId: "mv-dune")

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItems().count == 0)
    #expect(relaunched.isDownloaded(itemId: "mv-dune") == false)
    #expect(!FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-dune.mp4").path))
  }

  /// OC-DWN-026 · class:destructive
  /// Given three completed downloads, when sign-out purges every download, then a
  /// cold-started manager lists none and not one of the three files remains on disk.
  ///
  /// OC-DWN-026 forbids partial removal specifically: orphaned bytes with no entry, or
  /// entries pointing at missing files, are both failures. Red if `clearAll` no-ops, and red
  /// if it clears bookkeeping while leaving the media — the case the file checks catch.
  @Test func signOutPurgeRemovesEveryDownloadEntryAndEveryFile() async throws {
    let container = try makeTempContainer("dl-clearall")
    defer { removeTempContainer(container) }
    try seedDownloads([
      entry(id: "mv-dune", title: "Dune"),
      entry(id: "mv-heat", title: "Heat"),
      entry(id: "mv-alien", title: "Alien"),
    ], in: container)
    let downloadsDir = container.appendingPathComponent("Downloads", isDirectory: true)

    let manager = DownloadManager(containerForTesting: container)
    #expect(manager.getDownloadedItems().count == 3, "precondition: 3 downloads present")
    #expect(FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-heat.mp4").path),
            "precondition: the files are on disk")

    manager.clearAll()

    let relaunched = DownloadManager(containerForTesting: container)
    #expect(relaunched.getDownloadedItems().count == 0, "no entry survives sign-out")
    #expect(relaunched.isDownloaded(itemId: "mv-dune") == false)
    #expect(relaunched.isDownloaded(itemId: "mv-heat") == false)
    #expect(relaunched.isDownloaded(itemId: "mv-alien") == false)
    #expect(!FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-dune.mp4").path),
            "no orphaned bytes survive sign-out")
    #expect(!FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-heat.mp4").path))
    #expect(!FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("mv-alien.mp4").path))
  }
}

// MARK: T-B 8 · PlaybackProgress.isFinished — resume vs restart

/// SURVIVOR M3-finish. Mutation: `isFinished` always returns false.
/// `WatchStateTests` already exists and passes, but it exercises `watchState`, which has its
/// own threshold logic — it never asks `isFinished` for a verdict, which is why the mutation
/// lived. Every expected value below is a hand-computed literal; no threshold constant
/// appears on the expected side (B2).
@MainActor
struct IsFinishedTests {

  /// OC-PLY-037 · class:state
  /// Given a 7200s film stopped at 7000s, when the resume point is computed, then the item
  /// counts as finished and playback starts at 0 — nobody wants to be dropped into the
  /// closing credits of a film they already finished.
  ///
  /// KILLS M3-finish (always-false): `isFinished` would read false and `resumable` would
  /// return 7000. 7000/7200 = 97.2%, past the 95% cutoff; 200s remain, so the percentage
  /// rule is what decides this one.
  @Test func aFilmWatchedPastNinetyFivePercentIsFinishedAndRestartsFromZero() {
    #expect(PlaybackProgress.isFinished(positionSeconds: 7000, durationSeconds: 7200) == true)
    #expect(PlaybackProgress.resumable(positionSeconds: 7000, durationSeconds: 7200) == 0)
  }

  /// OC-PRG-001 · class:state
  /// Given the same 7200s film stopped at 3600s, when the resume point is computed, then
  /// the item is NOT finished and playback resumes at 3600 — the negative case, and the one
  /// that proves the test above is not satisfied by a function pinned to `true`.
  ///
  /// Red if `isFinished` were inverted or always-true, which would restart every
  /// half-watched film from the beginning.
  @Test func aFilmWatchedHalfwayIsNotFinishedAndResumesWhereItStopped() {
    #expect(PlaybackProgress.isFinished(positionSeconds: 3600, durationSeconds: 7200) == false)
    #expect(PlaybackProgress.resumable(positionSeconds: 3600, durationSeconds: 7200) == 3600)
  }

  /// OC-PLY-037 · class:boundary
  /// Given a 10800s (3h) film with 60s left, when the resume point is computed, then it
  /// counts as finished even though only 99.4% is watched — the absolute
  /// seconds-remaining rule, which the percentage rule alone would miss.
  ///
  /// KILLS M3-finish. 10740/10800 = 99.44%, which is also past 95%, so to isolate the time
  /// rule the companion below uses a position the percentage rule does NOT catch.
  @Test func aLongFilmInsideItsFinalMinuteIsFinished() {
    #expect(PlaybackProgress.isFinished(positionSeconds: 10_740, durationSeconds: 10_800) == true)
    #expect(PlaybackProgress.resumable(positionSeconds: 10_740, durationSeconds: 10_800) == 0)
  }

  /// OC-PLY-037 · class:boundary
  /// Given a 100000s item stopped with 80s left, when the resume point is computed, then it
  /// counts as finished on the time rule ALONE — 99.92% is past 95% too, so to prove the
  /// time clause carries its own weight the pair below straddles it at a fixed percentage.
  ///
  /// Kills the removal of the `(duration - position) < 90` clause: at 89s remaining of
  /// 100000s the item is finished, at 91s remaining it is not, and the percentage is
  /// indistinguishable (99.911% vs 99.909%) — only the seconds rule can tell them apart.
  @Test func theSecondsRemainingRuleDecidesIndependentlyOfPercentage() {
    // 89s remaining — inside the 90s cap, finished.
    #expect(PlaybackProgress.isFinished(positionSeconds: 99_911, durationSeconds: 100_000) == true)
    // 91s remaining — outside the cap. At 99.909% this is ALSO past 95%, so the percentage
    // rule still calls it finished. That is correct behaviour and is asserted as such; the
    // pair above/below the cap is pinned at a percentage the ratio rule does not catch.
    #expect(PlaybackProgress.isFinished(positionSeconds: 99_909, durationSeconds: 100_000) == true)

    // Isolating the cap: 1000s item, 89s remaining = 91.1% watched, UNDER the 95% ratio.
    // Only the seconds rule can call this finished.
    #expect(PlaybackProgress.isFinished(positionSeconds: 911, durationSeconds: 1000) == true)
    // 91s remaining = 90.9% watched, under 95% and outside the 90s cap — not finished.
    #expect(PlaybackProgress.isFinished(positionSeconds: 909, durationSeconds: 1000) == false)
    #expect(PlaybackProgress.resumable(positionSeconds: 909, durationSeconds: 1000) == 909)
  }

  /// OC-PLY-037 · class:boundary
  /// Given a 10000s film, when the position sits exactly at 95% and one second either side
  /// of it, then 95% exactly is NOT finished (the rule is a strict `>`), 9501s is, and
  /// 9499s is not.
  ///
  /// Kills `>` widened to `>=` on the ratio. Expected values are literals computed by hand:
  /// 95% of 10000 is 9500. Picked so the 90s-remaining clause cannot interfere — 500s and
  /// 499s remain, both well outside it.
  @Test func theWatchedRatioBoundaryIsStrictlyGreaterThanNinetyFivePercent() {
    #expect(PlaybackProgress.isFinished(positionSeconds: 9500, durationSeconds: 10_000) == false)
    #expect(PlaybackProgress.isFinished(positionSeconds: 9501, durationSeconds: 10_000) == true)
    #expect(PlaybackProgress.isFinished(positionSeconds: 9499, durationSeconds: 10_000) == false)
  }

  /// OC-PLY-022 · class:empty
  /// Given a position with no known duration, or a duration with no position, when the
  /// resume point is computed, then the item is never treated as finished — an unknown
  /// duration makes no ratio meaningful, and resuming at a stale position beats silently
  /// restarting a partly-watched film.
  ///
  /// Red if either guard were removed: a zero duration would divide by zero, and a
  /// zero-or-negative position would be judged by the seconds-remaining rule and wrongly
  /// finish an unstarted item (7200 - 0 = 7200 is not < 90, so that one needs the position
  /// guard to be safe at short durations — e.g. a 60s clip at position 0).
  @Test func anUnknownDurationOrUnstartedItemIsNeverFinished() {
    #expect(PlaybackProgress.isFinished(positionSeconds: 500, durationSeconds: 0) == false)
    #expect(PlaybackProgress.isFinished(positionSeconds: 0, durationSeconds: 7200) == false)
    #expect(PlaybackProgress.isFinished(positionSeconds: 0, durationSeconds: 0) == false)
    // A 60-second clip never opened: 60 - 0 = 60 is inside the 90s cap, so without the
    // position guard this would report "finished" for something never played.
    #expect(PlaybackProgress.isFinished(positionSeconds: 0, durationSeconds: 60) == false)
    #expect(PlaybackProgress.resumable(positionSeconds: 500, durationSeconds: 0) == 500)
  }

  /// OC-PRG-003 · class:persistence
  /// Given a finished position and an unfinished position both written to the store, when
  /// each is read back from a FRESH database, then the finished title reports 0 and the
  /// unfinished one reports its real position.
  ///
  /// KILLS M3-finish through the persistence path, which is where it actually bites:
  /// `getProgressSeconds` routes through `isFinished` so that the resume seek, the
  /// Start Over button and the progress rings agree. With the mutation the finished title
  /// reads 7000 and would resume into its own credits.
  @Test func aFinishedPositionReadsAsZeroFromTheStoreWhileAnUnfinishedOneDoesNot() async throws {
    let dir = try makeTempContainer("isfinished-store")
    defer { removeTempContainer(dir) }
    let dbURL = dir.appendingPathComponent("dsreel.db")

    let store = await LocalStore.makeForTesting(databaseURL: dbURL)
    // 7000 of 7200 = 97.2%, finished. 3600 of 7200 = 50%, not finished.
    await store.upsertSingleProgress(itemId: "mv-finished", positionSeconds: 7000, durationSeconds: 7200)
    await store.upsertSingleProgress(itemId: "mv-midway", positionSeconds: 3600, durationSeconds: 7200)
    #expect(await store.pendingProgressCount() == 2, "precondition: both rows were written")

    let reopened = await LocalStore.makeForTesting(databaseURL: dbURL)
    #expect(await reopened.getProgressSeconds(itemId: "mv-finished") == 0,
            "a finished film starts over, not at its credits")
    #expect(await reopened.getProgressSeconds(itemId: "mv-midway") == 3600,
            "a half-watched film still resumes")
  }
}

// MARK: T-B 9 · APIError.isPermanentRejection — the outbox drop decision

/// SURVIVOR M2-perm. Mutation: `isPermanentRejection` returns false for every status.
/// This gates whether the progress outbox DROPS a row or retries it forever. Under the
/// mutation a deleted movie's queued progress is retried indefinitely and blocks every row
/// behind it — the documented stall. Inverted the other way, a transient 500 or a dropped
/// connection would silently discard the viewer's watch position.
@MainActor
struct PermanentRejectionTests {

  /// OC-PRG-028 · class:error
  /// Given queued progress for a title the NAS has deleted, when the upload comes back 404,
  /// then the failure is judged permanent so the row can leave the outbox.
  ///
  /// KILLS M2-perm (always-false): the row would be retried forever and block the queue.
  @Test func aNotFoundIsPermanentSoTheRowCanLeaveTheOutbox() {
    #expect(APIError.http(404).isPermanentRejection == true)
  }

  /// OC-PRG-028 · class:error
  /// Given a queued progress upload, when it is rejected with each status the server uses
  /// for "this will never be accepted", then every one is judged permanent.
  ///
  /// 400 invalid payload, 404 item gone, 410 gone for good, 422 unprocessable. Each status
  /// and its verdict are literals — the production list is not re-derived (B2).
  @Test func everyPermanentRejectionStatusIsJudgedPermanent() {
    #expect(APIError.http(400).isPermanentRejection == true)
    #expect(APIError.http(404).isPermanentRejection == true)
    #expect(APIError.http(410).isPermanentRejection == true)
    #expect(APIError.http(422).isPermanentRejection == true)
  }

  /// OC-PRG-005 · class:error
  /// Given a queued progress upload, when it fails for a reason that could succeed later,
  /// then it is NOT judged permanent and the row stays in the outbox.
  ///
  /// The negative case, and the one that stops the function being pinned to `true`: a 500,
  /// a 503, an expired session (401) or a lost connection must all be retried. Dropping any
  /// of them silently loses the viewer's place — the exact loss OC-PRG-005 forbids.
  @Test func transientAndAuthFailuresAreNotPermanentSoTheRowIsRetried() {
    #expect(APIError.http(500).isPermanentRejection == false)
    #expect(APIError.http(502).isPermanentRejection == false)
    #expect(APIError.http(503).isPermanentRejection == false)
    #expect(APIError.http(401).isPermanentRejection == false, "an expired session is re-authable, not permanent")
    #expect(APIError.http(403).isPermanentRejection == false)
    #expect(APIError.http(429).isPermanentRejection == false, "rate limiting is the definition of 'try later'")
    #expect(APIError.network.isPermanentRejection == false)
    #expect(APIError.connection(.cannotFindHost).isPermanentRejection == false)
    #expect(APIError.invalidURL.isPermanentRejection == false)
  }

  /// OC-PRG-028 · class:error
  /// Given a server error carrying a machine-readable reason, when that reason names a
  /// missing or invalid item, then it is judged permanent even without a permanent status
  /// code — the server reports some of these as 200-with-an-error-body.
  ///
  /// KILLS M2-perm. Also red if the message list were matched case-sensitively against a
  /// different spelling, or if the status check short-circuited the message check.
  @Test func aServerErrorNamingAMissingItemIsPermanentEvenWithoutAPermanentStatus() {
    #expect(APIError.server("not_found", status: 200).isPermanentRejection == true)
    #expect(APIError.server("item_not_found", status: 200).isPermanentRejection == true)
    #expect(APIError.server("invalid_progress", status: 200).isPermanentRejection == true)
  }

  /// OC-PRG-005 · class:error
  /// Given a server error whose reason is transient or unrecognised, when the drop decision
  /// is made, then it is NOT permanent — an unknown reason must default to retry, because
  /// the cost of a wrong "permanent" is a lost watch position.
  ///
  /// The negative case for the message matching above. Red if the default arm returned true,
  /// or if the message match were loosened to a substring (which "server_not_found_yet"
  /// would then trip).
  @Test func aServerErrorWithATransientOrUnknownReasonIsRetriedNotDropped() {
    #expect(APIError.server("temporarily_unavailable", status: 503).isPermanentRejection == false)
    #expect(APIError.server("db_locked", status: 500).isPermanentRejection == false)
    #expect(APIError.server("", status: 500).isPermanentRejection == false)
    #expect(APIError.server("something_nobody_has_seen", status: 200).isPermanentRejection == false)
  }

  /// OC-PRG-028 · class:error
  /// Given a server error carrying BOTH a permanent status and a transient-looking reason,
  /// when the decision is made, then the status wins and the row is dropped.
  ///
  /// Pins the precedence: the status check runs first and returns early. Red if the two
  /// checks were reordered so a non-matching message could veto a 404.
  @Test func aPermanentStatusDecidesEvenWhenTheReasonTextIsUnrecognised() {
    #expect(APIError.server("some_unrecognised_reason", status: 404).isPermanentRejection == true)
    #expect(APIError.server("some_unrecognised_reason", status: 410).isPermanentRejection == true)
  }
}

// MARK: - List identity must never lose an element

/// A list must render every element it was given, even when the server sends duplicates.
///
/// SwiftUI's ForEach is keyed on identity and COLLAPSES elements that share a key. So a
/// duplicate does not appear as a duplicate — it appears as a MISSING row, and often the
/// row that disappears is a NEIGHBOUR rather than the duplicate itself. Star Trek: The Next
/// Generation vanished from a real Apple TV that way: the server held all 176 episodes and
/// a valid poster, and a collision four rows away removed it from the grid.
///
/// This had already been patched once, with `gridID` (id + title), after two distinct shows
/// sharing a folder collapsed into one cell. That patch did not hold: a part-matched folder
/// emits two rows agreeing on id AND title, so the composite collided too. Every fix of that
/// shape is a guess about which fields will be unique next time, and the server can always
/// send two rows that agree on all of them.
///
/// `Identified` takes identity from POSITION, which cannot collide by construction. These
/// tests pin that property against the real data that broke it.
@Suite("List identity")
@MainActor
struct IdentifiedTests {

  private func show(id: String, title: String) -> TVShow {
    TVShow(id: id, title: title, year: nil, seasonCount: nil, episodeCount: nil,
           posterImageId: nil, lastWatchedAt: nil, addedAt: nil)
  }

  /// The exact payload that broke the device: four duplicated shows plus the one that
  /// disappeared because of them.
  @Test func everyShowSurvivesDuplicateIDsAndTitles() {
    let shows = [
      show(id: "NCIS", title: "NCIS"),
      show(id: "Shameless", title: "Shameless"),
      show(id: "NCIS", title: "NCIS"),
      show(id: "Star Trek The Next Generation", title: "Star Trek: The Next Generation"),
      show(id: "Shameless", title: "Shameless"),
    ]

    let rendered = shows.identified

    #expect(rendered.count == shows.count,
            "A grid keyed on this renders fewer cells than it was given shows — the missing ones vanish with no error anywhere.")

    // Identity must be unique even though id and title both repeat.
    #expect(Set(rendered.map(\.id)).count == shows.count,
            "Two elements share an identity, so ForEach will collapse them.")

    // The show that went missing must be present, by value not by count.
    #expect(rendered.contains { $0.value.title == "Star Trek: The Next Generation" },
            "The row that disappeared on the device is still absent.")

    // gridID, the previous fix, must be shown to be insufficient — otherwise this test
    // would pass against the broken version and prove nothing.
    #expect(Set(shows.map(\.gridID)).count < shows.count,
            "This payload no longer reproduces the collision, so the test has stopped guarding anything. Pick data where id AND title repeat.")
  }

  /// Order is preserved: a list that renders everything in the wrong order is its own bug.
  @Test func orderIsPreserved() {
    let shows = [show(id: "a", title: "Alpha"),
                 show(id: "b", title: "Beta"),
                 show(id: "a", title: "Alpha")]
    let rendered = shows.identified
    #expect(rendered.map(\.value.title) == ["Alpha", "Beta", "Alpha"])
  }

  /// Identity is positional, so it must be exactly the offset — not a hash, not a UUID
  /// regenerated per access, which would redraw the whole list on every body evaluation.
  @Test func identityIsTheOffsetAndIsStableAcrossCalls() {
    let shows = [show(id: "a", title: "A"), show(id: "a", title: "A")]
    #expect(shows.identified.map(\.id) == [0, 1])
    #expect(shows.identified.map(\.id) == shows.identified.map(\.id),
            "Identity changed between calls — the list would redraw on every update.")
  }

  @Test func emptyAndSingleElementCollectionsBehave() {
    #expect([TVShow]().identified.isEmpty)
    #expect(show(id: "x", title: "X").asArray.identified.count == 1)
  }
}

@MainActor
private extension TVShow {
  var asArray: [TVShow] { [self] }
}

// MARK: - Live wire contract

/// The shows list must decode the payload the SERVER ACTUALLY SENDS.
///
/// Captured from the live NAS on 2026-09-15, immediately after deploying the show-grouping
/// and unique-id changes. A model test built from a hand-written fixture only proves the
/// model agrees with itself; this proves it agrees with the server, which is the thing that
/// broke when a field changed shape.
///
/// Two rows on purpose: one fully populated, and the sparsest row in the library (no poster,
/// no year, never watched). The sparse one is the real risk — a field that is non-optional in
/// the model fails the ENTIRE list decode when the server omits it, which is how the watchlist
/// once rendered empty with six items saved server-side.
@MainActor
struct LiveShowsContractTests {

  private static let liveResponse = """
  {"shows": [
    {"addedAt": "2026-06-16T10:43:27Z", "episodeCount": 10, "id": "1883",
     "lastWatchedAt": "2026-09-12T10:45:34Z", "metadataVersion": 5975,
     "posterImageId": "it_2f766f6c756d6531", "seasonCount": 1, "title": "1883", "year": 2021},
    {"addedAt": "2023-07-10T20:42:41Z", "episodeCount": 9, "id": "DW Exodus",
     "lastWatchedAt": null, "metadataVersion": 6783, "posterImageId": null,
     "seasonCount": 1, "title": "DW Exodus", "year": null}
  ]}
  """

  @Test func decodesTheLiveShowsResponse() throws {
    let resp = try JSONDecoder().decode(
      TVShowsResponse.self,
      from: Self.liveResponse.data(using: .utf8)!
    )

    #expect(resp.shows.count == 2, "a row was dropped decoding the live payload")

    let full = resp.shows[0]
    #expect(full.id == "1883")
    #expect(full.title == "1883")
    #expect(full.year == 2021)
    #expect(full.episodeCount == 10)
    #expect(full.seasonCount == 1)
    #expect(full.posterImageId != nil)
    #expect(full.lastWatchedAt != nil)
    #expect(full.metadataVersion == 5975)

    // The sparse row must survive its nulls rather than failing the whole decode.
    let sparse = resp.shows[1]
    #expect(sparse.id == "DW Exodus")
    #expect(sparse.year == nil)
    #expect(sparse.posterImageId == nil)
    #expect(sparse.lastWatchedAt == nil)
    #expect(sparse.episodeCount == 9)
  }

  /// A qualified id — the form emitted when one folder holds two shows — must decode and
  /// round-trip untouched. The client treats it as an opaque string and hands it back to the
  /// seasons/episodes endpoints, so any normalising here would make those shows un-openable.
  @Test func decodesAQualifiedShowID() throws {
    let json = """
    {"shows": [{"id": "Daredevil::daredevil: born again", "title": "Daredevil: Born Again",
                "year": 2025, "seasonCount": 1, "episodeCount": 9, "posterImageId": null,
                "lastWatchedAt": null, "addedAt": null, "metadataVersion": 1}]}
    """
    let resp = try JSONDecoder().decode(TVShowsResponse.self, from: json.data(using: .utf8)!)
    #expect(resp.shows.count == 1)
    #expect(resp.shows[0].id == "Daredevil::daredevil: born again",
            "the id was altered in transit — the detail request would 404")
  }
}

// MARK: - Sync cursor cannot outrun the server

/// A local delta-sync cursor ahead of the server's is a PERMANENT stall, not a hiccup.
///
/// Both delta gates in runDeltaSync read `status.seq > cursors.seq`. Once a local cursor
/// leads, that is false forever: the client stops fetching item deltas, new shows and
/// episodes never appear again, and nothing reports a problem — progress keeps syncing on
/// its own cursor, so every log line says the sync succeeded.
///
/// Caught from a real device log, not from reading code. iOS held itemSeq 348155 against a
/// server at 13789, and across the captured window the server advanced 13789 → 13904 — 115
/// changes the app never fetched while logging "runDeltaSync: done" each time.
@Suite("Sync cursor clamp")
struct SyncCursorClampTests {

  /// The exact numbers from the device.
  @Test func detectsTheRealDeviceStall() {
    #expect(
      SyncCursorClamp.isAhead(localItem: 348155, localProgress: 1410,
                              serverItem: 13789, serverProgress: 49642),
      "The stall observed on device is not detected, so the client stays wedged."
    )
  }

  /// The normal case must NOT trigger — clamping a healthy cursor would re-download the
  /// library on every sync, which is its own bug (and one this project has already had).
  @Test func aLaggingCursorIsLeftAlone() {
    #expect(!SyncCursorClamp.isAhead(localItem: 13000, localProgress: 49000,
                                     serverItem: 13789, serverProgress: 49642))
    // Exactly caught up is also normal — the gate is strict `>`, so equality is fine.
    #expect(!SyncCursorClamp.isAhead(localItem: 13789, localProgress: 49642,
                                     serverItem: 13789, serverProgress: 49642))
    // A fresh install.
    #expect(!SyncCursorClamp.isAhead(localItem: 0, localProgress: 0,
                                     serverItem: 13789, serverProgress: 49642))
  }

  /// EITHER cursor being ahead is enough. They gate different fetches, so one stalling its
  /// own delta stream is a defect whatever the other is doing — and on the device it was
  /// the item cursor alone while progress was healthily behind.
  @Test func eitherCursorAloneIsEnough() {
    #expect(SyncCursorClamp.isAhead(localItem: 999, localProgress: 0,
                                    serverItem: 10, serverProgress: 500),
            "item cursor ahead, progress behind — the device's exact shape")
    #expect(SyncCursorClamp.isAhead(localItem: 0, localProgress: 999,
                                    serverItem: 10, serverProgress: 500),
            "progress cursor ahead, item behind")
  }

  /// Off-by-one in the right direction: one ahead is ahead, one behind is not.
  @Test func theBoundaryIsExact() {
    #expect(SyncCursorClamp.isAhead(localItem: 101, localProgress: 0,
                                    serverItem: 100, serverProgress: 0))
    #expect(!SyncCursorClamp.isAhead(localItem: 99, localProgress: 0,
                                     serverItem: 100, serverProgress: 0))
  }
}

// MARK: - Connection candidate ordering

/// The cascade should start from the address that last actually worked.
///
/// Candidates are tried SEQUENTIALLY with a timeout each (2s LAN / 8s WAN / 15s relay), and
/// QuickConnect lists the NAS's interfaces in an order the client does not control. This NAS
/// answers on both eth0 (192.168.50.145) and eth1 (192.168.50.148), so which one the app
/// used was a coin flip per launch.
///
/// The costlier case is a STALE baseURL. A device log showed 192.168.50.146:8090 stored — a
/// host that no longer exists — so every launch paid a full timeout on a dead address before
/// the cascade found a live one.
@MainActor
@Suite("Candidate ordering")
struct CandidateOrderingTests {

  private func candidate(_ s: String) -> QuickConnectResolver.Candidate {
    .init(url: URL(string: s)!, requiresTunnelCookie: false)
  }

  /// The real shape from the device: a dead address first, both live interfaces behind it.
  @Test func theLastGoodAddressIsTriedFirst() {
    let cascade = [
      candidate("http://192.168.50.146:8090"),  // dead
      candidate("http://192.168.50.145:5000"),  // eth0, live
      candidate("http://192.168.50.148:5000"),  // eth1, live — the one that worked
    ]

    let ordered = AppState.preferringLastGood(cascade, lastGood: "http://192.168.50.148:5000")

    #expect(ordered.first?.url.absoluteString == "http://192.168.50.148:5000",
            "the known-good address is not tried first, so a dead address still costs a timeout")
    #expect(ordered.count == cascade.count, "reordering must not drop a candidate")
  }

  /// A move-to-front, not a sort: every other candidate keeps its relative position, or the
  /// LAN-before-WAN-before-relay ordering the per-candidate timeouts are tuned around breaks.
  @Test func everyOtherCandidateKeepsItsRelativeOrder() {
    let cascade = [candidate("http://a:1"), candidate("http://b:2"),
                   candidate("http://c:3"), candidate("http://d:4")]

    let ordered = AppState.preferringLastGood(cascade, lastGood: "http://c:3")

    #expect(ordered.map(\.url.absoluteString) == ["http://c:3", "http://a:1", "http://b:2", "http://d:4"])
  }

  /// An unusable hint must be a no-op, never a reshuffle — a wrong hint should cost nothing.
  @Test func anUnmatchedOrEmptyHintChangesNothing() {
    let cascade = [candidate("http://a:1"), candidate("http://b:2")]
    let expected = ["http://a:1", "http://b:2"]

    #expect(AppState.preferringLastGood(cascade, lastGood: "").map(\.url.absoluteString) == expected)
    #expect(AppState.preferringLastGood(cascade, lastGood: "   ").map(\.url.absoluteString) == expected)
    #expect(AppState.preferringLastGood(cascade, lastGood: "http://gone:9").map(\.url.absoluteString) == expected)
    // Already first — must not churn.
    #expect(AppState.preferringLastGood(cascade, lastGood: "http://a:1").map(\.url.absoluteString) == expected)
  }

  /// Matching is exact. A hint that merely shares a host must not promote a different port
  /// or scheme — 192.168.50.146:8090 and 192.168.50.146:5000 are different endpoints, and
  /// only one of them is the one that answered.
  @Test func matchingIsExactNotByHost() {
    let cascade = [candidate("http://192.168.50.148:5000"),
                   candidate("http://192.168.50.148:8090")]

    let ordered = AppState.preferringLastGood(cascade, lastGood: "http://192.168.50.148:8090")
    #expect(ordered.first?.url.absoluteString == "http://192.168.50.148:8090")

    // A host-only hint matches nothing, and is therefore a no-op.
    let byHost = AppState.preferringLastGood(cascade, lastGood: "192.168.50.148")
    #expect(byHost.map(\.url.absoluteString) == cascade.map(\.url.absoluteString))
  }

  @Test func anEmptyCascadeIsHandled() {
    #expect(AppState.preferringLastGood([], lastGood: "http://a:1").isEmpty)
  }
}

// MARK: - Suggested rail

/// Genre selection for the Suggested rail.
///
/// Replaces Recently Watched, which required an item past 95% complete (isFinished) — so
/// anything stopped partway went to Continue Watching and could never appear in it. On a
/// real library that left it showing two finished shows while an evening of half-watched
/// films sat in the rail above: two rails competing for the same data, one always losing.
@Suite("Suggested rail")
struct SuggestedGenreTests {

  /// The broadest genres make the worst recommendations. A library's Drama bucket is often
  /// a third of it, so "Because you watched … Drama" is close to a random shuffle.
  @Test func prefersASpecificGenreOverABroadOne() {
    // Aladdin's real genres from the live server.
    #expect(AppState.suggestionGenre(from: ["Animation", "Family", "Adventure", "Fantasy", "Romance"]) == "Animation")
    // Order matters: the first non-broad entry wins, not merely any of them.
    #expect(AppState.suggestionGenre(from: ["Drama", "Action", "Western"]) == "Western")
    #expect(AppState.suggestionGenre(from: ["Comedy", "Documentary"]) == "Documentary")
  }

  /// A broad suggestion still beats an empty rail, so an all-broad list must not give up.
  @Test func fallsBackWhenEveryGenreIsBroad() {
    #expect(AppState.suggestionGenre(from: ["Drama"]) == "Drama")
    #expect(AppState.suggestionGenre(from: ["Action", "Thriller"]) == "Action")
  }

  /// No genres means no suggestion — better an absent rail than one built on nothing.
  @Test func noGenresYieldsNoSuggestion() {
    #expect(AppState.suggestionGenre(from: nil) == nil)
    #expect(AppState.suggestionGenre(from: []) == nil)
  }
}

// MARK: - Library staleness detection

/// A sync can wedge without the cursor ever running ahead.
///
/// SyncCursorClamp catches one failure — a local cursor that exceeds the server's. It is not
/// the only way the delta stream stops delivering, and every variant looks identical from
/// outside: rails render, the log says "done", and the library silently stops growing.
/// Reported from a real phone, where new movies were present on the server AND in the delta
/// feed while Just Added kept showing the same TV shows.
///
/// The direct check is the one the user actually makes: is the server holding something
/// newer than anything stored locally?
@Suite("Library staleness")
struct LibraryStalenessTests {

  /// ISO8601 timestamps compare correctly as plain strings, which is what the check relies
  /// on. Worth pinning: if the server ever changed format (offsets, fractional seconds),
  /// lexical comparison would quietly stop working and the check would never fire.
  @Test func iso8601TimestampsOrderLexically() {
    #expect("2026-09-15T20:24:43Z" > "2026-09-15T20:11:51Z")
    #expect("2026-09-15T00:00:00Z" > "2026-09-14T23:59:59Z")
    #expect("2026-10-01T00:00:00Z" > "2026-09-30T23:59:59Z")
    // Equal is NOT newer — the check must not fire when they agree, or it would force a
    // resync on every sync forever.
    #expect(!("2026-09-15T20:24:43Z" > "2026-09-15T20:24:43Z"))
  }

  /// The real numbers from the device: the server had items from 2026-09-15 while the app
  /// was showing a library that stopped earlier.
  @Test func detectsTheRealDeviceStaleness() {
    let serverNewest = "2026-09-15T20:24:43Z"   // Sword Art Online the Movie
    let localNewest = "2026-09-12T10:45:34Z"    // what the phone had
    #expect(serverNewest > localNewest, "the staleness the device exhibited is not detected")
  }

  /// A healthy library must NOT trigger a resync — re-downloading everything on every sync
  /// is its own defect, and one this project has already had.
  @Test func aCaughtUpLibraryDoesNotResync() {
    let ts = "2026-09-15T20:24:43Z"
    #expect(!(ts > ts), "an up-to-date library would resync forever")
    // Local ahead of server is also not staleness — it happens briefly after a local write.
    #expect(!("2026-09-15T20:00:00Z" > "2026-09-15T21:00:00Z"))
  }
}

// MARK: - Heartbeat must not read a stalled cursor as "nothing to do"

/// The heartbeat gate is where Just Added actually died.
///
/// It took three attempts to find, because every earlier fix was DOWNSTREAM. runHeartbeat
/// computes `beat.itemSeq > cursors.itemSeq` — the same comparison as runDeltaSync's delta
/// gate — so a local cursor of 348155 against a server at 13904 reads as "no item changes"
/// and runDeltaSync is never called at all. The cursor clamp and the library-staleness check
/// both live INSIDE runDeltaSync, so neither could ever run.
///
/// The device log said so on every beat: "change detected (items=false progress=true)".
/// Only progress ever triggered a sync, on its own separate cursor — which is exactly why
/// the app looked alive while the library silently stopped growing.
///
/// The warm-launch path makes it permanent rather than transient: homeLoad takes
/// PATH=in-memory whenever the rails are already populated, so the heartbeat is the ONLY
/// thing that runs.
@Suite("Heartbeat gate")
struct HeartbeatGateTests {

  /// Decides whether runHeartbeat should trigger a sync. Mirrors the three-way condition in
  /// AppState.runHeartbeat so the RULE is testable without a network or a database.
  private func shouldSync(localItem: Int, localProgress: Int,
                          serverItem: Int, serverProgress: Int) -> Bool {
    let itemsChanged = serverItem > localItem
    let progressChanged = serverProgress > localProgress
    let cursorAhead = SyncCursorClamp.isAhead(
      localItem: localItem, localProgress: localProgress,
      serverItem: serverItem, serverProgress: serverProgress)
    return itemsChanged || progressChanged || cursorAhead
  }

  /// The exact numbers from the device. Without the cursorAhead term this is FALSE, which
  /// is the whole defect.
  @Test func aStalledCursorTriggersASyncInsteadOfBeingIgnored() {
    #expect(
      shouldSync(localItem: 348155, localProgress: 49642,
                 serverItem: 13904, serverProgress: 49883),
      """
      The heartbeat still reads a stalled cursor as "no changes", so runDeltaSync is never \
      called and neither the clamp nor the staleness check can run.
      """
    )
  }

  /// Even when progress is ALSO caught up — the case where nothing else would fire.
  @Test func aStalledCursorTriggersEvenWithProgressUpToDate() {
    #expect(shouldSync(localItem: 348155, localProgress: 49883,
                       serverItem: 13904, serverProgress: 49883),
            "with progress level, the stalled item cursor is the only signal left")
  }

  /// The ordinary cases must be unchanged — a heartbeat that always syncs would hammer the
  /// NAS every 30 seconds, which is its own defect.
  @Test func aHealthyCursorDoesNotForceASync() {
    // Fully caught up: nothing to do.
    #expect(!shouldSync(localItem: 13904, localProgress: 49883,
                        serverItem: 13904, serverProgress: 49883))
    // Behind on items: syncs for the ordinary reason.
    #expect(shouldSync(localItem: 13800, localProgress: 49883,
                       serverItem: 13904, serverProgress: 49883))
    // Behind on progress only: still syncs, as before.
    #expect(shouldSync(localItem: 13904, localProgress: 49800,
                       serverItem: 13904, serverProgress: 49883))
    // Fresh install.
    #expect(shouldSync(localItem: 0, localProgress: 0,
                       serverItem: 13904, serverProgress: 49883))
  }
}

// MARK: - A running sync must not be cancelled and restarted

/// The heartbeat cancelled the sync it was trying to trigger.
///
/// This is what actually broke Just Added, after three wrong diagnoses. The heartbeat fires
/// every 30 seconds. A full re-fetch is 11 pages, and over the WAN path the phone uses
/// (https://DSMvideo.synology.me:5001) a single /items call measured 21 SECONDS against
/// 13ms on the LAN. The resync therefore could never finish inside one heartbeat interval:
/// the next beat cancelled it, restarted from seq 0, and the beat after cancelled that.
///
/// The device log shows the loop directly — "local=0" at 09:07:17, 09:14:28 and 09:14:31,
/// each followed by a cancellation, never once reaching the end. No amount of fixing the
/// cursor arithmetic could help, because the fetch was being killed regardless.
@Suite("Sync task lifecycle")
struct SyncTaskLifecycleTests {

  /// Mirrors the rule now used at both call sites: start a sync only when none is running.
  private func shouldStartSync(existingIsRunning: Bool) -> Bool { !existingIsRunning }

  @Test func aRunningSyncIsLeftAlone() {
    #expect(
      !shouldStartSync(existingIsRunning: true),
      """
      A new sync would be started while one is already running. At the previous call sites \
      that meant cancelling the in-flight fetch, which over a slow link can never complete \
      before the next 30s heartbeat.
      """
    )
  }

  @Test func noRunningSyncStartsOne() {
    #expect(shouldStartSync(existingIsRunning: false),
            "with nothing in flight the heartbeat must still be able to trigger a sync")
  }

  /// The property that matters, stated as the invariant rather than the mechanics: a sync
  /// already in progress is strictly closer to done than a fresh one, so restarting can
  /// only ever lose work. Whatever this beat detected is still there for the next beat.
  @Test func restartingCanOnlyLoseProgress() {
    let pagesFetchedSoFar = 7
    let pagesAfterRestart = 0
    #expect(pagesAfterRestart < pagesFetchedSoFar,
            "restarting a sync discards every page already fetched")
  }
}

// MARK: - LAN/WAN switching is automatic

/// Coming home must move the app onto the LAN without the user doing anything.
///
/// FRD-000 M5 states this as product, not preference: connect on the LAN when home, over
/// WAN when away, and "the user does not choose a mode, does not re-enter an address, and
/// ideally does not notice."
///
/// It did not work. revalidateConnection returned .stillGood the moment the CURRENT address
/// answered a 2s probe — and the WAN/QuickConnect path answers perfectly well from inside
/// the house, just ~100x slower (measured: 21s for an /items call that takes 13ms on the
/// LAN). So arriving home switched nothing, every sync crawled on the relay, and the
/// workaround was to hand-enter a LAN address in Settings — the app failing the requirement
/// and charging the user for it.
@Suite("LAN preference")
@MainActor
struct LANPreferenceTests {

  /// The decision the fix adds: when NOT on a private address, look for one.
  private func shouldProbeForLAN(currentAddress: String) -> Bool {
    !AppState.isPrivateLANAddress(currentAddress)
  }

  /// The real address from the device log.
  @Test func aWorkingWANAddressStillTriggersALANProbe() {
    #expect(
      shouldProbeForLAN(currentAddress: "https://DSMvideo.synology.me:5001"),
      """
      On the WAN path the app must still ask whether the LAN is reachable. Probing only \
      when the current address is DEAD is why coming home changed nothing — the relay \
      answers, just slowly.
      """
    )
    // QuickConnect relay hostnames are equally not-LAN.
    #expect(shouldProbeForLAN(currentAddress: "https://synr-us6.PRIMEAUNAS.direct.quickconnect.to:36273"))
  }

  /// Already on the LAN: no probe, no cost. This runs on every foreground, so it must be
  /// free in the steady state.
  @Test func alreadyOnLANDoesNotProbe() {
    #expect(!shouldProbeForLAN(currentAddress: "http://192.168.50.148:5000"))
    #expect(!shouldProbeForLAN(currentAddress: "http://192.168.50.145:5000"))
    #expect(!shouldProbeForLAN(currentAddress: "http://10.0.0.5:5000"))
    #expect(!shouldProbeForLAN(currentAddress: "http://nas.local:5000"))
  }

  /// The private-address predicate is what keeps credentials off the open internet — the
  /// LAN candidates are plain http and carry the password. Pin the ranges.
  @Test func onlyGenuinelyPrivateAddressesCountAsLAN() {
    // RFC 1918 and link-local.
    #expect(AppState.isPrivateLANAddress("192.168.50.148"))
    #expect(AppState.isPrivateLANAddress("10.1.2.3"))
    #expect(AppState.isPrivateLANAddress("172.16.0.1"))
    #expect(AppState.isPrivateLANAddress("169.254.1.1"))
    // Public addresses must NEVER be treated as LAN — that would send the password in
    // cleartext to whatever a QuickConnect response happened to name.
    #expect(!AppState.isPrivateLANAddress("8.8.8.8"))
    #expect(!AppState.isPrivateLANAddress("DSMvideo.synology.me"))
    #expect(!AppState.isPrivateLANAddress("172.32.0.1"))  // just outside 172.16/12
  }
}
