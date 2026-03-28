import Foundation

struct APIClient {
  let baseURL: URL
  let token: String?

  func login(username: String, password: String) async throws -> LoginResponse {
    let req = LoginRequest(username: username, password: password, otp: nil)
    return try await request(
      path: "/api/v1/auth/login",
      method: "POST",
      body: req,
      response: LoginResponse.self,
      authorized: false
    )
  }

  func libraries() async throws -> LibrariesResponse {
    try await request(path: "/api/v1/libraries", method: "GET", body: Optional<Int>.none, response: LibrariesResponse.self)
  }

  /// One-request change detection: returns count + lastUpdatedAt per library.
  /// The client compares these against its cache to decide which libraries need re-fetching.
  func librariesSummary() async throws -> LibrarySummariesResponse {
    try await request(path: "/api/v1/libraries/summary", method: "GET", body: Optional<Int>.none, response: LibrarySummariesResponse.self)
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
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: ItemsResponse.self)
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
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: ItemsResponse.self)
  }

  func tvShows(libraryId: String = "lib_tv") async throws -> TVShowsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/tv/shows"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [URLQueryItem(name: "libraryId", value: libraryId)]
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: TVShowsResponse.self)
  }

  func tvShowSeasons(showId: String, libraryId: String = "lib_tv") async throws -> TVSeasonsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/tv/shows/\(showId)/seasons"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [URLQueryItem(name: "libraryId", value: libraryId)]
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: TVSeasonsResponse.self)
  }

  func tvShowEpisodes(showId: String, season: Int, libraryId: String = "lib_tv") async throws -> ItemsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/tv/shows/\(showId)/episodes"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [
      URLQueryItem(name: "libraryId", value: libraryId),
      URLQueryItem(name: "season", value: String(season)),
    ]
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: ItemsResponse.self)
  }

  func itemDetail(id: String) async throws -> ItemDetail {
    try await request(path: "/api/v1/items/\(id)", method: "GET", body: Optional<Int>.none, response: ItemDetail.self)
  }

  func playback(id: String) async throws -> PlaybackInfo {
    try await request(path: "/api/v1/items/\(id)/playback", method: "GET", body: Optional<Int>.none, response: PlaybackInfo.self)
  }

  func setProgress(id: String, positionSeconds: Int, durationSeconds: Int) async throws {
    _ = try await request(
      path: "/api/v1/items/\(id)/progress",
      method: "POST",
      body: ProgressRequest(positionSeconds: positionSeconds, durationSeconds: durationSeconds, state: "playing"),
      response: ProgressResponse.self
    )
  }

  // MARK: - TMDb Manual Fix

  func tmdbSearch(itemId: String, query: String? = nil, year: Int? = nil, type: String? = nil) async throws -> TMDbSearchResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/items/\(itemId)/tmdb-search"), resolvingAgainstBaseURL: false) else {
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
    _ = try await request(
      path: "/api/v1/items/\(itemId)/tmdb-fix",
      method: "POST",
      body: Body(tmdbId: tmdbId, type: type),
      response: EmptyDecodable.self
    )
  }

  func tvShowTMDbSearch(showId: String, query: String? = nil) async throws -> TMDbSearchResponse {
    guard let encodedId = showId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      throw APIError.invalidURL
    }
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/tv/shows/\(encodedId)/tmdb-search"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
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
    _ = try await request(
      path: "/api/v1/tv/shows/\(encodedId)/tmdb-fix",
      method: "POST",
      body: Body(tmdbId: tmdbId),
      response: EmptyDecodable.self
    )
  }

  func imageURL(id: String, width: Int? = nil) -> URL? {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/images/\(id)"), resolvingAgainstBaseURL: false) else {
      return nil
    }
    if let width {
      comps.queryItems = [URLQueryItem(name: "w", value: String(width))]
    }
    return comps.url
  }

  func generatePairingCode() async throws -> PairingCodeResponse {
    try await request(path: "/api/v1/auth/pairing/generate", method: "POST", body: Optional<Int>.none, response: PairingCodeResponse.self)
  }

  func exchangePairingCode(code: String) async throws -> LoginResponse {
    let req = PairingCodeExchangeRequest(code: code)
    return try await request(
      path: "/api/v1/auth/pairing/exchange",
      method: "POST",
      body: req,
      response: LoginResponse.self,
      authorized: false
    )
  }

  // MARK: - core

  private func request<T: Decodable, B: Encodable>(
    path: String,
    method: String,
    body: B?,
    response: T.Type,
    authorized: Bool = true
  ) async throws -> T {
    let url = baseURL.appendingPathComponent(path)
    return try await request(url: url, method: method, body: body, response: response, authorized: authorized)
  }

  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()

  private func request<T: Decodable, B: Encodable>(
    url: URL,
    method: String,
    body: B?,
    response: T.Type,
    authorized: Bool = true
  ) async throws -> T {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if authorized, let token {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
    case .server(let msg): return msg.replacingOccurrences(of: "_", with: " ")
    case .invalidURL: return "Invalid server URL."
    }
  }
}

struct APIErrorResponse: Decodable {
  let error: String
}

/// Used as a placeholder response type for endpoints that return any JSON but whose value we discard.
struct EmptyDecodable: Decodable {}

