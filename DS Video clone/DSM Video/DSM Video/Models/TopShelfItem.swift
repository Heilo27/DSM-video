import Foundation

/// Lightweight snapshot written by the main app and read by the Top Shelf extension.
/// Stored as JSON in the shared App Group container (topshelf.json).
struct TopShelfItem: Codable, Sendable {
    let id: String
    let title: String
    let year: Int?
    let imageURL: String?   // tokenless image URL (TASK-774: never persist the session token here)
    let deepLinkURL: String // dsvideo://item/{id}

    /// How far through the item the viewer is, 0...1, or nil when unwatched.
    ///
    /// The whole point of a Continue Watching shelf is showing where you left off, and
    /// tvOS draws that bar itself from TVTopShelfSectionedItem.playbackProgress — but only
    /// if it is given a value. Optional rather than defaulting to 0 so an unwatched item
    /// renders with no bar instead of an empty one suggesting "just started".
    ///
    /// Optional in the Codable sense too: a topshelf.json written by an older build has no
    /// such key, and decoding must not fail and blank the whole shelf.
    var playbackProgress: Double?
}

/// The file the app writes and the Top Shelf extension reads.
///
/// Carries the heading because the APP decides which rail it wrote — Continue Watching, or
/// Just Added when nothing is in progress. The extension cannot know which without being
/// told, and inferring it from the data would be a second rule to keep in sync.
///
/// The extension also accepts the legacy bare-array form, so an installed build's existing
/// topshelf.json keeps working until the app next writes one.
struct TopShelfSnapshot: Codable, Sendable {
    let sectionTitle: String
    let items: [TopShelfItem]
}
