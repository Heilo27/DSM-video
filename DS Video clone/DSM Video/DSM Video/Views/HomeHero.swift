import SwiftUI

// MARK: - HomeHero
//
// The Cinematic theme's flagship element: a full-bleed featured title at the top of Home.
// Renders ONLY on the Cinematic theme (`usesCinematicChrome`) — on Classic / Nitrate it
// is an EmptyView, so those themes' Home layout is unchanged. Auto-rotates through the
// first few featured items. Play and tap both push the same ItemDetailView the rail
// cards use, so navigation behavior is identical to the rest of the app.

struct HomeHero: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// Candidate items to feature (typically Just Added). The hero picks the first few
  /// that have a usable backdrop/poster.
  let items: [ItemSummary]

  @State private var index: Int = 0
  @State private var rotationTask: Task<Void, Never>?

  private var featured: [ItemSummary] {
    // An item is featurable if it has any renderable image: a real backdrop/poster
    // image id (live NAS) OR a bundled demo poster asset (demo mode).
    func hasImage(_ item: ItemSummary) -> Bool {
      if item.backdropImageId != nil || item.posterImageId != nil { return true }
      if appState.isDemoMode, DemoData.posterAssetNames[item.id] != nil { return true }
      return false
    }
    // Prefer a landscape backdrop for a true cinematic hero; fall back to any featurable item.
    let withBackdrop = items.filter { $0.backdropImageId != nil }
    let pool = withBackdrop.isEmpty ? items.filter(hasImage) : withBackdrop
    return Array(pool.prefix(5))
  }

  var body: some View {
    // Gate: only the Cinematic theme shows a hero. Everything else keeps the old top-rail layout.
    if ThemeHolder.shared.current.usesCinematicChrome, !featured.isEmpty {
      heroBody
    }
  }

  private var current: ItemSummary { featured[min(index, featured.count - 1)] }

  private var heroBody: some View {
    let theme = ThemeHolder.shared.current
    return NavigationLink {
      ItemDetailView(itemID: current.id, fallbackTitle: current.title)
    } label: {
      ZStack(alignment: .bottomLeading) {
        backdrop(for: current)

        // Scrim: melts the backdrop into the page background at the bottom.
        LinearGradient(colors: theme.heroScrim, startPoint: .top, endPoint: .bottom)

        VStack(alignment: .leading, spacing: 10) {
          Text(eyebrow(for: current))
            .font(.dsEyebrow)
            .tracking(2)
            .foregroundStyle(Color.dsAccent)

          Text(current.title)
            .font(.dsDisplay)
            .foregroundStyle(Color.dsTextPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 2)

          Text(metadata(for: current))
            .font(.dsCaption.monospaced())
            .foregroundStyle(Color.dsTextSecondary)
            // At accessibility sizes the single line can't hold year • runtime • rating
            // without truncating and silently dropping the rating (TASK-786). Let it wrap
            // to as many lines as needed so every field stays visible.
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)

          buttonRow
            .padding(.top, 4)

          if featured.count > 1 { dots }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 380)
      .clipped()
      // Extend the backdrop up under the status bar for a true full-bleed hero.
      .ignoresSafeArea(edges: .top)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Featured: \(current.title)")
    .accessibilityHint("Opens details")
    .onAppear { startRotation() }
    .onDisappear { rotationTask?.cancel() }
  }

  // MARK: Pieces

  @ViewBuilder
  private func backdrop(for item: ItemSummary) -> some View {
    Group {
      if appState.isDemoMode, let assetName = DemoData.posterAssetNames[item.id] {
        Image(assetName).resizable().scaledToFill()
      } else if let imageId = item.backdropImageId ?? item.posterImageId {
        AuthenticatedImage(
          url: appState.api.imageURL(id: imageId, width: 800),
          token: appState.sessionToken,
          usesTunnelCookie: appState.api.usesTunnelCookie
        )
        .scaledToFill()
      } else {
        Rectangle().fill(Color.dsSurfaceHigh)
      }
    }
    .frame(height: 380)
    .frame(maxWidth: .infinity)
    .clipped()
    // Subtle accent-tinted glow so the hero image feels lit.
    .overlay(alignment: .top) {
      LinearGradient(
        colors: [Color.dsAccentGlow.opacity(0.25), .clear],
        startPoint: .top, endPoint: .center
      )
      .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var buttonRow: some View {
    // At accessibility text sizes the scaled labels ("Play" / "Watchlist") overflow a
    // side-by-side row and truncate to "P…" / "W…" (TASK-784). Stack vertically and let
    // each button stretch full-width so the labels always render in full. At default
    // sizes the layout is unchanged: glowing red Play + glass Watchlist, side by side.
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 10) {
        playButton
        watchlistButton
      }
    } else {
      HStack(spacing: 10) {
        playButton
        watchlistButton
      }
    }
  }

  // Play — filled accent with glow.
  private var playButton: some View {
    NavigationLink {
      ItemDetailView(itemID: current.id, fallbackTitle: current.title, autoPlay: true)
    } label: {
      Label("Play", systemImage: "play.fill")
        .font(.subheadline.weight(.bold))
        .foregroundStyle(Color.dsAccentOn)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .background(Color.dsAccent, in: Capsule())
        .shadow(color: Color.dsAccentGlow, radius: 12, y: 4)
    }
    .buttonStyle(.plain)
  }

  // Watchlist — outlined glass.
  private var watchlistButton: some View {
    Label("Watchlist", systemImage: "plus")
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Color.dsTextPrimary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
      .padding(.horizontal, 18)
      .padding(.vertical, 11)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay(Capsule().stroke(Color.dsBorderStrong, lineWidth: 1))
  }

  private var dots: some View {
    HStack(spacing: 6) {
      ForEach(0..<featured.count, id: \.self) { i in
        Capsule()
          .fill(i == index ? Color.dsAccent : Color.dsTextTertiary.opacity(0.5))
          .frame(width: i == index ? 18 : 6, height: 6)
          .animation(.easeInOut(duration: 0.3), value: index)
      }
    }
    .padding(.top, 6)
  }

  // MARK: Content helpers

  private func eyebrow(for item: ItemSummary) -> String {
    item.type == "tvshow" ? "FEATURED SERIES" : "FEATURED"
  }

  private func metadata(for item: ItemSummary) -> String {
    var parts: [String] = []
    if let year = item.year { parts.append(String(year)) }
    if let d = item.durationSeconds, d > 0 {
      let h = d / 3600, m = (d % 3600) / 60
      parts.append(h > 0 ? "\(h)h \(m)m" : "\(m)m")
    }
    if let r = item.rating, r > 0 { parts.append(String(format: "★ %.1f", r)) }
    return parts.joined(separator: "  •  ")
  }

  // MARK: Rotation

  private func startRotation() {
    guard featured.count > 1 else { return }
    rotationTask?.cancel()
    rotationTask = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(6))
        guard !Task.isCancelled else { break }
        withAnimation(.easeInOut(duration: 0.5)) {
          index = (index + 1) % featured.count
        }
      }
    }
  }
}
