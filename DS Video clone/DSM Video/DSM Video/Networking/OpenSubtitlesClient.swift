import Foundation

// Set this to your OpenSubtitles.com API key to enable subtitle search and download.
// Get a free key at https://www.opensubtitles.com/consumers
// Leave empty to disable the feature (search button will show a "not configured" message).
let OpenSubtitlesAPIKey = ""

// BCP-47 language code for subtitle search. "en" = English.
// Override to your preferred language, e.g. "fr", "de", "es", "ja".
let OpenSubtitlesLanguage = "en"

enum OpenSubtitlesError: LocalizedError {
  case notConfigured
  case invalidAPIKey
  case quotaExceeded
  case rateLimited
  var errorDescription: String? {
    switch self {
    case .notConfigured: return "Subtitle search requires an OpenSubtitles API key. See OpenSubtitlesClient.swift to configure one."
    case .invalidAPIKey: return "OpenSubtitles API key is invalid. Check your key at opensubtitles.com."
    case .quotaExceeded: return "OpenSubtitles daily download quota exceeded. Try again tomorrow."
    case .rateLimited:   return "Too many subtitle requests. Please wait a moment and try again."
    }
  }
}

struct SubtitleResult: Identifiable, Sendable {
  let id: Int
  let fileName: String
  let language: String
  let downloadCount: Int
}

struct OpenSubtitlesClient {
  private let baseURL = URL(string: "https://api.opensubtitles.com/api/v1")!
  private let userAgent = "DSMVideo v1"

  func searchSubtitles(query: String, year: Int?) async throws -> [SubtitleResult] {
    guard !OpenSubtitlesAPIKey.isEmpty else { throw OpenSubtitlesError.notConfigured }
    guard var comps = URLComponents(url: baseURL.appendingPathComponent("subtitles"), resolvingAgainstBaseURL: false) else {
      throw URLError(.badURL)
    }
    var queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "languages", value: OpenSubtitlesLanguage)]
    if let y = year { queryItems.append(URLQueryItem(name: "year", value: String(y))) }
    comps.queryItems = queryItems
    guard let url = comps.url else { throw URLError(.badURL) }

    var req = URLRequest(url: url)
    req.setValue(OpenSubtitlesAPIKey, forHTTPHeaderField: "Api-Key")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await URLSession.shared.data(for: req)
    if let http = response as? HTTPURLResponse {
      switch http.statusCode {
      case 401: throw OpenSubtitlesError.invalidAPIKey
      case 406: throw OpenSubtitlesError.quotaExceeded
      case 429: throw OpenSubtitlesError.rateLimited
      default: break
      }
    }

    struct Response: Decodable {
      struct Item: Decodable {
        struct Attributes: Decodable {
          struct File: Decodable {
            let fileId: Int
            let fileName: String
            enum CodingKeys: String, CodingKey {
              case fileId = "file_id"
              case fileName = "file_name"
            }
          }
          let language: String
          let downloadCount: Int
          let files: [File]
          enum CodingKeys: String, CodingKey {
            case language
            case downloadCount = "download_count"
            case files
          }
        }
        let attributes: Attributes
      }
      let data: [Item]
    }

    let decoded = try JSONDecoder().decode(Response.self, from: data)
    return decoded.data.compactMap { item in
      guard let file = item.attributes.files.first else { return nil }
      return SubtitleResult(
        id: file.fileId,
        fileName: file.fileName,
        language: item.attributes.language,
        downloadCount: item.attributes.downloadCount
      )
    }
  }

  func downloadSubtitle(fileId: Int) async throws -> URL {
    guard !OpenSubtitlesAPIKey.isEmpty else { throw OpenSubtitlesError.notConfigured }
    let url = baseURL.appendingPathComponent("download")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(OpenSubtitlesAPIKey, forHTTPHeaderField: "Api-Key")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(["file_id": fileId])

    let (data, dlResponse) = try await URLSession.shared.data(for: req)
    if let http = dlResponse as? HTTPURLResponse {
      switch http.statusCode {
      case 401: throw OpenSubtitlesError.invalidAPIKey
      case 406: throw OpenSubtitlesError.quotaExceeded
      case 429: throw OpenSubtitlesError.rateLimited
      default: break
      }
    }

    struct DownloadResponse: Decodable {
      let link: String
    }

    let decoded = try JSONDecoder().decode(DownloadResponse.self, from: data)
    guard let downloadURL = URL(string: decoded.link) else { throw URLError(.badURL) }

    let (fileData, _) = try await URLSession.shared.data(from: downloadURL)
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".srt")
    try fileData.write(to: tempURL)
    return tempURL
  }
}
