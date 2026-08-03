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
  // tvOS has no cursor: the focus engine drives selection, so the chip must show a
  // focused state or it's impossible to tell what the remote is pointing at.
  @Environment(\.isFocused) private var isFocused
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
      Text(label)
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(isActive ? Color.dsAccentOn : (focused ? .black : Color.dsTextSecondary))
        .frame(minHeight: 56)
        .padding(.horizontal, 24)
        .background(
          RoundedRectangle(cornerRadius: theme.radiusPill, style: .continuous)
            .fill(isActive ? Color.dsAccent : (focused ? .white : Color.dsSurface))
        )
        .scaleEffect(focused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
    .buttonStyle(.plain)
    .focused($focused)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    #else
    Button(action: action) {
      Text(label)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(isActive ? Color.dsAccentOn : Color.dsTextSecondary)
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
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
      HStack(spacing: tvAdjusted(8)) {
        content
      }
      // 60pt horizontal on tvOS for the title-safe area; the chip row would otherwise
      // start inside the overscan region and the first chip would clip on a real TV.
      .padding(.horizontal, tvAdjusted(16, tv: 60))
      .padding(.vertical, tvAdjusted(8, tv: 16))
    }
    .background(Color.black.opacity(0.95))
  }

  private func tvAdjusted(_ base: CGFloat, tv: CGFloat? = nil) -> CGFloat {
    #if os(tvOS)
    return tv ?? base * 2
    #else
    return base
    #endif
  }
}
