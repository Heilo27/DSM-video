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

struct Library: Decodable, Identifiable, Hashable {
  let id: String
  let title: String
  let kind: String
}

// MARK: - Items

struct ItemsResponse: Decodable {
  let total: Int
  let items: [ItemSummary]
}

struct ItemProgress: Decodable, Hashable {
  let positionSeconds: Int
  let durationSeconds: Int
  let updatedAt: String
}

struct ItemSummary: Decodable, Identifiable, Hashable {
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
  let seasonNumber: Int?
  let episodeNumber: Int?
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
  let genres: [String]
  let cast: [Person]
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
