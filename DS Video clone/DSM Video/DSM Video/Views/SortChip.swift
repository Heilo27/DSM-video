import SwiftUI

/// Shared sort-filter chip (A20). Previously the Movies grid (`SortChipBar`) and the
/// TV Shows grid (`TVShowSortChipBar`) each rendered their own chip with inconsistent
/// corner radii (20 vs 16) and label formatting. Both now render through this single
/// component so the two sort systems look and behave identically: pill-shaped chips,
/// accent fill when active, secondary text when inactive.
///
/// Available on tvOS as well: this file used to be wrapped entirely in `#if !os(tvOS)`,
/// which is why the TV had no way to change sort order at all — the grid's tvOS branch
/// put its sort buttons in `ToolbarItem(placement: .topBarTrailing)`, a placement tvOS
/// does not render, so they existed in code but were invisible on screen.
struct SortChip: View {
  @Environment(\.theme) private var theme
  #if os(tvOS)
  // Binds the chip into the focus engine (check_focus requires every tvOS button to be
  // bound). It does NOT drive the look: measured on the tvOS sim this Bool never turned
  // true for the chip, so the visual reads `isFocused` inside `TVSortChipLabel` instead.
  @FocusState private var focused: Bool
  #endif

  let label: String
  let isActive: Bool
  /// Accessibility label describing the chip's action/state.
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    #if os(tvOS)
    Button(action: action) {
      TVSortChipLabel(label: label, isActive: isActive)
    }
    .dsPlainButton()
    .focused($focused)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    #else
    Button(action: action) {
      Text(label)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(isActive ? Color.dsAccentOn : Color.dsTextSecondary)
        .frame(minHeight: 44)
        .padding(.horizontal, .dsSpaceMD)
        .background(
          RoundedRectangle(cornerRadius: theme.radiusPill, style: .continuous)
            .fill(isActive ? Color.dsAccent : Color.dsSurface)
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    #endif
  }
}

/// Shared container for a horizontal scroll of sort chips — unifies padding and the
/// translucent backing used by both grid screens.
struct SortChipScroller<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: .dsSpaceCompact) {
        content
      }
      // dsSpaceGutter is the title-safe inset on tvOS (60pt); the chip row would otherwise
      // start inside the overscan region and the first chip would clip on a real TV.
      .padding(.horizontal, .dsSpaceGutter)
      .padding(.vertical, .dsSpaceCompact)
    }
    .background(Color.dsBackground.opacity(0.95))
  }
}

#if os(tvOS)
/// tvOS chip face. Reads `isFocused` from INSIDE the Button's label, the only place the
/// environment value reflects the button's own focus (read on the Button's parent it is
/// always false). tvOS has no cursor: the focus engine drives selection, so the chip must
/// draw a focused state itself, since `dsPlainButton()` draws no system platter. An active
/// chip is already accent-filled, so focus there is a white ring plus the lift; an
/// inactive chip turns white.
private struct TVSortChipLabel: View {
  @Environment(\.theme) private var theme
  @Environment(\.isFocused) private var focused

  let label: String
  let isActive: Bool

  var body: some View {
    Text(label)
      .font(.dsTVSectionTitle)
      .foregroundStyle(isActive ? Color.dsAccentOn : (focused ? .black : Color.dsTextSecondary))
      .frame(minHeight: 56)
      .padding(.horizontal, .dsSpaceXXL)
      .background(
        RoundedRectangle(cornerRadius: theme.radiusPill, style: .continuous)
          .fill(isActive ? Color.dsAccent : (focused ? .white : Color.dsSurface))
      )
      .overlay(
        RoundedRectangle(cornerRadius: theme.radiusPill, style: .continuous)
          .strokeBorder(Color.white, lineWidth: isActive && focused ? 4 : 0)
      )
      .scaleEffect(focused ? 1.06 : 1.0)
      .animation(.easeOut(duration: 0.15), value: focused)
  }
}

/// tvOS library screen heading plus an optional item count (TASK-1059).
///
/// Replaces `.navigationTitle` on the library grids: tvOS renders that as a dim, centred
/// system title in no type-scale role, which read as disabled next to the white headings
/// on Home. The count lives here, in the pinned header, instead of in a Text after the
/// LazyVGrid, where lazy row estimation left it on top of the second row of cards.
/// Both grid screens share this so the heading cannot drift apart.
struct TVLibraryHeading: View {
  let title: String
  var count: Int? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.dsTVLargeTitle)
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      if let count {
        Text("\(count) item\(count == 1 ? "" : "s")")
          .font(.dsTVCaption)
          .foregroundStyle(Color.dsTextSecondary)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, .dsSpaceGutter)
    .padding(.top, .dsSpaceMD)
    .background(Color.dsBackground.opacity(0.95))
  }
}
#endif
