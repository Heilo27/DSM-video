import Foundation

/// Lightweight snapshot written by the main app and read by the Top Shelf extension.
/// Stored as JSON in the shared App Group container (topshelf.json).
struct TopShelfItem: Codable, Sendable {
    let id: String
    let title: String
    let year: Int?
    let imageURL: String?   // full URL string including auth token as query param
    let deepLinkURL: String // dsvideo://item/{id}
}
