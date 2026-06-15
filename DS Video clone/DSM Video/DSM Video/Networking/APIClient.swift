import Foundation

struct APIClient {
  let baseURL: URL
  let token: String?
  /// When true, adds `Cookie: type=tunnel` to every request — required for QuickConnect relay mode.
  var usesTunnelCookie: Bool = false

  func login(username: String, password: String, timeoutInterval: TimeInterval = 60) async throws -> LoginResponse {
    let req = LoginRequest(username: username, password: password, otp: nil)
    return try await request(
      path: "/api/v1/auth/login",
      method: "POST",
      body: req,
      response: LoginResponse.self,
      authorized: false,
      timeoutInterval: timeoutInterval
    )
  }

  func libraries() async throws -> LibrariesResponse {
    try await request(path: "/api/v1/libraries", method: "GET", body: Optional<Int>.none, response: LibrariesResponse.self, timeoutInterval: 15)
  }

  func items(libraryId: String, limit: Int = 50, offset: Int = 0) async throws -> ItemsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/items"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [
      URLQueryItem(name: "libraryId", value: libraryId),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    guard let url = comps.url else {
      throw APIError.invalidURL
    }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: ItemsResponse.self, timeoutInterval: 120)
  }

  func search(query: String, limit: Int = 50, offset: Int = 0) async throws -> ItemsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/search"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    guard let url = comps.url else {
      throw APIError.invalidURL
    }
    return try await requestWithRetry(url: url, method: "GET", body: Optional<Int>.none, response: ItemsResponse.self, timeoutInterval: 15)
  }

  func tvShows(libraryId: String) async throws -> TVShowsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/tv/shows"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [URLQueryItem(name: "libraryId", value: libraryId)]
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await requestWithRetry(url: url, method: "GET", body: Optional<Int>.none, response: TVShowsResponse.self, timeoutInterval: 15)
  }

  func tvShowSeasons(showId: String, libraryId: String) async throws -> TVSeasonsResponse {
    guard let encodedId = showId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      throw APIError.invalidURL
    }
    var comps = URLComponents()
    comps.scheme = baseURL.scheme
    comps.host = baseURL.host
    comps.port = baseURL.port
    comps.percentEncodedPath = "/api/v1/tv/shows/\(encodedId)/seasons"
    comps.queryItems = [URLQueryItem(name: "libraryId", value: libraryId)]
    guard let url = comps.url else { throw APIError.invalidURL }
    // TASK-655/675: explicit 15s timeout (was defaulting to 60s) so a slow NAS
    // fails fast instead of hanging the season list.
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: TVSeasonsResponse.self, timeoutInterval: 15)
  }

  func tvShowEpisodes(showId: String, season: Int, libraryId: String) async throws -> ItemsResponse {
    guard let encodedId = showId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      throw APIError.invalidURL
    }
    var comps = URLComponents()
    comps.scheme = baseURL.scheme
    comps.host = baseURL.host
    comps.port = baseURL.port
    comps.percentEncodedPath = "/api/v1/tv/shows/\(encodedId)/episodes"
    comps.queryItems = [
      URLQueryItem(name: "libraryId", value: libraryId),
      URLQueryItem(name: "season", value: String(season)),
    ]
    guard let url = comps.url else { throw APIError.invalidURL }
    // TASK-655/675: explicit 15s timeout (was defaulting to 60s).
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: ItemsResponse.self, timeoutInterval: 15)
  }

  func itemDetail(id: String) async throws -> ItemDetail {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try await requestWithRetry(path: "/api/v1/items/\(enc)", method: "GET", body: Optional<Int>.none, response: ItemDetail.self, timeoutInterval: 15)
  }

  func playback(id: String, quality: String = "auto", subtitleOffset: Double = 0) async throws -> PlaybackInfo {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/items/\(enc)/playback"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    var queryItems: [URLQueryItem] = []
    if quality != "auto" { queryItems.append(URLQueryItem(name: "quality", value: quality)) }
    if subtitleOffset != 0 { queryItems.append(URLQueryItem(name: "subtitleOffset", value: String(format: "%.3f", subtitleOffset))) }
    if !queryItems.isEmpty { comps.queryItems = queryItems }
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: PlaybackInfo.self, timeoutInterval: 15)
  }

  func setProgress(id: String, positionSeconds: Int, durationSeconds: Int) async throws {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    _ = try await request(
      path: "/api/v1/items/\(enc)/progress",
      method: "POST",
      body: ProgressRequest(positionSeconds: positionSeconds, durationSeconds: durationSeconds, state: "playing"),
      response: ProgressResponse.self
    )
  }

  func progressBatch(ids: [String]) async throws -> ProgressBatchResponse {
    guard !ids.isEmpty else { return ProgressBatchResponse(progress: [:]) }
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/progress"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
    guard let url = comps.url else { throw APIError.invalidURL }
    // Short timeout: progress data is non-critical. Fail fast so cached content
    // shows immediately rather than blocking for the default 60-second timeout.
    return try await request(url: url, method: "GET", body: Optional<Int>.none,
                             response: ProgressBatchResponse.self, timeoutInterval: 8)
  }

  /// Fetches all progress rows for the authenticated user in a single request.
  /// Prefer this over progressBatch for home-screen refresh — avoids N×chunked requests.
  func progressAll() async throws -> ProgressBatchResponse {
    try await request(path: "/api/v1/progress/all", method: "GET", body: Optional<Int>.none,
                      response: ProgressBatchResponse.self, timeoutInterval: 15)
  }

  // MARK: - TMDb Manual Fix

  func tmdbSearch(itemId: String, query: String? = nil, year: Int? = nil, type: String? = nil) async throws -> TMDbSearchResponse {
    let enc = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/items/\(enc)/tmdb-search"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    var queryItems: [URLQueryItem] = []
    if let q = query, !q.isEmpty { queryItems.append(URLQueryItem(name: "q", value: q)) }
    if let y = year { queryItems.append(URLQueryItem(name: "year", value: String(y))) }
    if let t = type { queryItems.append(URLQueryItem(name: "type", value: t)) }
    comps.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: TMDbSearchResponse.self)
  }

  func tmdbFix(itemId: String, tmdbId: Int, type: String) async throws {
    struct Body: Encodable { let tmdbId: Int; let type: String }
    let enc = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
    _ = try await request(
      path: "/api/v1/items/\(enc)/tmdb-fix",
      method: "POST",
      body: Body(tmdbId: tmdbId, type: type),
      response: EmptyDecodable.self
    )
  }

  func tvShowTMDbSearch(showId: String, query: String? = nil) async throws -> TMDbSearchResponse {
    guard let encodedId = showId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      throw APIError.invalidURL
    }
    var comps = URLComponents()
    comps.scheme = baseURL.scheme
    comps.host = baseURL.host
    comps.port = baseURL.port
    comps.percentEncodedPath = "/api/v1/tv/shows/\(encodedId)/tmdb-search"
    if let q = query, !q.isEmpty {
      comps.queryItems = [URLQueryItem(name: "q", value: q)]
    }
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: TMDbSearchResponse.self)
  }

  func tvShowTMDbFix(showId: String, tmdbId: Int) async throws {
    struct Body: Encodable { let tmdbId: Int }
    guard let encodedId = showId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      throw APIError.invalidURL
    }
    var comps = URLComponents()
    comps.scheme = baseURL.scheme
    comps.host = baseURL.host
    comps.port = baseURL.port
    comps.percentEncodedPath = "/api/v1/tv/shows/\(encodedId)/tmdb-fix"
    guard let url = comps.url else { throw APIError.invalidURL }
    _ = try await request(url: url, method: "POST", body: Body(tmdbId: tmdbId), response: EmptyDecodable.self)
  }

  func imageURL(id: String, width: Int? = nil, version: Int? = nil) -> URL? {
    guard baseURL != AppState.fallbackURL else { return nil }
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/images/\(id)"), resolvingAgainstBaseURL: false) else {
      return nil
    }
    var items: [URLQueryItem] = []
    if let width { items.append(URLQueryItem(name: "w", value: String(width))) }
    if let version { items.append(URLQueryItem(name: "v", value: String(version))) }
    if !items.isEmpty { comps.queryItems = items }
    return comps.url
  }

  /// TASK-740: base URL for an item's trick-play assets. The player appends
  /// "trickplay.vtt"/"trickplay.jpg". Returns nil when the server isn't resolved.
  func trickplayBaseURL(itemID: String) -> URL? {
    guard baseURL != AppState.fallbackURL else { return nil }
    return baseURL.appendingPathComponent("/api/v1/trickplay/\(itemID)")
  }

  // MARK: - Delta Sync

  func serverVersion(timeout: TimeInterval = 5) async throws -> ServerVersion {
    try await request(path: "/api/v1/version", method: "GET", body: Optional<Int>.none,
                      response: ServerVersion.self, authorized: false, timeoutInterval: timeout)
  }

  func syncStatus(timeout: TimeInterval = 10) async throws -> SyncStatusResponse {
    try await request(path: "/api/v1/sync/status", method: "GET", body: Optional<Int>.none,
                      response: SyncStatusResponse.self, timeoutInterval: timeout)
  }

  func syncHeartbeat() async throws -> SyncHeartbeatResponse {
    // authorized: true — heartbeat is user-scoped; Bearer token required (TASK-429).
    try await request(path: "/api/v1/sync/heartbeat", method: "GET", body: Optional<Int>.none,
                      response: SyncHeartbeatResponse.self, authorized: true, timeoutInterval: 5)
  }

  func syncItems(since: Int, limit: Int = 500, afterRowid: Int? = nil) async throws -> SyncItemsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/sync/items"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    var queryItems = [
      URLQueryItem(name: "since", value: String(since)),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let r = afterRowid { queryItems.append(URLQueryItem(name: "afterRowid", value: String(r))) }
    comps.queryItems = queryItems
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none,
                             response: SyncItemsResponse.self, timeoutInterval: 30)
  }

  func syncDeleted(since: Int) async throws -> SyncDeletedResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/sync/deleted"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [URLQueryItem(name: "since", value: String(since))]
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none,
                             response: SyncDeletedResponse.self, timeoutInterval: 10)
  }

  func refreshToken() async throws -> LoginResponse {
    try await request(path: "/api/v1/auth/refresh", method: "POST", body: Optional<Int>.none,
                      response: LoginResponse.self, timeoutInterval: 10)
  }

  func generatePairingCode() async throws -> PairingCodeResponse {
    try await request(path: "/api/v1/auth/pairing/generate", method: "POST", body: Optional<Int>.none, response: PairingCodeResponse.self)
  }

  func exchangePairingCode(code: String, timeoutInterval: TimeInterval = 60) async throws -> LoginResponse {
    let req = PairingCodeExchangeRequest(code: code)
    return try await request(
      path: "/api/v1/auth/pairing/exchange",
      method: "POST",
      body: req,
      response: LoginResponse.self,
      authorized: false,
      timeoutInterval: timeoutInterval
    )
  }

  // MARK: - Watchlist

  func watchlist() async throws -> ItemsResponse {
    try await requestWithRetry(path: "/api/v1/watchlist", method: "GET", body: Optional<Int>.none,
                               response: ItemsResponse.self, timeoutInterval: 15)
  }

  func addToWatchlist(id: String) async throws {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    _ = try await request(path: "/api/v1/watchlist/\(enc)", method: "POST",
                          body: Optional<Int>.none, response: EmptyDecodable.self)
  }

  func removeFromWatchlist(id: String) async throws {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    _ = try await request(path: "/api/v1/watchlist/\(enc)", method: "DELETE",
                          body: Optional<Int>.none, response: EmptyDecodable.self)
  }

  func isInWatchlist(id: String) async throws -> Bool {
    struct Resp: Decodable { let inWatchlist: Bool }
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    let resp = try await request(path: "/api/v1/watchlist/\(enc)", method: "GET",
                                 body: Optional<Int>.none, response: Resp.self)
    return resp.inWatchlist
  }

  // MARK: - core

  /// Retry wrapper for transient network errors (timeout, connection lost).
  /// Retries once after a 1-second delay. Does NOT retry on 4xx/5xx — those are
  /// caller errors that won't improve with a retry.
  private func requestWithRetry<T: Decodable, B: Encodable>(
    path: String,
    method: String,
    body: B?,
    response: T.Type,
    authorized: Bool = true,
    timeoutInterval: TimeInterval = 60
  ) async throws -> T {
    let url = baseURL.appendingPathComponent(path)
    return try await requestWithRetry(url: url, method: method, body: body, response: response, authorized: authorized, timeoutInterval: timeoutInterval)
  }

  private func requestWithRetry<T: Decodable, B: Encodable>(
    url: URL,
    method: String,
    body: B?,
    response: T.Type,
    authorized: Bool = true,
    timeoutInterval: TimeInterval = 60
  ) async throws -> T {
    do {
      return try await request(url: url, method: method, body: body, response: response, authorized: authorized, timeoutInterval: timeoutInterval)
    } catch let urlError as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(urlError.code) {
      try await Task.sleep(nanoseconds: 1_000_000_000)
      return try await request(url: url, method: method, body: body, response: response, authorized: authorized, timeoutInterval: timeoutInterval)
    }
  }

  private func request<T: Decodable, B: Encodable>(
    path: String,
    method: String,
    body: B?,
    response: T.Type,
    authorized: Bool = true,
    timeoutInterval: TimeInterval = 60
  ) async throws -> T {
    let url = baseURL.appendingPathComponent(path)
    return try await request(url: url, method: method, body: body, response: response, authorized: authorized, timeoutInterval: timeoutInterval)
  }

  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()

  private func request<T: Decodable, B: Encodable>(
    url: URL,
    method: String,
    body: B?,
    response: T.Type,
    authorized: Bool = true,
    timeoutInterval: TimeInterval = 60
  ) async throws -> T {
    var req = URLRequest(url: url, timeoutInterval: timeoutInterval)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if authorized, let token {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if usesTunnelCookie {
      req.setValue("type=tunnel", forHTTPHeaderField: "Cookie")
    }
    if let body {
      req.httpBody = try Self.encoder.encode(body)
    }

    let (data, httpResp) = try await URLSession.shared.data(for: req)
    guard let httpResp = httpResp as? HTTPURLResponse else {
      throw APIError.network
    }
    if !(200...299).contains(httpResp.statusCode) {
      if let apiErr = try? Self.decoder.decode(APIErrorResponse.self, from: data) {
        throw APIError.server(apiErr.error)
      }
      throw APIError.http(httpResp.statusCode)
    }
    return try Self.decoder.decode(T.self, from: data)
  }
}

enum APIError: Error {
  case network
  case http(Int)
  case server(String)
  case invalidURL

  var userMessage: String {
    switch self {
    case .network: return "Network error."
    case .http(let code): return "Server error (\(code))."
    case .server(let msg):
      // Map known server error codes to friendly, actionable text.
      switch msg {
      case "permission_denied":
        return "Your account isn't allowed to use this app. Ask the server owner to grant you access in DSM → Control Panel → Application Privileges."
      case "invalid_credentials":
        return "Incorrect username or password."
      case "account_disabled":
        return "This account is disabled. Ask the server owner to enable it."
      default:
        return msg.replacingOccurrences(of: "_", with: " ")
      }
    case .invalidURL: return "Invalid server URL."
    }
  }

  /// True when the failure came back from the server itself (it was reached and
  /// answered), as opposed to a connectivity/DNS/resolution miss. Used so the
  /// login flow surfaces a real auth error instead of a generic "couldn't find".
  var serverReached: Bool {
    switch self {
    case .server, .http: return true
    case .network, .invalidURL: return false
    }
  }
}

struct APIErrorResponse: Decodable {
  let error: String
}

/// Used as a placeholder response type for endpoints that return any JSON but whose value we discard.
struct EmptyDecodable: Decodable {}

