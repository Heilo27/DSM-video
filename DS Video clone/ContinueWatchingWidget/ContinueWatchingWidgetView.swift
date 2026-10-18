import ImageIO
import SwiftUI
import WidgetKit

// MARK: - Continue Watching widget views (FR-154 display rules)
//
// SwiftUI + ImageIO only (no UIKit), so the same file also renders off-device for review.
// Everything drawn comes from ContinueWatchingSnapshot.Entry: no image is ever fetched here.

/// Picks the layout for the family WidgetKit is drawing.
struct ContinueWatchingWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entries: [ContinueWatchingSnapshot.Entry]

  var body: some View {
    ContinueWatchingLayout(family: family, entries: entries)
      .containerBackground(.background, for: .widget)
  }
}

/// The layout for one family, given explicitly so a render can choose it.
struct ContinueWatchingLayout: View {
  let family: WidgetFamily
  let entries: [ContinueWatchingSnapshot.Entry]

  var body: some View {
    if entries.isEmpty {
      ContinueWatchingPlaceholder()
    } else if family == .systemMedium {
      MediumContinueWatching(entries: Array(entries.prefix(ContinueWatchingSnapshotPolicy.maxItems)))
    } else if let first = entries.first {
      SmallContinueWatching(entry: first)
    }
  }
}

// MARK: - Empty

/// Shown for a missing file, no entries, or another profile's snapshot: calm, not an error.
struct ContinueWatchingPlaceholder: View {
  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: "play.rectangle")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("Nothing in progress")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Small: the most recent title

struct SmallContinueWatching: View {
  let entry: ContinueWatchingSnapshot.Entry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      PosterTile(entry: entry, showsTitleOnArtwork: false)
        .frame(width: 52, height: 78)
      Spacer(minLength: 0)
      Text(entry.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
      if let subtitle = entry.subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let progress = ContinueWatchingDisplay.clampedProgress(entry.progress) {
        ProgressBar(value: progress)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ContinueWatchingDisplay.accessibilityLabel(for: entry))
    .widgetURL(ContinueWatchingDisplay.deepLink(for: entry))
  }
}

// MARK: - Medium: up to four posters

struct MediumContinueWatching: View {
  let entries: [ContinueWatchingSnapshot.Entry]

  private let spacing: CGFloat = 8

  var body: some View {
    GeometryReader { proxy in
      let slots = CGFloat(ContinueWatchingSnapshotPolicy.maxItems)
      let tileWidth = (proxy.size.width - spacing * (slots - 1)) / slots
      HStack(alignment: .top, spacing: spacing) {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
          MediumTile(entry: entry)
            .frame(width: tileWidth)
        }
        Spacer(minLength: 0)
      }
      .frame(maxHeight: .infinity, alignment: .center)
    }
  }
}

struct MediumTile: View {
  let entry: ContinueWatchingSnapshot.Entry

  var body: some View {
    let tile = VStack(spacing: 6) {
      PosterTile(entry: entry, showsTitleOnArtwork: true)
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
      if let progress = ContinueWatchingDisplay.clampedProgress(entry.progress) {
        ProgressBar(value: progress)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ContinueWatchingDisplay.accessibilityLabel(for: entry))

    if let url = ContinueWatchingDisplay.deepLink(for: entry) {
      Link(destination: url) { tile }
    } else {
      tile
    }
  }
}

// MARK: - Pieces

/// The entry's poster from its thumbnail bytes, or a tile with the title when there is none.
struct PosterTile: View {
  let entry: ContinueWatchingSnapshot.Entry
  /// Medium tiles have no caption, so a missing poster must still say what the title is.
  let showsTitleOnArtwork: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    ZStack {
      if let image = ContinueWatchingDisplay.posterImage(from: entry.thumbnail) {
        Image(decorative: image, scale: 1)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        shape.fill(.quaternary)
        if showsTitleOnArtwork {
          Text(entry.title)
            .font(.caption2.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.8)
            .padding(4)
        } else {
          Image(systemName: "film")
            .foregroundStyle(.secondary)
        }
      }
    }
    .clipShape(shape)
  }
}

/// A thin, fixed-height progress bar (the system linear style varies by platform).
struct ProgressBar: View {
  let value: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(.tint)
          .frame(width: max(proxy.size.height, proxy.size.width * value))
      }
    }
    .frame(height: 4)
  }
}

/// The display rules the views share, in one place.
enum ContinueWatchingDisplay {
  /// Posters are decoded no larger than this (pixels): a medium tile is ~70pt wide at 3x.
  static let maxPosterPixelSize = 320

  /// The bar's fill, or nil when there is no meaningful ratio (no bar at all, not an empty one).
  static func clampedProgress(_ progress: Double?) -> Double? {
    guard let progress, progress.isFinite else { return nil }
    return min(max(progress, 0), 1)
  }

  static func deepLink(for entry: ContinueWatchingSnapshot.Entry) -> URL? {
    URL(string: ItemDeepLink.urlString(itemID: entry.id))
  }

  /// "Title, S2 · E4, 40 percent watched", leaving out whatever is unknown.
  static func accessibilityLabel(for entry: ContinueWatchingSnapshot.Entry) -> String {
    var parts = [entry.title]
    if let subtitle = entry.subtitle { parts.append(subtitle) }
    if let progress = clampedProgress(entry.progress) {
      parts.append("\(Int((progress * 100).rounded())) percent watched")
    }
    return parts.joined(separator: ", ")
  }

  /// Decodes the snapshot's JPEG, downsampled, or nil for missing or unreadable bytes (which then
  /// draw as the title tile rather than failing the widget).
  static func posterImage(from data: Data?) -> CGImage? {
    guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPosterPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}
