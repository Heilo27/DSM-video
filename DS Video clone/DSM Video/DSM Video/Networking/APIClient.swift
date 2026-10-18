import Foundation

struct APIClient {
  let baseURL: URL
  let token: String?
  /// When true, adds `Cookie: type=tunnel` to every request — required for QuickConnect relay mode.
  var usesTunnelCookie: Bool = false
  /// Where `X-DSVideo-Profile` comes from (FR-220). The default reads ActiveProfileStore at
  /// the moment each request is built, so the ~dozen places that construct an APIClient
  /// never carry a profile id that can go stale. Work that must stay with ONE profile even
  /// if the user switches mid-flight (progress sync, the outbox) pins it with `pinned(to:)`.
  var profileHeader: ProfileHeaderSource = .activeProfile
  /// The store `.activeProfile` reads. Always `.shared` in production; AppState hands every
  /// client its own `profileStore`, which is how a test isolates the profile header (TASK-925).
  var profileStore: ActiveProfileStore = .shared

  /// A copy whose requests always name `profileID` (nil = send no header).
  func pinned(to profileID: String?) -> APIClient {
    var copy = self
    copy.profileHeader = .pinned(profileID)
    return copy
  }

  /// Request timeout tiers.
  ///
  /// These used to be bare literals scattered per call site, with an implicit 60s default on
  /// `request`/`requestWithRetry` that silently applied to any call not specifying one — so
  /// `setProgress` (called from the player and the outbox flush) could hang for a full minute
  /// while `progressBatch`, the same subsystem, used 8s. And `/items` sat at 120s while
  /// `/search` used 15s for an equivalent query against the same table, an 8x spread with no
  /// justification: on a cold NAS database search failed while items waited two minutes.
  ///
  /// `nonisolated` is required, not cosmetic. The project builds with
  /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, which would make these constants
  /// MainActor-isolated — but they are used as *default parameter values*, and
  /// those are evaluated in a nonisolated context at each call site. Under Swift 5
  /// that is a warning; newer toolchains (and Xcode Cloud) promote it to an error.
  /// These are plain compile-time constants with no shared mutable state, so
  /// opting them out of isolation is correct rather than a workaround.
  nonisolated enum Timeout {
    /// Fire-and-forget writes. Failure is recoverable — the outbox retries.
    static let write: TimeInterval = 8
    /// Interactive reads. The user is looking at a spinner.
    static let interactive: TimeInterval = 20
    /// Bulk reads that legitimately take longer on a cold database (full library pages).
    static let bulk: TimeInterval = 45
    /// Authentication. Deliberately generous — the candidate ladder above already imposes
    /// its own much shorter per-candidate timeouts.
    static let auth: TimeInterval = 30
    /// Liveness probes. Must fail fast; a slow probe blocks the reconnect loop.
    static let probe: TimeInterval = 5
  }

  func login(username: String, password: String, timeoutInterval: TimeInterval = Timeout.auth) async throws -> LoginResponse {
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

  /// Revokes this token server-side. Best-effort: the local sign-out must not depend on it.
  ///
  /// POST /auth/logout existed with ZERO callers, so signing out cleared the device but left
  /// the bearer token valid on the server until it expired — a stolen or shared-device token
  /// kept working after the user thought they had signed out.
  func logout(timeoutInterval: TimeInterval = 8) async throws {
    _ = try await request(
      path: "/api/v1/auth/logout",
      method: "POST",
      body: Optional<Int>.none,
      response: ProgressResponse.self,   // server returns {"ok":true}
      timeoutInterval: timeoutInterval
    )
  }

  func libraries() async throws -> LibrariesResponse {
    try await request(path: "/api/v1/libraries", method: "GET", body: Optional<Int>.none, response: LibrariesResponse.self, timeoutInterval: 15)
  }

  /// How multiple selected genres combine.
  enum GenreMode: String {
    /// Match any selected genre — widens the result set. The default, because with
    /// multi-select the intuitive first tap is "action OR comedy"; requiring every genre
    /// yields an empty grid almost immediately on a real library.
    case any
    /// Match every selected genre — narrows.
    case all
  }

  /// Genres available in a library, most-used first, with counts.
  ///
  /// Driven by actual library contents rather than a fixed TMDb list, so the picker can
  /// never offer a genre that would return nothing.
  func genres(libraryId: String?) async throws -> GenresResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/genres"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    if let libraryId { comps.queryItems = [URLQueryItem(name: "libraryId", value: libraryId)] }
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await requestWithRetry(url: url, method: "GET", body: Optional<Int>.none,
                                      response: GenresResponse.self, timeoutInterval: Timeout.interactive)
  }

  /// - Parameter filter: server-side mode. "justAdded" orders by added_at DESC; the default
  ///   (empty) orders by TITLE, which is why a bare `limit: 1` returns an alphabetical head
  ///   rather than the newest item — a trap that silently defeated the staleness check.
  func items(libraryId: String, limit: Int = 50, offset: Int = 0,
             genres: [String] = [], genreMode: GenreMode = .any,
             filter: String? = nil) async throws -> ItemsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/items"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [
      URLQueryItem(name: "libraryId", value: libraryId),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    // Filtering happens SERVER-side. Doing it client-side would only ever filter the pages
    // already loaded — with 500+ items paginated, the filter would appear to work while
    // silently missing most of the library.
    if !genres.isEmpty {
      comps.queryItems?.append(URLQueryItem(name: "genre", value: genres.joined(separator: ",")))
      comps.queryItems?.append(URLQueryItem(name: "genreMode", value: genreMode.rawValue))
    }
    if let filter, !filter.isEmpty {
      comps.queryItems?.append(URLQueryItem(name: "filter", value: filter))
    }
    guard let url = comps.url else {
      throw APIError.invalidURL
    }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: ItemsResponse.self, timeoutInterval: Timeout.bulk)
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

  /// Titles sharing a genre with whatever this user watched most recently.
  ///
  /// One request: the server picks the seed from the progress table directly, so it is
  /// correct even when this client's sync is behind — and it avoids fetching an item's full
  /// detail purely to read its genres, which ItemSummary does not carry.
  func suggested(libraryId: String?, limit: Int = 8) async throws -> SuggestedResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/suggested"),
                                    resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    var q = [URLQueryItem(name: "limit", value: String(limit))]
    if let libraryId { q.append(URLQueryItem(name: "libraryId", value: libraryId)) }
    comps.queryItems = q
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none,
                             response: SuggestedResponse.self, timeoutInterval: Timeout.interactive)
  }

  /// The "Just Added" rail, computed BY THE SERVER.
  ///
  /// The clients used to derive this themselves from their local SQLite mirror. That is a
  /// guess about the library made by the party that does not hold it, and it fails in the
  /// worst possible way: when the mirror stops updating, the rail keeps rendering
  /// confidently stale content and nothing reports a problem. A phone showed the same four
  /// TV shows for days while the server held a dozen newer films.
  ///
  /// The server precomputes and caches this, so the call is cheap and the answer is
  /// authoritative.
  func justAdded(libraryId: String? = nil, limit: Int = 16) async throws -> ItemsResponse {
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/just-added"),
                                    resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    var q = [URLQueryItem(name: "limit", value: String(limit))]
    if let libraryId { q.append(URLQueryItem(name: "libraryId", value: libraryId)) }
    comps.queryItems = q
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await requestWithRetry(url: url, method: "GET", body: Optional<Int>.none,
                                      response: ItemsResponse.self,
                                      timeoutInterval: Timeout.interactive)
  }

  /// The active profile's browse collections (FRD-002 FR-275). The server decides which
  /// collections this profile is offered and drops empty ones; an empty array means "no
  /// collections yet" (FR-276), not a failure.
  func collections() async throws -> CollectionsResponse {
    let url = baseURL.appendingPathComponent("/api/v1/collections")
    return try await requestWithRetry(url: url, method: "GET", body: Optional<Int>.none,
                                      response: CollectionsResponse.self,
                                      timeoutInterval: Timeout.interactive)
  }

  /// One page of a collection's titles, in the /items envelope (FR-275). A show is one entry
  /// (an `episode` row whose `showName` names the show). An offered collection with nothing
  /// visible answers `total: 0`; an id not offered to this profile is 404 unknown_collection.
  func collectionItems(id: String, sort: String = "title", order: String = "asc",
                       limit: Int = 60, offset: Int = 0) async throws -> ItemsResponse {
    guard var comps = URLComponents(
      url: baseURL.appendingPathComponent("/api/v1/collections")
        .appendingPathComponent(id).appendingPathComponent("items"),
      resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [
      URLQueryItem(name: "sort", value: sort),
      URLQueryItem(name: "order", value: order),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await requestWithRetry(url: url, method: "GET", body: Optional<Int>.none,
                                      response: ItemsResponse.self,
                                      timeoutInterval: Timeout.interactive)
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

  /// More Like This for a title (FR-151): up to `limit` titles in the /items element shape, with
  /// episodes already collapsed to their show. One attempt, no retry: the shelf is optional and
  /// loads after the page is up, so a failure is simply a hidden shelf (see MoreLikeThis).
  func similar(id: String, limit: Int = MoreLikeThis.limit) async throws -> ItemsResponse {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/items/\(enc)/similar"),
                                    resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none,
                             response: ItemsResponse.self, timeoutInterval: 15)
  }

  /// - Parameter startSeconds: where a TRANSCODE should begin in the source. Ignored by
  ///   the server for direct play and remux, which are byte-range seekable already. The
  ///   returned playlist's timeline still starts at 0, so add `PlaybackInfo.startSeconds`
  ///   to any position reported back to the user.
  func playback(id: String, quality: String = "auto", subtitleOffset: Double = 0,
                startSeconds: Double = 0) async throws -> PlaybackInfo {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/items/\(enc)/playback"), resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }
    var queryItems: [URLQueryItem] = []
    if quality != "auto" { queryItems.append(URLQueryItem(name: "quality", value: quality)) }
    if subtitleOffset != 0 { queryItems.append(URLQueryItem(name: "subtitleOffset", value: String(format: "%.3f", subtitleOffset))) }
    if startSeconds > 0 { queryItems.append(URLQueryItem(name: "start", value: String(format: "%.3f", startSeconds))) }
    if !queryItems.isEmpty { comps.queryItems = queryItems }
    guard let url = comps.url else { throw APIError.invalidURL }
    return try await request(url: url, method: "GET", body: Optional<Int>.none, response: PlaybackInfo.self, timeoutInterval: 15)
  }

  /// Returns whether the server actually stored the write. `false` means it was
  /// superseded by a newer write and silently discarded — not an error, but not a
  /// success either, so callers must not treat a 200 alone as "saved".
  ///
  /// - Parameter watchedAt: RFC3339 time the viewer was at this position. The server orders
  ///   writes by it (FRD-001 FR-014: the later watch wins), so pass it on every write: the
  ///   current time for a live write, the stored time when replaying an outbox backlog. Nil
  ///   falls back to the server's receive time.
  @discardableResult
  func setProgress(id: String, positionSeconds: Int, durationSeconds: Int,
                   watchedAt: String? = nil) async throws -> Bool {
    let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    let resp = try await request(
      path: "/api/v1/items/\(enc)/progress",
      method: "POST",
      body: ProgressRequest(positionSeconds: positionSeconds, durationSeconds: durationSeconds,
                            state: "playing", watchedAt: watchedAt),
      response: ProgressResponse.self,
      // A write, not an interactive read: this is called from the player and from the
      // outbox flush loop. Inheriting the general default let a single stalled write block
      // the flush; the outbox retries, so failing fast is strictly better.
      timeoutInterval: Timeout.write
    )
    // Absent (older server) is treated as applied — only an explicit false is a discard.
    return resp.applied ?? true
  }

  /// Releases a server playback session, freeing its transcode and temp directory now
  /// rather than waiting on the idle reaper.
  ///
  /// Best-effort and idempotent by design — the session id is its own credential, so this
  /// is unauthenticated, and a failure here must never surface to the user or block
  /// teardown. Every play previously leaked a session because nothing called it.
  func stopPlayback(sessionID: String, timeoutInterval: TimeInterval = 5) async {
    let enc = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
    guard let url = URL(string: "/api/v1/playback/\(enc)/stop", relativeTo: baseURL) else { return }
    // Issued directly rather than through request(): the endpoint answers 204 with an
    // EMPTY body, which no Decodable can parse. Going through the generic path would
    // always throw a decode error on an operation that in fact succeeded.
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = timeoutInterval
    if usesTunnelCookie { req.setValue("type=tunnel", forHTTPHeaderField: "Cookie") }
    _ = try? await URLSession.shared.data(for: req)
  }

  // progressBatch(ids:) lived here — superseded by progressAll (one request instead of
  // N chunked ones) and left with zero callers. Its own doc comment already said
  // "Prefer progressAll".

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

  /// Which artwork to ask the server for. An item's poster and backdrop share ONE id
  /// (`/api/v1/images/{itemID}`), so this is the only thing that tells them apart —
  /// omit it and the server serves the 2:3 poster (TASK-913).
  enum ImageKind: String {
    /// 2:3 portrait. Grid cells, show tiles, the detail-page poster.
    case poster
    /// 16:9 landscape. Wide rail cards, heroes, Top Shelf.
    case backdrop
  }

  /// Widths the backend serves, snapped from any `w` by `metadata.ParseImageSize`.
  /// Anything above the top rung is served as `original` — the full-resolution source,
  /// not "a big thumbnail".
  ///
  /// Passing a value off-ladder is silently rounded server-side, so the client would
  /// mint a distinct URL (= distinct URLCache + NSCache key) for bytes identical to a
  /// neighbouring request. Snapping here keeps one cache entry per real size.
  ///
  /// TASK-913: 780 and 1280 are BACKDROP-only rungs on TMDb. They exist here because a
  /// 16:9 TV rail card is genuinely ~760px wide — before they were added, every such
  /// card rounded up to `original` and pulled megabytes per tile.
  static let imageWidthLadder = [92, 185, 342, 500]
  static let backdropWidthLadder = [92, 185, 342, 500, 780, 1280]

  /// Snap a point size to the smallest ladder width that covers it at native scale.
  /// Pass the size the image is actually *drawn* at, in points.
  ///
  /// The cap matters: a 180pt grid cell at 3x wants 540px, past the poster ladder's top
  /// rung — and falling through to `original` would fetch the full-resolution source,
  /// far worse than the slight upscale from 500. For thumbnail-sized art a few percent
  /// of softness is invisible; multiple megabytes per cell is not. Callers that
  /// genuinely want `original` (full-bleed heroes) should pass a width explicitly.
  static func ladderWidth(forPointWidth points: CGFloat, scale: CGFloat,
                          kind: ImageKind = .poster) -> Int {
    let ladder = kind == .backdrop ? backdropWidthLadder : imageWidthLadder
    let needed = points * scale
    return ladder.first { CGFloat($0) >= needed } ?? ladder[ladder.count - 1]
  }

  func imageURL(id: String, width: Int? = nil, version: Int? = nil,
                kind: ImageKind = .poster) -> URL? {
    guard baseURL != AppState.fallbackURL else { return nil }
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/images/\(id)"), resolvingAgainstBaseURL: false) else {
      return nil
    }
    var items: [URLQueryItem] = []
    if let width { items.append(URLQueryItem(name: "w", value: String(width))) }
    if let version { items.append(URLQueryItem(name: "v", value: String(version))) }
    // Only sent for backdrops: `poster` is the server's default, and omitting it keeps
    // every existing poster URL byte-identical so caches stay warm across this upgrade.
    if kind == .backdrop { items.append(URLQueryItem(name: "type", value: kind.rawValue)) }
    if !items.isEmpty { comps.queryItems = items }
    return comps.url
  }

  /// The lock-screen and Control Center artwork for a title (FR-058, TASK-965): its poster,
  /// else its backdrop, so a title with only one kind of art still shows a picture. Nil when
  /// it has neither. The poster URL is byte-identical to the library grid's (ItemPosterCell:
  /// 342, versioned) so a title opened from the grid finds its artwork already in ImageCache.
  ///
  /// `downloadedPoster` is the poster file a download saved beside its video (TASK-1011). It
  /// is the same picture as the server poster, so it comes first: it needs no network, and a
  /// download is most often played offline.
  func nowPlayingArtworkURL(images: ItemDetail.Images?, version: Int? = nil,
                            downloadedPoster: URL? = nil) -> URL? {
    if let downloadedPoster { return downloadedPoster }
    if let posterID = images?.poster?.id {
      return imageURL(id: posterID, width: 342, version: version)
    }
    if let backdropID = images?.backdropImageID {
      return imageURL(id: backdropID, width: 780, version: version, kind: .backdrop)
    }
    return nil
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
    // 90s, not 30. A 500-item page is a genuinely large response, and over the WAN path
    // (QuickConnect / DDNS) a 100-item /items call measured 21 SECONDS against 13ms on the
    // LAN. At 30s this timed out on essentially every remote sync, which is how a device
    // could never finish a full re-fetch. The caller now also asks for smaller pages when
    // it has to start from scratch — see runDeltaSync — so this budget covers the slow
    // link rather than encouraging bigger requests.
    return try await request(url: url, method: "GET", body: Optional<Int>.none,
                             response: SyncItemsResponse.self, timeoutInterval: 90)
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

  /// `server` travels with the code to the device that redeems it (TASK-972).
  func generatePairingCode(server: PairingServerInfo) async throws -> PairingCodeResponse {
    try await request(path: "/api/v1/auth/pairing/generate", method: "POST", body: server, response: PairingCodeResponse.self)
  }

  func exchangePairingCode(code: String, timeoutInterval: TimeInterval = Timeout.auth) async throws -> PairingExchangeResponse {
    let req = PairingCodeExchangeRequest(code: code)
    return try await request(
      path: "/api/v1/auth/pairing/exchange",
      method: "POST",
      body: req,
      response: PairingExchangeResponse.self,
      authorized: false,
      timeoutInterval: timeoutInterval
    )
  }

  // MARK: - Profiles (docs/api/ProfilesAPI.md)
  //
  // Profile routes send NO profile header: they work whatever the active profile is (the
  // picker needs them), and a stale id from a deleted profile must not lock the picker out.
  // PIN-bearing calls use `request`, never `requestWithRetry`: a silent retry after a
  // timeout could spend a second attempt against the shared failure counter (FR-215).

  func profiles() async throws -> ProfilesResponse {
    try await pinned(to: nil).requestWithRetry(
      path: "/api/v1/profiles", method: "GET", body: Optional<Int>.none,
      response: ProfilesResponse.self, timeoutInterval: Timeout.interactive)
  }

  func ageLevels() async throws -> AgeLevelsResponse {
    try await pinned(to: nil).requestWithRetry(
      path: "/api/v1/profiles/age-levels", method: "GET", body: Optional<Int>.none,
      response: AgeLevelsResponse.self, timeoutInterval: Timeout.interactive)
  }

  func createProfile(_ body: CreateProfileRequest) async throws -> Profile {
    try await pinned(to: nil).request(
      path: "/api/v1/profiles", method: "POST", body: body,
      response: Profile.self, timeoutInterval: Timeout.interactive)
  }

  func updateProfile(id: String, _ body: UpdateProfileRequest) async throws -> Profile {
    try await pinned(to: nil).request(
      path: "/api/v1/profiles/\(Self.pathSegment(id))", method: "PATCH", body: body,
      response: Profile.self, timeoutInterval: Timeout.interactive)
  }

  /// DESTRUCTIVE (FR-206): the server permanently deletes the profile's progress, history
  /// and watchlist. Callers confirm with the user first.
  func deleteProfile(id: String, ownerPin: String) async throws {
    _ = try await pinned(to: nil).request(
      path: "/api/v1/profiles/\(Self.pathSegment(id))", method: "DELETE",
      body: OwnerPinBody(ownerPin: ownerPin),
      response: EmptyDecodable.self, timeoutInterval: Timeout.interactive)
  }

  /// FR-213: the server checks the PIN every time a protected profile is entered.
  func verifyPin(profileID: String, pin: String) async throws {
    _ = try await pinned(to: nil).request(
      path: "/api/v1/profiles/\(Self.pathSegment(profileID))/pin/verify", method: "POST",
      body: PinBody(pin: pin),
      response: EmptyDecodable.self, timeoutInterval: Timeout.interactive)
  }

  /// FR-216: a forgotten owner PIN is reset with the DSM password (and OTP, if any).
  func resetOwnerPin(password: String, otp: String?, newPin: String) async throws {
    _ = try await pinned(to: nil).request(
      path: "/api/v1/profiles/owner/pin/reset", method: "POST",
      body: OwnerPinResetRequest(password: password, otp: otp, newPin: newPin),
      response: EmptyDecodable.self, timeoutInterval: Timeout.auth)
  }

  /// One path segment: "/" is escaped too, so an id can never step into another route.
  private static func pathSegment(_ id: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove("/")
    return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
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

  // isInWatchlist(id:) lived here — zero callers. Watchlist membership is derived
  // from the already-loaded AppState.watchlistItems, so a per-item round trip was
  // never needed.

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
    timeoutInterval: TimeInterval = Timeout.interactive
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
    timeoutInterval: TimeInterval = Timeout.interactive
  ) async throws -> T {
    do {
      return try await request(url: url, method: method, body: body, response: response, authorized: authorized, timeoutInterval: timeoutInterval)
    } catch let error as APIError where Self.isRetryableTransport(error) {
      // MUST match APIError.connection, not a bare URLError.
      //
      // request() wraps every URLError it catches into APIError.connection(code) — so the
      // previous `catch let urlError as URLError` clause could never match and this entire
      // retry ladder was dead from the day that wrap landed. The LAN→WAN blip it was
      // written for (TASK-788) went unretried, and search / item detail / genres /
      // watchlist / TV shows all failed hard on a network switch instead.
      try await Task.sleep(nanoseconds: 1_000_000_000)
      return try await request(url: url, method: method, body: body, response: response, authorized: authorized, timeoutInterval: timeoutInterval)
    }
  }

  /// Transport failures worth exactly one retry.
  ///
  /// TASK-788: a LAN→WAN auto-switch produces a transient .cannotConnectToHost /
  /// .cannotFindHost / .dnsLookupFailed on the first request after the network changes
  /// (old LAN IP unreachable, or WAN host not yet resolving). A single bounded retry
  /// papers over the blip while the reconnect cascade catches up — handleConnectionFailure
  /// already treats these as serverUnreachable.
  static func isRetryableTransport(_ error: APIError) -> Bool {
    guard case .connection(let code) = error else { return false }
    return [
      .timedOut, .networkConnectionLost, .notConnectedToInternet,
      .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ].contains(code)
  }

  private func request<T: Decodable, B: Encodable>(
    path: String,
    method: String,
    body: B?,
    response: T.Type,
    authorized: Bool = true,
    timeoutInterval: TimeInterval = Timeout.interactive
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
    timeoutInterval: TimeInterval = Timeout.interactive
  ) async throws -> T {
    var req = URLRequest(url: url, timeoutInterval: timeoutInterval)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var sentProfileID: String?
    if authorized, let token {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      switch profileHeader {
      case .activeProfile: sentProfileID = profileStore.activeProfileID
      case .pinned(let id): sentProfileID = id
      }
      ActiveProfileStore.setHeader(sentProfileID, on: &req)
    }
    if usesTunnelCookie {
      req.setValue("type=tunnel", forHTTPHeaderField: "Cookie")
    }
    if let body {
      req.httpBody = try Self.encoder.encode(body)
    }

    // A transport failure (host down, connection refused, DNS miss, TLS mismatch) throws
    // URLError, NOT APIError. Left unwrapped it escapes as an unrecognised error type and
    // callers fall through to a generic "Login failed" — or worse, a string-matching ladder
    // upstream sees the word "password" nowhere, matches something else, and tells the user
    // their credentials are wrong when the server was simply unreachable. Wrap it here so the
    // real reason survives all the way to the UI.
    // Diagnostic instrumentation: this is the single choke point every API call passes
    // through, so logging here covers login, libraries, home rails, playback and progress
    // without scattering log lines across the codebase. Kept to one line per request so a
    // photographed screen stays readable.
    let started = Date()
    let endpoint = "\(method) \(url.path)"

    let data: Data
    let httpResp: HTTPURLResponse
    do {
      let (d, resp) = try await URLSession.shared.data(for: req)
      guard let http = resp as? HTTPURLResponse else {
        dlog.error(.network, "\(endpoint) — response was not HTTP")
        throw APIError.network
      }
      data = d
      httpResp = http
    } catch let urlError as URLError {
      // The failure Ryan hit on the TV: server unreachable, reported to the user as a
      // credentials problem. Log the host so a stale saved address is obvious at a glance.
      dlog.error(.network,
                 "\(endpoint) — \(urlError.code.diagnosticName) (host: \(url.host ?? "?"):\(url.port.map(String.init) ?? "-"))")
      throw APIError.transport(urlError)
    }

    let ms = Int(Date().timeIntervalSince(started) * 1000)
    if !(200...299).contains(httpResp.statusCode) {
      // 409 from /playback means the server is mid-converting this file to a
      // DirectPlay format (auto-normalize, TASK-755). Surface it as a distinct,
      // non-error state so the UI can show an informational "being prepared, check
      // back later" message instead of a red failure.
      if httpResp.statusCode == 409,
         let conv = try? Self.decoder.decode(ConvertingResponse.self, from: data),
         conv.status == "converting" {
        throw APIError.converting
      }
      // Carry the HTTP status alongside the decoded error code. The backend's writeErr
      // ALWAYS emits a JSON body ({"error": code}) — including on 401 — so this decode
      // always succeeded and every auth rejection became .server("invalid_token"),
      // never .http(401). The two `case .http(401)` handlers in AppState were therefore
      // unreachable: an expired or revoked token left the user on an authenticated-looking
      // UI with empty rails, no route back to login, and the dead token still in the
      // Keychain. Preserving the status here is what makes those handlers fire.
      if let apiErr = try? Self.decoder.decode(APIErrorResponse.self, from: data) {
        dlog.error(.network, "\(endpoint) → HTTP \(httpResp.statusCode) \(apiErr.error) (\(ms)ms)")
        if apiErr.error == "unknown_profile" {
          // The profile this request named is gone (deleted, or another account's). The
          // app returns to the picker (FR-206); AppState decides whether it was the active one.
          let rejected = sentProfileID
          Task { @MainActor in
            NotificationCenter.default.post(name: .activeProfileRejected, object: rejected)
          }
        }
        throw APIError.server(apiErr.error, status: httpResp.statusCode, detail: apiErr.detail)
      }
      dlog.error(.network, "\(endpoint) → HTTP \(httpResp.statusCode), no error body (\(ms)ms)")
      throw APIError.http(httpResp.statusCode)
    }

    do {
      let decoded = try Self.decoder.decode(T.self, from: data)
      // Only log slow successes. A healthy request is noise; a slow one explains a stall.
      if ms > 3000 {
        dlog.warn(.network, "\(endpoint) → OK but slow: \(ms)ms, \(data.count)B")
      }
      return decoded
    } catch let decodeError as DecodingError {
      // Decode failures are the quietest class of bug in this app: the request succeeded,
      // the server was healthy, and the screen renders empty. ItemsResponse.total silently
      // breaking Watchlist on every platform was exactly this. Name the field and the
      // expected type so the mismatch is diagnosable from a photo alone.
      let detail = Self.describe(decodeError)
      dlog.error(.decode, "\(endpoint) → \(detail) [\(T.self)]")
      // Wrap rather than rethrow raw. Every consumer tests `error as? APIError`, so an
      // unwrapped DecodingError silently became "Could not connect to server." — reporting a
      // healthy server as unreachable, which is exactly the quiet failure described above.
      throw APIError.decode(detail: detail)
    }
  }

  /// Flatten a DecodingError into one short, photographable line naming the offending field.
  private static func describe(_ error: DecodingError) -> String {
    func path(_ ctx: DecodingError.Context) -> String {
      let p = ctx.codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
      return p.isEmpty ? "<root>" : p
    }
    switch error {
    case .keyNotFound(let key, let ctx):
      return "missing field '\(key.stringValue)' at \(path(ctx))"
    case .typeMismatch(let type, let ctx):
      return "wrong type at \(path(ctx)) — expected \(type)"
    case .valueNotFound(let type, let ctx):
      return "null at \(path(ctx)) — expected \(type)"
    case .dataCorrupted(let ctx):
      return "corrupt JSON at \(path(ctx))"
    @unknown default:
      return "decode failed"
    }
  }
}

enum APIError: Error {
  case network
  /// A transport-level failure that never reached the server (host unreachable, connection
  /// refused, DNS failure, timeout, TLS rejection). Distinct from `.server`/`.http`, which
  /// mean the server DID answer and rejected us — the difference the user needs in order to
  /// know whether to fix their address or their password.
  case connection(URLError.Code)
  /// The request never left the device: Local Network access is off and the server is on the
  /// LAN (TASK-949). URLSession reports it as -1009 `.notConnectedToInternet`, which is not
  /// true: the network works, the app may not use it.
  case localNetworkDenied
  case http(Int)
  /// A structured error from the server. `status` is the HTTP status that carried it —
  /// needed because the backend returns a JSON body on EVERY error including 401, so
  /// matching on the message alone cannot distinguish an auth failure from any other
  /// server-side rejection. Defaulted so existing construction sites keep compiling.
  case server(String, status: Int = 0, detail: APIErrorDetail? = nil)
  case invalidURL
  // The server is currently converting this title to a smooth-playback format
  // (auto-normalize). Not a failure — an informational, transient state.
  case converting
  /// The request SUCCEEDED and the server is healthy — we could not parse what it sent.
  ///
  /// Previously a DecodingError was rethrown unwrapped, so every consumer's
  /// `(error as? APIError)?.userMessage ?? "Could not connect to server."` fell through to
  /// the fallback and told the user their server was unreachable while it was answering
  /// normally. That is the opposite of the truth and sends them to debug their network
  /// instead of reporting a version mismatch. `detail` names the offending field.
  case decode(detail: String)

  var userMessage: String {
    switch self {
    case .network: return "Network error."
    case .localNetworkDenied: return LocalNetworkPermission.deniedMessage
    case .connection(let code):
      switch code {
      case .cannotConnectToHost:
        return "Couldn't connect to the server. Check the address and port, and that DSVideoServer is running."
      case .cannotFindHost, .dnsLookupFailed:
        return "Couldn't find that server. Double-check the address."
      case .timedOut:
        return "The server didn't respond. Check the address and that DSVideoServer is running."
      case .notConnectedToInternet, .networkConnectionLost:
        return "No network connection."
      case .secureConnectionFailed, .serverCertificateUntrusted,
           .serverCertificateHasBadDate, .serverCertificateNotYetValid,
           .serverCertificateHasUnknownRoot:
        return "Secure connection failed. If your server has no HTTPS certificate, turn HTTPS off."
      case .appTransportSecurityRequiresSecureConnection:
        // -1022. iOS refused to SEND the request; nothing was ever attempted, so the
        // address and port are not the problem and telling the user to check them sends
        // them to debug a server that is very likely fine.
        //
        // The app's ATS policy allows cleartext on the local network only (TASK-777), so
        // this is specifically: plain http:// to a PUBLIC address. Name that, and name the
        // fix — this is exactly the remote-access case, where the answer is HTTPS or
        // QuickConnect rather than weakening transport security.
        return "iOS blocked this connection because it isn't encrypted. Plain http:// is only "
          + "allowed on your local network — for a server outside it, turn HTTPS on or connect "
          + "with QuickConnect."
      default:
        return "Couldn't reach the server. Check the address and port."
      }
    case .converting:
      return "This video is being prepared for smooth playback. Check back in a few minutes."
    case .decode:
      // Deliberately does not mention the network: the server answered. Name the real cause
      // and the action that can actually help.
      return "The server sent something this app couldn't read. It may be running a different "
        + "version — update DSVideoServer and the app, then try again."
    case .http(let code):
      // Name the cause, not the wire status. A raw "Server error (403)" tells the user
      // nothing they can act on.
      switch code {
      case 401:
        return "Your session expired. Sign in again."
      case 403:
        // A bare 403 says nothing about the session (TASK-961): the backend's session failures
        // are all 401, and its 403s are permission, profile and content refusals.
        return "The server refused that request. This account or profile may not have access to it."
      case 404:
        return "The server couldn't find that item. It may have been moved or removed."
      case 429:
        return "Too many requests at once. Wait a moment and try again."
      case 500...599:
        return "The server had a problem handling that. Try again shortly."
      default:
        return "The server rejected the request (\(code))."
      }
    case .server(let msg, _, let detail):
      // Map known server error codes to friendly, actionable text.
      switch msg {

      // ── Profiles and PINs (FRD-002 §10) ───────────────────────────────────────
      // None of these is a session problem (FR-217): they never say "sign in again".
      case "unknown_profile":
        return "That profile no longer exists. Choose a profile to continue."
      case "content_restricted":
        return "This title is above this profile's age rating."
      case "profile_restricted":
        return "This profile has an age limit, so it can't change library details. Switch to an Adult profile to do this."
      case "owner_pin_required":
        return "Enter the owner's PIN to manage profiles."
      case "pin_incorrect":
        return Self.incorrectPinMessage(attemptsRemaining: detail?.attemptsRemaining)
      case "pin_locked":
        return Self.pinLockedMessage(retryAfterSeconds: detail?.retryAfterSeconds)
      case "password_incorrect":
        return "Incorrect DSM password or verification code."
      case "otp_required":
        return "This DSM account uses two-factor sign-in. Enter your DSM verification code along with your password."
      case "dsm_unavailable":
        // FR-216 (TASK-1014): the server reached DSM's absence, not a verdict on the password.
        // Unmapped, this fell to the default and read "Dsm unavailable.".
        return "Couldn't reach DSM on your NAS to check your password. Nothing was changed. Try again in a moment."
      case "invalid_pin_format":
        return "A PIN must be exactly 4 digits."
      case "invalid_profile_name":
        return "A profile name needs 1 to \(ProfileNameRules.maxLength) characters."
      case "duplicate_profile_name":
        return "Another profile already has that name."
      case "invalid_age_level":
        return "That age rating isn't one this app supports. Choose one from the list."
      case "profile_limit_reached":
        return "This account already has the most profiles allowed. Delete one to add another."
      case "owner_pin_not_set":
        return "Set a PIN on the owner profile before adding other profiles."
      case "owner_profile_immutable":
        return "The owner profile can't be deleted or given an age limit, and keeps its PIN while other profiles exist."
      case "unknown_collection":
        return "That collection isn't available on this profile."

      // ── Account / access ──────────────────────────────────────────────────────
      case "permission_denied":
        return "Your account isn't allowed to use this app. Ask the server owner to grant you access in DSM → Control Panel → Application Privileges."
      case "invalid_credentials":
        return "Incorrect username or password."
      case "account_disabled":
        return "This account is disabled. Ask the server owner to enable it."
      case "admin_required":
        return "This action needs an administrator account."
      case "missing_credentials":
        return "Enter both a username and a password."

      // ── Session / token ───────────────────────────────────────────────────────
      // These are recoverable by signing in again; say that rather than showing jargon.
      case "invalid_token", "token_revoked", "token_error":
        return "Your session has expired. Please sign in again."
      case "missing_token":
        return "You're signed out. Please sign in again."
      case "token_generation_failed", "token_signing_failed":
        return "The server couldn't create a session. Try again, and check the server logs if it persists."

      // ── Pairing ───────────────────────────────────────────────────────────────
      case "invalid_or_expired_code":
        return "That pairing code is wrong or has expired. Generate a new one and try again."
      case "pairing_busy":
        return "The server couldn't issue a pairing code right now. Try again in a minute."
      case "missing_code":
        return "Enter the 6-digit pairing code from your signed-in device."

      // ── Playback ──────────────────────────────────────────────────────────────
      // The four most likely playback failures. These used to render as raw snake_case
      // ("transcode busy"), which tells the user nothing about what to do next.
      case "transcode_busy":
        return "The server is already converting other videos. Try again in a few minutes."
      case "transcode_unavailable", "ffmpeg_failed", "pipe_failed":
        return "This video can't be prepared for playback right now. Check that DSVideoServer's converter is working."
      case "media_missing", "path_not_allowed", "stat_failed":
        return "The video file is missing or was moved. Rescan your library on the NAS."
      case "invalid_segment", "playlist_not_ready":
        return "Playback is still starting up. Give it a moment and try again."
      case "trickplay_unavailable":
        return "Scrubbing previews aren't ready for this video yet."

      // ── Content lookup ────────────────────────────────────────────────────────
      case "not_found", "show_not_found":
        return "That item is no longer in your library."
      case "invalid_library":
        return "That library no longer exists. Pull to refresh."
      case "image_not_found", "no_image_available", "image_fetch_failed", "image_cache_unavailable":
        return "Artwork isn't available for this item."

      // ── Metadata ──────────────────────────────────────────────────────────────
      case "tmdb_not_configured":
        return "TMDb isn't set up on the server, so artwork and descriptions can't be fetched. Add an API key in DSVideoServer's settings."
      case "tmdb_error":
        return "Couldn't reach TMDb for artwork. Try again later."

      // ── Rate limiting / server health ─────────────────────────────────────────
      case "rate_limit_exceeded":
        return "Too many requests. Wait a moment and try again."
      case "db_error", "internal_error":
        return "The server hit an internal error. Check the DSVideoServer logs on your NAS."
      case "server_error":
        // TASK-1040: the profile endpoints return this when the server failed to generate an
        // ID or secure a PIN, before anything was written (profiles.go), so "nothing was
        // saved" is true of every path that reaches it.
        return "The server couldn't finish that and nothing was saved. Try again; if it keeps happening, check the DSVideoServer logs on your NAS."

      // ── QuickConnect lookup (POST /auth/quickconnect/resolve) ─────────────────
      case "quickconnect_resolve_failed":
        // The NAS asked QuickConnect's lookup service and got no usable answer, so the
        // ID itself is not at fault (an unknown ID is QuickConnectError.notFound).
        return "Your NAS couldn't reach QuickConnect to look up that ID. Check that the NAS has an internet connection, or sign in with its address instead."
      case "missing_quickconnect_id":
        return "Enter a QuickConnect ID to look up."

      // ── Profile picture ───────────────────────────────────────────────────────
      case "invalid_avatar":
        return "The server doesn't accept that profile picture. Choose a different one."

      default:
        // Anything unmapped still reaches the user, but as a readable sentence rather than
        // a raw identifier. Malformed-request codes (invalid_json, missing_show_id, …) land
        // here deliberately: they indicate a client bug, not something a user can fix, and
        // the diagnostic log carries the exact code for us. A code a user CAN act on gets
        // its own case above (TASK-1040).
        let readable = msg.replacingOccurrences(of: "_", with: " ")
        return readable.prefix(1).uppercased() + readable.dropFirst() + "."
      }
    case .invalidURL: return "Invalid server URL."
    }
  }

  /// True when this is an authentication/authorization rejection — the token is missing,
  /// expired, invalid, or revoked, or the account lacks permission.
  ///
  /// Use this instead of matching `.http(401)`: the backend attaches a JSON body to every
  /// error response, so a 401 arrives as `.server("invalid_token", status: 401)` and a bare
  /// `case .http(401)` never matches. Checking the status covers both shapes, and the
  /// message check covers any path that loses the status.
  var isAuthFailure: Bool {
    // An ACCOUNT-STATE problem is not a credential problem: re-authenticating cannot fix it,
    // so it must not trigger the clear-session-and-return-to-login path. The backend emits
    // permission_denied/403 from the LOGIN handler itself (main.go:1331) when DSM rejects the
    // account for this app — a documented, real condition. Treating it as an auth failure
    // produced an infinite loop: sign in successfully → 403 → token deleted → sign in again →
    // 403 → forever, with no message explaining that the fix is in DSM's Application
    // Privileges. Those cases surface their own actionable error via userMessage instead.
    if isAccountStateFailure { return false }
    // 403 is NOT auth. None of the backend's 403 codes concerns the session:
    //   permission_denied  — account state, handled above (re-auth cannot fix it)
    //   admin_required     — this USER lacks a privilege; the session is perfectly valid
    //   path_not_allowed   — the requested FILE is outside the media roots
    //   forbidden          — a route refused this account
    //   unknown_profile, content_restricted, profile_restricted, owner_pin_required,
    //   pin_incorrect, password_incorrect, otp_required
    //                      — profile and PIN refusals (FRD-002 §10, FR-217: none is a session
    //                        failure)
    // Treating any of them as an auth failure deleted the Keychain token and claimed the
    // session had expired, so a moved or renamed file could silently sign the user out.
    // The session failures (missing_token, invalid_token, token_revoked) are all 401, and
    // 401 remains unconditional — every 401 the server emits is genuinely a token problem.
    switch self {
    case .http(let code):
      return code == 401
    case .server(let msg, let status, _):
      if status == 401 { return true }
      return ["missing_token", "invalid_token", "token_revoked"].contains(msg)
    default:
      return false
    }
  }

  /// The account exists and the password is right, but it is not permitted to use this app
  /// (DSM Application Privileges) or is disabled. Re-authentication cannot resolve either —
  /// only a change on the server can — so these must NOT drive the session-expiry path.
  var isAccountStateFailure: Bool {
    if case .server(let msg, _, _) = self {
      return msg == "permission_denied" || msg == "account_disabled"
    }
    return false
  }

  /// True when the server rejected this request in a way that RETRYING CANNOT FIX — the
  /// resource is gone, or the payload is invalid. Distinct from a transient failure
  /// (offline, timeout, 5xx, auth expiry), all of which can succeed later.
  ///
  /// Used by the progress outbox: a queued row for a deleted item 404s forever
  /// (main.go's TASK-797 guard), and retrying it at the head of the queue blocks every
  /// row behind it permanently. Such rows are dropped rather than retried.
  ///
  /// Deliberately EXCLUDES 401/403 — an expired token is transient, and those are handled
  /// by isAuthFailure / the re-authentication path instead.
  var isPermanentRejection: Bool {
    switch self {
    case .http(let code):
      return code == 400 || code == 404 || code == 410 || code == 422
    case .server(let msg, let status, _):
      if status == 400 || status == 404 || status == 410 || status == 422 { return true }
      return ["not_found", "invalid_progress", "item_not_found"].contains(msg)
    default:
      return false
    }
  }

  /// True when the failure came back from the server itself (it was reached and
  /// answered), as opposed to a connectivity/DNS/resolution miss. Used so the
  /// login flow surfaces a real auth error instead of a generic "couldn't find".
  var serverReached: Bool {
    switch self {
    // .decode means the request completed and the server sent a body we could not parse —
    // the most definitively "reached" failure there is.
    case .server, .http, .converting, .decode: return true
    case .network, .invalidURL, .connection, .localNetworkDenied: return false
    }
  }
}

struct APIErrorResponse: Decodable {
  let error: String
  /// `pin_incorrect` only: tries left before the profile locks (FR-215).
  let attemptsRemaining: Int?
  /// `pin_locked` only: seconds until PIN checks are accepted again (FR-215).
  let retryAfterSeconds: Int?

  var detail: APIErrorDetail? {
    guard attemptsRemaining != nil || retryAfterSeconds != nil else { return nil }
    return APIErrorDetail(attemptsRemaining: attemptsRemaining, retryAfterSeconds: retryAfterSeconds)
  }
}

/// Extra fields some error bodies carry (ProfilesAPI.md, FRD-002 §10).
nonisolated struct APIErrorDetail: Equatable, Sendable {
  var attemptsRemaining: Int?
  var retryAfterSeconds: Int?
}

/// Where APIClient takes `X-DSVideo-Profile` from. See `APIClient.profileHeader`.
nonisolated enum ProfileHeaderSource: Equatable, Sendable {
  /// Read ActiveProfileStore when the request is built.
  case activeProfile
  /// Always this id; nil sends no header.
  case pinned(String?)
}

extension APIError {
  /// The one conversion of a transport failure. TASK-949: -1009 also means "Local Network
  /// access is off" when the address is on the LAN. It is classified here, while the error still
  /// carries its NWPath; past this point only the code survives and the user would read
  /// "No network connection." on a network that works.
  nonisolated static func transport(_ urlError: URLError) -> APIError {
    LocalNetworkPermission.isDenied(urlError) ? .localNetworkDenied : .connection(urlError.code)
  }

  /// The server's structured extras, when the error carried any.
  var detail: APIErrorDetail? {
    if case .server(_, _, let detail) = self { return detail }
    return nil
  }

  /// The server's error code, when it sent one.
  var serverCode: String? {
    if case .server(let code, _, _) = self { return code }
    return nil
  }

  nonisolated static func incorrectPinMessage(attemptsRemaining: Int?) -> String {
    guard let left = attemptsRemaining else { return "Incorrect PIN." }
    switch left {
    case ...0: return "Incorrect PIN. No tries left, so PIN entry for this profile is locked for a while."
    case 1: return "Incorrect PIN. 1 try left before this profile locks."
    default: return "Incorrect PIN. \(left) tries left before this profile locks."
    }
  }

  nonisolated static func pinLockedMessage(retryAfterSeconds: Int?) -> String {
    let base = "Too many incorrect PINs."
    guard let seconds = retryAfterSeconds, seconds > 0 else {
      return base + " Wait a few minutes and try again."
    }
    if seconds < 60 {
      return base + " Try again in \(seconds) second\(seconds == 1 ? "" : "s")."
    }
    let minutes = (seconds + 59) / 60   // round up: never promise it unlocks sooner than it does
    return base + " Try again in \(minutes) minute\(minutes == 1 ? "" : "s")."
  }
}

/// 409 body from /playback when the server is mid-converting the title to a
/// DirectPlay format (auto-normalize, TASK-755). Distinct from APIErrorResponse
/// so a "converting" state isn't shown as a hard error.
struct ConvertingResponse: Decodable {
  let status: String
}

/// Used as a placeholder response type for endpoints that return any JSON but whose value we discard.
struct EmptyDecodable: Decodable {}

