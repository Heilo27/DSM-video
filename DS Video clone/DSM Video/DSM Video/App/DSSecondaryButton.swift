import SwiftUI

// MARK: - Secondary action button

/// The one secondary-action look (design-spec, `dsSecondaryButton`). The quieter action that sits
/// beside a primary one (Sign Out beside Retry, Generate New Code beside a live code, Done on the
/// profile screens), drawn from tokens only so it reads on every theme.
///
/// - Idle: `dsSurfaceRaised` fill, 1pt `dsBorderSubtle` stroke, `dsTextPrimary` label, no glow.
/// - Pressed: the shared press feedback (`DSPressFeedback`): scale on Cinematic, dim elsewhere.
/// - Focused (tvOS): brighter fill, `dsBorderStrong` stroke, 1.04 scale. The call site still owns
///   `.focused($state, equals:)`; this style only draws the result. A custom style replaces the
///   system tvOS focus effect, so an unbound one is unreachable (`fastlane check_focus`).
/// - Disabled: `dsSurface` fill with a `dsTextMuted` label, same as the primary.
///
/// The label supplies content, and any accessibility-size wrapping it needs; the style supplies
/// the font, colors and box, using the same height and padding as `dsPrimaryButton(.card)` so the
/// two sit together at one size.
private struct DSSecondaryButtonStyle: ButtonStyle {
    let fillsWidth: Bool
    let minWidth: CGFloat?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    private var minHeight: CGFloat {
        #if os(tvOS)
        54
        #else
        52
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        20
        #else
        16
        #endif
    }

    func makeBody(configuration: Configuration) -> some View {
        let theme = ThemeHolder.shared.current
        let focused = isEnabled && isFocused
        let outline = RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
        let fill: Color = isEnabled ? Color.dsSurfaceRaised : Color.dsSurface
        let stroke: Color = focused ? Color.dsBorderStrong : Color.dsBorderSubtle

        return configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.dsTextPrimary : Color.dsTextMuted)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background { outline.fill(fill).brightness(focused ? 0.12 : 0) }
            .overlay { outline.strokeBorder(stroke, lineWidth: focused ? 2 : 1) }
            .modifier(DSPressFeedback(pressed: configuration.isPressed, dimsWhenDisabled: false))
            .scaleEffect(focused ? 1.04 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .contentShape(outline)
    }
}

extension View {
    /// Draws a Button as the quieter action beside a screen's primary one. Apply it in place of
    /// `.buttonStyle(.bordered)` / `.borderedProminent` plus a tint.
    ///
    /// - Parameters:
    ///   - fillsWidth: stretch to the available width.
    ///   - minWidth: a floor on the width; the button still grows to fit its label.
    ///
    /// Every tvOS use must also carry `.focused()`; this style only draws the focus look.
    func dsSecondaryButton(fillsWidth: Bool = false,
                           minWidth: CGFloat? = nil) -> some View {
        buttonStyle(DSSecondaryButtonStyle(fillsWidth: fillsWidth, minWidth: minWidth))
    }
}
