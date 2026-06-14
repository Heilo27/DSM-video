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
  let total: Int
  let items: [ItemSummary]
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
  let images: Images
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
       cast: [Person]? = nil, images: Images, changeSeq: Int? = nil,
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
  let chapters: [Chapter]?
  let quality: String?
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
  let totalItems: Int
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
