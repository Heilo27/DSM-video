import SwiftUI

/// The check drawn in a card's top-right corner when `PlaybackProgress.cardIndicator` says the
/// title is complete. One view for every card shape (iOS poster, iOS landscape, tvOS portrait,
/// tvOS landscape) so the badge cannot drift between them (TASK-1018). Only the size differs,
/// and only by platform: tvOS is read from across a room.
struct CardWatchedBadge: View {
  enum Size {
    case compact   // iOS cards
    case tv        // tvOS cards

    fileprivate var diameter: CGFloat { self == .tv ? 28 : 22 }
    fileprivate var glyph: CGFloat { self == .tv ? 13 : 11 }
    fileprivate var inset: CGFloat { self == .tv ? 8 : 6 }
  }

  let size: Size

  var body: some View {
    Circle()
      .fill(Color.dsSuccess)
      .frame(width: size.diameter, height: size.diameter)
      .overlay(
        Image(systemName: "checkmark")
          .font(.system(size: size.glyph, weight: .bold))
          .foregroundStyle(.black)
      )
      .padding(size.inset)
      .accessibilityHidden(true)
  }
}

extension View {
  /// Overlays the watched badge on the top-trailing corner when `indicator` is `.watchedBadge`;
  /// does nothing for `.none` and `.bar`. Apply outside the card's clip so a theme with a large
  /// corner radius cannot trim the badge.
  func cardWatchedBadge(
    _ indicator: PlaybackProgress.CardIndicator,
    size: CardWatchedBadge.Size = .compact
  ) -> some View {
    overlay(alignment: .topTrailing) {
      if indicator == .watchedBadge {
        CardWatchedBadge(size: size)
      }
    }
  }
}
