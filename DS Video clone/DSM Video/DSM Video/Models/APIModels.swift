import Foundation

// MARK: - Auth

struct LoginRequest: Encodable {
  let username: String
  let password: String
  let otp: String?
}

struct LoginResponse: Decodable {
  struct User: Decodable {
    let id: String
    let username: String
    let displayName: String
  }

  let token: String
  let user: User
}

// MARK: - Libraries

struct LibrariesResponse: Decodable {
  let libraries: [Library]
}

struct Library: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let kind: String
}

// MARK: - Items

struct ItemsResponse: Decodable {
  /// Optional because not every endpoint that returns this shape sends it.
  ///
  /// GET /api/v1/watchlist returns ONLY {"items": [...]} — no `total`. With this declared
  /// non-optional the decode threw keyNotFound on every watchlist load, on every platform,
  /// every 30 seconds, and the list rendered permanently empty even with items saved
  /// server-side (verified live: 6 items returned, 0 shown). /items does send it and is
  /// unaffected.
  let total: Int?
  let items: [ItemSummary]

  /// Total when the server supplied one, else the count actually returned. Callers paging or
  /// displaying a count should use this rather than force-unwrapping `total`.
  var effectiveTotal: Int { total ?? items.count }
}

struct ItemProgress: Codable, Hashable, Sendable {
  let positionSeconds: Int
  let durationSeconds: Int
  let updatedAt: String
}

struct ItemSummary: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let type: String
  let title: String
  let year: Int?
  let durationSeconds: Int?
  let addedAt: String
  let rating: Double?
  let posterImageId: String?
  let backdropImageId: String?
  let progress: ItemProgress?
  let showName: String?
  let showFolderId: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
  // Delta sync metadata — nil when decoded from legacy API responses
  let libraryId: String?
  let changeSeq: Int?

  nonisolated init(id: String, type: String, title: String, year: Int? = nil,
                   durationSeconds: Int? = nil, addedAt: String, rating: Double? = nil,
                   posterImageId: String? = nil, backdropImageId: String? = nil,
                   progress: ItemProgress? = nil, showName: String? = nil,
                   showFolderId: String? = nil,
                   seasonNumber: Int? = nil, episodeNumber: Int? = nil,
                   libraryId: String? = nil, changeSeq: Int? = nil) {
    self.id = id
    self.type = type
    self.title = title
    self.year = year
    self.durationSeconds = durationSeconds
    self.addedAt = addedAt
    self.rating = rating
    self.posterImageId = posterImageId
    self.backdropImageId = backdropImageId
    self.progress = progress
    self.showName = showName
    self.showFolderId = showFolderId
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.libraryId = libraryId
    self.changeSeq = changeSeq
  }
}

extension ItemSummary {
  nonisolated var withoutProgress: ItemSummary {
    ItemSummary(id: id, type: type, title: title, year: year,
                durationSeconds: durationSeconds, addedAt: addedAt,
                rating: rating, posterImageId: posterImageId,
                backdropImageId: backdropImageId, progress: nil,
                showName: showName, showFolderId: showFolderId,
                seasonNumber: seasonNumber, episodeNumber: episodeNumber,
                libraryId: libraryId, changeSeq: changeSeq)
  }

  nonisolated func withPosterImageId(_ newId: String) -> ItemSummary {
    ItemSummary(id: id, type: type, title: title, year: year,
                durationSeconds: durationSeconds, addedAt: addedAt,
                rating: rating, posterImageId: newId,
                backdropImageId: backdropImageId, progress: progress,
                showName: showName, showFolderId: showFolderId,
                seasonNumber: seasonNumber, episodeNumber: episodeNumber,
                libraryId: libraryId, changeSeq: changeSeq)
  }
}

// MARK: - TV Shows

struct TVShow: Decodable, Identifiable, Hashable {
  let id: String
  let title: String
  let year: Int?
  let seasonCount: Int?
  let episodeCount: Int?
  let posterImageId: String?
  let lastWatchedAt: String?
  let addedAt: String?
  let metadataVersion: Int?

  /// Stable identity for list/grid rendering. `id` is the folder name, which the
  /// detail view passes to the seasons/episodes endpoints — but two distinct shows
  /// can share one folder (e.g. "Marvel's Daredevil" and "Daredevil: Born Again"
  /// both under Daredevil/), giving them the SAME `id`. A LazyVGrid keyed on `id`
  /// then collapses the duplicate cells and one renders blank depending on scroll
  /// position. Key the grid on this composite instead so each show is distinct,
  /// while detail navigation still uses `id` for the API lookup.
  var gridID: String { "\(id)\u{001F}\(title)" }

  init(id: String, title: String, year: Int?, seasonCount: Int?, episodeCount: Int?,
       posterImageId: String?, lastWatchedAt: String?, addedAt: String?, metadataVersion: Int? = nil) {
    self.id = id; self.title = title; self.year = year; self.seasonCount = seasonCount
    self.episodeCount = episodeCount; self.posterImageId = posterImageId
    self.lastWatchedAt = lastWatchedAt; self.addedAt = addedAt; self.metadataVersion = metadataVersion
  }
}

struct TVShowsResponse: Decodable {
  let shows: [TVShow]
}

struct TVSeason: Decodable, Hashable {
  let seasonNumber: Int
  let episodeCount: Int
}

struct TVSeasonsResponse: Decodable {
  let seasons: [TVSeason]
}

struct ItemDetail: Decodable, Identifiable {
  struct Person: Decodable, Hashable {
    let id: String?
    let name: String
    let role: String?
    let imageId: String?
  }

  struct Images: Decodable {
    struct Ref: Decodable {
      let id: String?
      let mapperId: String? // Added for backdrop API (uses mapper_id)
    }

    let poster: Ref
    let backdrop: Ref
  }

  let id: String
  let type: String
  let title: String
  let originalTitle: String?
  let year: Int?
  let durationSeconds: Int?
  let contentRating: String?
  let rating: Double?
  let summary: String?
  let genres: [String]?
  let cast: [Person]?
  // TASK-783: optional so an item whose server response omits the `images`
  // envelope (freshly-scanned / not-yet-TMDb-matched item, or an older server)
  // still decodes and opens — the detail view falls back to placeholder art.
  let images: Images?
  let changeSeq: Int?

  // TASK-728: media specs (nil until the server has fully probed the file).
  let videoCodec: String?
  let audioCodec: String?
  let container: String?
  let width: Int?
  let height: Int?
  let audioChannels: Int?

  init(id: String, type: String, title: String, originalTitle: String? = nil,
       year: Int? = nil, durationSeconds: Int? = nil, contentRating: String? = nil,
       rating: Double? = nil, summary: String? = nil, genres: [String]? = nil,
       cast: [Person]? = nil, images: Images? = nil, changeSeq: Int? = nil,
       videoCodec: String? = nil, audioCodec: String? = nil, container: String? = nil,
       width: Int? = nil, height: Int? = nil, audioChannels: Int? = nil) {
    self.id = id; self.type = type; self.title = title; self.originalTitle = originalTitle
    self.year = year; self.durationSeconds = durationSeconds; self.contentRating = contentRating
    self.rating = rating; self.summary = summary; self.genres = genres
    self.cast = cast; self.images = images; self.changeSeq = changeSeq
    self.videoCodec = videoCodec; self.audioCodec = audioCodec; self.container = container
    self.width = width; self.height = height; self.audioChannels = audioChannels
  }

  // MARK: - Derived format badges

  /// Short, capitalised quality/format badges for display, e.g. ["4K", "HDR-ready", "5.1"].
  /// Derived from resolution, codec, and channel count. Empty when specs are unknown.
  var qualityBadges: [String] {
    var badges: [String] = []
    if let w = width, let h = height {
      let longEdge = max(w, h)
      switch longEdge {
      case 3840...:        badges.append("4K")
      case 2560..<3840:    badges.append("1440p")
      case 1900..<2560:    badges.append("1080p")
      case 1200..<1900:    badges.append("720p")
      default: break
      }
    }
    // HEVC/AV1 commonly carry HDR; without color metadata we label the codec instead.
    switch (videoCodec ?? "").lowercased() {
    case "hevc", "h265": badges.append("HEVC")
    case "av1":          badges.append("AV1")
    default: break
    }
    if let ch = audioChannels {
      switch ch {
      case 8...:  badges.append("7.1")
      case 6, 7:  badges.append("5.1")
      default: break
      }
    }
    switch (audioCodec ?? "").lowercased() {
    case "truehd", "eac3": badges.append("Atmos-ready")
    case "dts":            badges.append("DTS")
    default: break
    }
    return badges
  }
}

// MARK: - Playback

struct Chapter: Decodable, Sendable {
  let id: Int
  let title: String
  let startSecs: Double
  let endSecs: Double
}

struct PlaybackInfo: Decodable {
  let kind: String
  let streamUrl: URL?
  let hlsMasterUrl: URL?
  let resumePositionSeconds: Int
  // Authoritative full runtime from the server's scan-time probe. A live-window HLS
  // playlist only reports the duration transcoded so far (the file transcodes at ~5x
  // realtime, so most isn't written at playback start), which makes AVPlayer's scrubber
  // pin to the end. The player falls back to this when it's larger than the item's
  // reported duration. Optional for backward compatibility with older servers.
  let durationSeconds: Int?
  let chapters: [Chapter]?
  let quality: String?
  // TASK-828: semantic subtitle metadata from the server's /playback response.
  // Additive — older servers omit it, so it's optional. The player still discovers
  // the actual text renditions from the HLS manifest; this array supplies the
  // "full vs forced vs image" semantics AVFoundation can't infer, plus which single
  // forced track should auto-enable (translation of foreign scenes).
  let subtitles: [Subtitle]?
}

/// A single subtitle track as described by the frozen `/playback subtitles[]` contract
/// (TASK-826). Matched to the player's AVMediaSelectionOptions by `language` (and `forced`
/// characteristic), not by array index — image subs occupy a slot but produce no rendition.
/// A subtitle track.
///
/// Every field decodes defensively. `PlaybackInfo.subtitles` is deliberately `[Subtitle]?`
/// so an older server that omits the key still plays — but that tolerance was defeated by
/// declaring all seven fields non-optional here: a server sending `subtitles` with any
/// subset of keys failed the whole PlaybackInfo decode, blanking the player screen rather
/// than degrading to "no subtitles". Missing fields now fall back to their neutral value.
struct Subtitle: Decodable, Hashable {
  /// HLS subtitle rendition playlist URL. `""` for image subs and direct/remux responses.
  let url: String
  /// BCP-47-ish lowercased tag (`"en"`, `"de"`); `"und"` when unknown.
  let language: String
  /// Human display label; already carries a `(Forced)` suffix for forced tracks.
  let name: String
  /// `"full"` | `"forced"` | `"image"`.
  let type: String
  /// True for translation-only/forced tracks.
  let forced: Bool
  /// Source-flagged default. Advisory.
  let `default`: Bool
  /// At most one track per item. When true, the client turns this track ON at
  /// playback start with no user action (foreign-scene translation case).
  let autoEnable: Bool

  enum CodingKeys: String, CodingKey {
    case url, language, name, type, forced, `default`, autoEnable
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    url = (try? c.decode(String.self, forKey: .url)) ?? ""
    language = (try? c.decode(String.self, forKey: .language)) ?? "und"
    type = (try? c.decode(String.self, forKey: .type)) ?? "full"
    forced = (try? c.decode(Bool.self, forKey: .forced)) ?? false
    `default` = (try? c.decode(Bool.self, forKey: .default)) ?? false
    autoEnable = (try? c.decode(Bool.self, forKey: .autoEnable)) ?? false
    // Name last: falls back to the language tag so a track is never unlabelled in the picker.
    name = (try? c.decode(String.self, forKey: .name)) ?? language.uppercased()
  }

  enum Kind: String { case full, forced, image, unknown }
  var kind: Kind { Kind(rawValue: type) ?? .unknown }
  /// Image subs are surfaced but never fetched/selectable.
  var isImage: Bool { kind == .image }
}

// MARK: - Progress

struct ProgressRequest: Encodable {
  let positionSeconds: Int
  let durationSeconds: Int
  let state: String?
}

struct ProgressResponse: Decodable {
  let ok: Bool
}

struct ProgressBatchResponse: Decodable {
  let progress: [String: ItemProgress]
}

// MARK: - TMDb Manual Fix

struct TMDbCandidate: Decodable, Identifiable {
  let tmdbId: Int
  let title: String
  let year: Int?
  let overview: String?
  let posterPath: String?
  let type: String

  var id: Int { tmdbId }

  var posterURL: URL? {
    guard let path = posterPath, !path.isEmpty else { return nil }
    return URL(string: "https://image.tmdb.org/t/p/w342\(path)")
  }
}

struct TMDbSearchResponse: Decodable {
  let results: [TMDbCandidate]
}

// MARK: - Pairing

struct PairingCodeResponse: Decodable {
  let code: String
  let expiresInSeconds: Int

  /// The server sends `expires_in_seconds` in snake_case — the ONLY snake_case key in an
  /// otherwise camelCase API (backend main.go, handlePairingGenerate).
  ///
  /// Without this mapping the decode threw `keyNotFound` on every call, so
  /// `generatePairingCode()` always failed and the Apple TV pairing screen could never
  /// display a code. It failed silently: AppState catches the error into `pairingError`,
  /// so the UI showed a generic failure rather than anything pointing at a decode problem.
  ///
  /// Fixed here rather than by renaming the server key (which would break already-deployed
  /// clients) or by setting a global `.convertFromSnakeCase` strategy (which would break
  /// every other response, all of which are camelCase). Same defect class as the
  /// `ItemsResponse.total` bug that silently broke Watchlist on every platform.
  enum CodingKeys: String, CodingKey {
    case code
    case expiresInSeconds = "expires_in_seconds"
  }
}

struct PairingCodeExchangeRequest: Encodable {
  let code: String
}

// MARK: - Delta Sync

struct ServerVersion: Decodable {
  let serverVersion: String
  let minClientVersion: String
  let capabilities: [String]
}

struct SyncStatusResponse: Decodable {
  let itemSeq: Int
  let progressSeq: Int
  /// Optional because the server already calls this a placeholder it intends to remove
  /// (`"totalItems": 0`, main.go — the COUNT(*) behind it was dropped as a full table scan).
  ///
  /// This is the worst possible field to leave non-optional: syncStatus() is the SECOND
  /// reconnect probe, so the day the server stops emitting the placeholder, every reconnect
  /// would throw a DecodingError and the app would go permanently unreachable — with a
  /// connection error pointing at a server that was answering fine.
  let totalItems: Int?
  var effectiveTotalItems: Int { totalItems ?? 0 }
}

struct SyncHeartbeatResponse: Decodable {
  let itemSeq: Int
  let progressSeq: Int
  let serverTimeMs: Int64
}

struct SyncItemsResponse: Decodable {
  let items: [ItemSummary]
  let nextSeq: Int
  let hasMore: Bool
  let nextAfterRowid: Int?
}

struct SyncDeletedResponse: Decodable {
  let deletedIds: [String]
  let asOf: Int
}
