import Foundation
#if os(iOS)
import CoreSpotlight
import UIKit
import UniformTypeIdentifiers
#endif

// MARK: - Spotlight indexer (FR-153, TASK-743)

/// Carries out what SpotlightPolicy decided. Protocol so AppState's wiring is testable without
/// the system index, and so tvOS (which shares this source folder and has no CoreSpotlight
/// index to feed) gets a no-op.
protocol SpotlightIndexing: AnyObject {
  /// Brings the index in line with `entries` (the manifest diff: add, update, delete).
  /// `artwork` turns a poster image id into small thumbnail bytes, or nil.
  func sync(entries: [SpotlightEntry], artwork: @escaping (String) async -> Data?) async
  /// Removes every entry and forgets what was indexed.
  func clear() async
}

/// tvOS, and anything that must not touch the system index.
final class NoSpotlightIndexer: SpotlightIndexing {
  func sync(entries: [SpotlightEntry], artwork: @escaping (String) async -> Data?) async {}
  func clear() async {}
}

enum SpotlightIndexerFactory {
  static func make() -> SpotlightIndexing {
    #if os(iOS)
    CoreSpotlightIndexer()
    #else
    NoSpotlightIndexer()
    #endif
  }
}

#if os(iOS)

/// The CSSearchableIndex implementation.
///
/// What is indexed: title, year, show name, a small poster thumbnail. Never a stream URL, a
/// token or the poster URL (S4). The thumbnail is bytes made at index time; nothing here keeps
/// the image id after the call.
///
/// The manifest (identifier -> what was indexed) lives in UserDefaults so a relaunch diffs
/// against what is really in the system index rather than re-adding everything.
final class CoreSpotlightIndexer: SpotlightIndexing {
  /// Pictures fetched per pass. A NAS library can be thousands of titles; fetching all their
  /// posters at once would hammer the NAS and the phone. Entries beyond the cap are indexed
  /// without a picture and get one on a later pass (SpotlightPolicy.changes retries them).
  static let artworkPerPass = 150
  private static let manifestKey = "dsReel.spotlight.manifest"
  /// CoreSpotlight takes batches; one call with thousands of items is a memory spike.
  private static let batchSize = 100

  private let index: CSSearchableIndex
  private let defaults: UserDefaults

  init(index: CSSearchableIndex = .default(), defaults: UserDefaults = .standard) {
    self.index = index
    self.defaults = defaults
  }

  private var manifest: [String: String] {
    get { defaults.dictionary(forKey: Self.manifestKey) as? [String: String] ?? [:] }
    set { defaults.set(newValue, forKey: Self.manifestKey) }
  }

  func sync(entries: [SpotlightEntry], artwork: @escaping (String) async -> Data?) async {
    var stored = manifest
    let changes = SpotlightPolicy.changes(desired: entries, manifest: stored)
    guard !changes.isEmpty else { return }

    if !changes.deletes.isEmpty {
      do {
        try await index.deleteSearchableItems(withIdentifiers: changes.deletes)
        for id in changes.deletes { stored[id] = nil }
        manifest = stored
      } catch {
        // Kept in the manifest, so the next pass tries again.
        NSLog("Spotlight: delete failed - \(error.localizedDescription)")
      }
    }

    var artworkBudget = Self.artworkPerPass
    for batch in changes.upserts.chunked(into: Self.batchSize) {
      if Task.isCancelled { return }
      var items: [CSSearchableItem] = []
      var withArt: [String: Bool] = [:]
      for entry in batch {
        var thumbnail: Data?
        if artworkBudget > 0, let posterID = entry.posterImageId {
          artworkBudget -= 1
          thumbnail = await artwork(posterID)
        }
        withArt[entry.id] = thumbnail != nil
        items.append(Self.searchableItem(for: entry, thumbnail: thumbnail))
      }
      // A cancelled pass (profile switch, sign-out) must not index titles for the old scope.
      if Task.isCancelled { return }
      do {
        try await index.indexSearchableItems(items)
        for entry in batch {
          stored[entry.id] = SpotlightPolicy.manifestValue(for: entry, withArtwork: withArt[entry.id] ?? false)
        }
        manifest = stored
      } catch {
        NSLog("Spotlight: index failed - \(error.localizedDescription)")
      }
    }
  }

  func clear() async {
    do {
      try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightPolicy.domainIdentifier])
    } catch {
      NSLog("Spotlight: clear failed - \(error.localizedDescription)")
    }
    // Forgotten even if the system call failed: the next pass then re-adds everything it should,
    // and a stale manifest can never claim an entry is indexed that the profile may not see.
    defaults.removeObject(forKey: Self.manifestKey)
  }

  private static func searchableItem(for entry: SpotlightEntry, thumbnail: Data?) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .movie)
    attributes.title = entry.title
    attributes.displayName = entry.title
    attributes.contentDescription = entry.subtitle
    attributes.thumbnailData = thumbnail
    let item = CSSearchableItem(
      uniqueIdentifier: entry.id, domainIdentifier: SpotlightPolicy.domainIdentifier,
      attributeSet: attributes)
    return item
  }
}

extension Array {
  fileprivate func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
  }
}

/// Small JPEG for a poster, bounded in size. Spotlight shows a tiny square; this keeps each
/// entry to a few KB.
nonisolated enum SpotlightArtwork {
  static let maxPixelWidth: CGFloat = 200

  static func thumbnailData(from image: UIImage) -> Data? {
    let scale = min(1, maxPixelWidth / max(image.size.width, 1))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    return scaled.jpegData(compressionQuality: 0.7)
  }
}

#endif
