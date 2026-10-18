import SwiftUI

/// The one 2:3 poster card: movie grid cell, TV-show grid cell and collection tile all render
/// through this shell, so radius, scrim, progress bar, watched badge and Cinematic depth are
/// decided in one place (TASK-955). A call site supplies only what differs: the artwork, and
/// the footer text laid over it.
///
/// Layout contract. The card's width comes from its parent; its height is always width x 1.5.
/// Neither depends on the artwork or the footer, so an image that has not loaded yet (or never
/// loads) cannot collapse the cell or reflow the grid when it arrives.
///
/// Not used by the tvOS portrait cards (`TVPortraitCard`, `TVShowPortraitCard`): they put the
/// title BELOW the artwork and scale on focus, so they are a different layout. They share the
/// radius token (`.dsRadiusPoster`) and `CardWatchedBadge` with this shell.
struct PosterCard<Art: View, Footer: View>: View {
  let indicator: PlaybackProgress.CardIndicator
  private let art: (_ width: CGFloat, _ height: CGFloat) -> Art
  private let footer: Footer

  /// - Parameters:
  ///   - indicator: what the card shows for playback state (bar, watched badge, nothing).
  ///   - art: the artwork, handed the exact size it must fill.
  ///   - footer: text laid over the bottom of the artwork. It owns its own padding and fonts.
  init(
    indicator: PlaybackProgress.CardIndicator = .none,
    @ViewBuilder art: @escaping (_ width: CGFloat, _ height: CGFloat) -> Art,
    @ViewBuilder footer: () -> Footer
  ) {
    self.indicator = indicator
    self.art = art
    self.footer = footer()
  }

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height = width * (3.0 / 2.0)

      ZStack(alignment: .bottom) {
        art(width, height)
        // TASK-857: the gradient's opaque region is a fixed fraction of card height, so at
        // accessibility text sizes the footer grew up past it and drew unreadably over bare
        // poster art (title text on top of the poster's own baked-in title). Backing the
        // footer with a scrim sized to the footer's MEASURED height keeps text legible at
        // every Dynamic Type size instead of only the ones that happen to fit under 45%.
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.45),
            .init(color: .black.opacity(0.85), location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        footer
          .background(alignment: .bottom) {
            LinearGradient(
              colors: [.black.opacity(0), .black.opacity(0.85), .black.opacity(0.92)],
              startPoint: .top,
              endPoint: .bottom
            )
            .padding(.top, -14)   // fade in above the text rather than starting hard at it
            .allowsHitTesting(false)
          }

        // Progress bar, pinned to the bottom edge INSIDE the clip. Whether and how wide is
        // PlaybackProgress.cardIndicator's call (TASK-978), shared with the tvOS cards.
        if case .bar(let frac) = indicator {
          GeometryReader { barGeo in
            ZStack(alignment: .leading) {
              Rectangle()
                .fill(Color.dsBorderStrong)
                .frame(height: 3)
              Rectangle()
                .fill(Color.dsAccent)
                .frame(width: barGeo.size.width * frac, height: 3)
            }
          }
          .frame(height: 3)
          .accessibilityHidden(true)
        }
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: .dsRadiusPoster, style: .continuous))
      // Outside the clip so the badge is never trimmed by the corner radius.
      .cardWatchedBadge(indicator)
      // Ambient elevation on the Cinematic theme; no-op on flat themes.
      .dsCardDepth()
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
    .contentShape(RoundedRectangle(cornerRadius: .dsRadiusPoster, style: .continuous))
    // TASK-693/698: redact poster + title in the app switcher / screen recordings.
    .privacySensitive()
  }
}
