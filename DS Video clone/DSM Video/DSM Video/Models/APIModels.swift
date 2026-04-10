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

/// Lightweight per-library stat returned by GET /api/v1/libraries/summary.
/// Used to detect additions/removals (count) and metadata rescans (lastUpdatedAt)
/// without fetching any item data.
struct LibrarySummary: Decodable, Sendable {
  let libraryId: String
  let count: Int
  let lastUpdatedAt: String
}

struct LibrarySummariesResponse: Decodable {
  let libraries: [LibrarySummary]
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
  let seasonNumber: Int?
  let episodeNumber: Int?
  // Delta sync metadata — nil when decoded from legacy API responses
  let libraryId: String?
  let changeSeq: Int?

  nonisolated init(id: String, type: String, title: String, year: Int? = nil,
                   durationSeconds: Int? = nil, addedAt: String, rating: Double? = nil,
                   posterImageId: String? = nil, backdropImageId: String? = nil,
                   progress: ItemProgress? = nil, showName: String? = nil,
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
                showName: showName, seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                libraryId: libraryId, changeSeq: changeSeq)
  }
}

// MARK: - TV Shows

struct TVShow: Decodable, Identifiable, Hashable {
  let id: String
  let title: String
  let year: Int?
  let seasonCount: Int
  let episodeCount: Int
  let posterImageId: String?
  let lastWatchedAt: String?
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
}

// MARK: - Playback

struct PlaybackInfo: Decodable {
  let kind: String
  let streamUrl: URL?
  let hlsMasterUrl: URL?
  let resumePositionSeconds: Int
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
