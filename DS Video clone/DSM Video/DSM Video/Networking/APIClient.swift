import Foundation

struct APIClient {
  let baseURL: URL
  let token: String?
  var tmdbAPIKey: String? = nil

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
    if let tmdbAPIKey {
      req.setValue(tmdbAPIKey, forHTTPHeaderField: "X-TMDb-API-Key")
    }
    if let body {
      req.httpBody = try JSONEncoder().encode(body)
    }

    let (data, httpResp) = try await URLSession.shared.data(for: req)
    guard let httpResp = httpResp as? HTTPURLResponse else {
      throw APIError.network
    }
    if !(200...299).contains(httpResp.statusCode) {
      if let apiErr = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
        throw APIError.server(apiErr.error)
      }
      throw APIError.http(httpResp.statusCode)
    }
    return try JSONDecoder().decode(T.self, from: data)
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

