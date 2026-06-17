import SwiftUI

#if !os(tvOS)
/// Shared sort-filter chip (A20). Previously the Movies grid (`SortChipBar`) and the
/// TV Shows grid (`TVShowSortChipBar`) each rendered their own chip with inconsistent
/// corner radii (20 vs 16) and label formatting. Both now render through this single
/// component so the two sort systems look and behave identically: pill-shaped chips,
/// accent fill when active, secondary text when inactive.
struct SortChip: View {
  @Environment(\.theme) private var theme

  let label: String
  let isActive: Bool
  /// Accessibility label describing the chip's action/state.
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
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
  }
}

/// Shared container for a horizontal scroll of sort chips — unifies padding and the
/// translucent backing used by both grid screens.
struct SortChipScroller<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        content
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .background(Color.black.opacity(0.95))
  }
}
#endif
