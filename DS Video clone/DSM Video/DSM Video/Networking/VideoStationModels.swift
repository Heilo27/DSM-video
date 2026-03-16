import Foundation

// MARK: - Response Envelope

struct WebAPIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: WebAPIErrorDetail?

    // Handle both success and error responses
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)

        if success {
            data = try container.decode(T.self, forKey: .data)
            error = nil
        } else {
            data = nil
            error = try container.decodeIfPresent(WebAPIErrorDetail.self, forKey: .error)
        }
    }

    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
}

struct WebAPIErrorResponse: Decodable {
    let success: Bool
    let error: WebAPIErrorDetail
}

struct WebAPIErrorDetail: Decodable {
    let code: Int
    let errors: [String]?
}

// MARK: - Auth Models

struct WebAPILoginData: Decodable {
    let sid: String
    let synotoken: String?
    let did: String?  // Device ID - needed for Cookie header

    enum CodingKeys: String, CodingKey {
        case sid
        case synotoken
        case did
    }
}

struct WebAPILoginResponse {
    let sid: String
    let synotoken: String?
    let did: String?  // Device ID
}

// MARK: - Libraries Models

struct VideoStationLibrariesData: Decodable {
    let libraries: [VideoStationLibrary]?

    // Video Station returns libraries in 'library' field (singular)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try 'library' (singular) first - this is what Video Station actually returns
        if let libraryArray = try? container.decode([VideoStationLibrary].self, forKey: .library) {
            libraries = libraryArray
        } else if let libraryArray = try? container.decode([VideoStationLibrary].self, forKey: .libraries) {
            // Fallback to 'libraries' (plural) for compatibility
            libraries = libraryArray
        } else {
            libraries = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case library  // Video Station uses singular
        case libraries // Fallback for plural
    }
}

struct VideoStationLibrary: Decodable {
    let id: Int
    let name: String
    let type: String?

    // Handle different possible field names
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try different possible ID formats
        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id) {
            id = Int(stringId) ?? 0
        } else {
            id = 0
        }

        // Try different name fields
        name = (try? container.decode(String.self, forKey: .name)) ??
               (try? container.decode(String.self, forKey: .title)) ??
               (try? container.decode(String.self, forKey: .library_name)) ??
               ""

        type = try? container.decode(String.self, forKey: .type)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case library_name
        case type
    }
}

// MARK: - Items Models

struct VideoStationItemsData: Decodable {
    let total: Int
    let items: [VideoStationItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try different possible field names for total
        if let intTotal = try? container.decode(Int.self, forKey: .total) {
            total = intTotal
        } else if let stringTotal = try? container.decode(String.self, forKey: .total) {
            total = Int(stringTotal) ?? 0
        } else {
            total = 0
        }

        // Try different possible field names for items
        // Video Station returns "movie" (singular) for movie library, "tvshow" for TV shows, etc.
        if let movieItems = try? container.decode([VideoStationItem].self, forKey: .movie) {
            items = movieItems
        } else if let tvItems = try? container.decode([VideoStationItem].self, forKey: .tvshow) {
            items = tvItems
        } else if let homeItems = try? container.decode([VideoStationItem].self, forKey: .homevideo) {
            items = homeItems
        } else if let movieItems = try? container.decode([VideoStationItem].self, forKey: .items) {
            items = movieItems
        } else if let movieItems = try? container.decode([VideoStationItem].self, forKey: .movies) {
            items = movieItems
        } else if let movieItems = try? container.decode([VideoStationItem].self, forKey: .data) {
            items = movieItems
        } else {
            items = []
        }
    }

    enum CodingKeys: String, CodingKey {
        case total
        case items
        case movies
        case data
        case movie      // Video Station uses singular
        case tvshow     // TV shows
        case homevideo  // Home videos
    }
}

struct VideoStationItem: Decodable {
    let id: Int
    let title: String
    let type: String?
    let year: Int?
    let duration: Int?
    let added_at: String?
    let rating: Double?
    let poster: String?
    let backdrop: String?
    let mapper_id: Int?
    let watch_status: VideoStationWatchStatus?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle different ID formats
        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id) {
            id = Int(stringId) ?? 0
        } else {
            id = 0
        }

        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        type = try? container.decode(String.self, forKey: .type)

        // Try year field, or extract from original_available (e.g., "1977" or "2010-11-12")
        if let yearValue = try? container.decode(Int.self, forKey: .year) {
            year = yearValue
        } else if let originalAvailable = try? container.decode(String.self, forKey: .original_available) {
            // Extract year from date string (e.g., "1977" or "2010-11-12")
            if let yearInt = Int(originalAvailable.prefix(4)) {
                year = yearInt
            } else {
                year = nil
            }
        } else {
            year = nil
        }

        duration = try? container.decode(Int.self, forKey: .duration)

        // Handle added_at - can be string or timestamp (create_time)
        if let addedAtString = try? container.decode(String.self, forKey: .added_at) {
            added_at = addedAtString
        } else if let createTime = try? container.decode(Int.self, forKey: .create_time) {
            added_at = String(createTime)
        } else {
            added_at = nil
        }

        rating = try? container.decode(Double.self, forKey: .rating)

        // Poster/backdrop might be in different fields or need mapper_id
        // Try poster/backdrop first, then mapper_id as fallback
        if let posterString = try? container.decode(String.self, forKey: .poster) {
            poster = posterString
        } else if let mapperId = try? container.decode(Int.self, forKey: .mapper_id) {
            poster = String(mapperId)
        } else {
            poster = nil
        }

        if let backdropString = try? container.decode(String.self, forKey: .backdrop) {
            backdrop = backdropString
        } else if let mapperId = try? container.decode(Int.self, forKey: .mapper_id) {
            backdrop = String(mapperId)
        } else {
            backdrop = nil
        }

        mapper_id = try? container.decode(Int.self, forKey: .mapper_id)
        watch_status = try? container.decode(VideoStationWatchStatus.self, forKey: .watch_status)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case year
        case original_available
        case duration
        case added_at
        case create_time
        case rating
        case poster
        case backdrop
        case mapper_id
        case watch_status
    }
}

struct VideoStationWatchStatus: Decodable {
    let time: Int?
    let total_time: Int?
    let updated_at: String?
}

// Video Station returns detail as array: {"data":{"movie":[{...}]}}
struct VideoStationItemDetailArrayData: Decodable {
    let item: VideoStationItemDetail?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try movie array first
        if let movieArray = try? container.decode([VideoStationItemDetail].self, forKey: .movie), let first = movieArray.first {
            item = first
        } else if let tvArray = try? container.decode([VideoStationItemDetail].self, forKey: .tvshow), let first = tvArray.first {
            item = first
        } else if let homeArray = try? container.decode([VideoStationItemDetail].self, forKey: .homevideo), let first = homeArray.first {
            item = first
        } else {
            item = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case movie
        case tvshow
        case homevideo
    }
}

struct VideoStationItemDetail: Decodable {
    let id: Int
    let title: String
    let type: String?
    let original_title: String?
    let year: Int?
    let duration: Int?
    let rating: String?
    let summary: String?
    let genres: [String]?
    let actors: [VideoStationActor]?
    let poster: String?
    let backdrop: String?
    let mapper_id: Int? // Added for backdrop API (uses mapper_id)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        type = try? container.decode(String.self, forKey: .type)
        original_title = try? container.decode(String.self, forKey: .original_title)
        year = try? container.decode(Int.self, forKey: .year)
        duration = try? container.decode(Int.self, forKey: .duration)
        rating = try? container.decode(String.self, forKey: .rating)
        summary = try? container.decode(String.self, forKey: .summary)
        genres = try? container.decode([String].self, forKey: .genres)
        actors = try? container.decode([VideoStationActor].self, forKey: .actors)

        // Decode mapper_id first (needed for backdrop API)
        mapper_id = try? container.decode(Int.self, forKey: .mapper_id)

        // Poster/backdrop might be in different fields or need mapper_id
        if let posterString = try? container.decode(String.self, forKey: .poster) {
            poster = posterString
        } else if let mapperId = mapper_id {
            poster = String(mapperId)
        } else {
            poster = nil
        }

        if let backdropString = try? container.decode(String.self, forKey: .backdrop) {
            backdrop = backdropString
        } else if let mapperId = mapper_id {
            backdrop = String(mapperId)
        } else {
            backdrop = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case original_title
        case year
        case duration
        case rating
        case summary
        case genres
        case actors
        case poster
        case backdrop
        case mapper_id
    }
}

struct VideoStationActor: Decodable {
    let name: String
    let role: String?
}

// MARK: - Streaming Models

/// Response from streaming open method
struct VideoStationStreamOpenData: Decodable {
    let stream_id: String?
    let format: String?

    enum CodingKeys: String, CodingKey {
        case stream_id
        case format
    }
}

struct VideoStationStreamingData: Decodable {
    let stream: VideoStationStream
}

struct VideoStationStream: Decodable {
    let url: String?
    let hls_url: String?
    let resume_time: Int?
}

struct VideoStationUpdateResponse: Decodable {
    let success: Bool
}

// MARK: - Errors

enum WebAPIError: Error {
    case invalidURL
    case network
    case http(Int)
    case server(Int, [String]?)
    case decode(Error)
    case loginFailed
    case notImplemented

    var userMessage: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .network:
            return "Network error. Check your connection and try again."
        case .http(let code):
            return "HTTP error (\(code))"
        case .server(let code, let errors):
            // Provide more specific messages for common Video Station error codes
            if code == 101 {
                return "Invalid parameter. The video may not be accessible for streaming."
            } else if code == 1101 {
                return "File not found. The video file may not exist or is not indexed."
            }
            return "Server error (\(code)): \(errors?.joined(separator: ", ") ?? "Unknown")"
        case .decode(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .loginFailed:
            return "Login failed. Check your username and password."
        case .notImplemented:
            return "Not yet implemented"
        }
    }
}
