import SwiftUI

// MARK: - Primary action button

/// The two shapes a primary action takes. A choice of role, made per screen on purpose:
/// `card` is the full-width call to action on a detail or setup screen; `pill` is the compact
/// action that sits over artwork (home hero, next-episode countdown).
enum DSPrimaryButtonShape {
    case card
    case pill
}

/// The one primary-action look (design-spec B1/B4, TRUTHS S2). Carries shape, height, press,
/// focus and disabled, so no screen hand-builds an accent button.
///
/// - Idle: accent fill, `dsAccentOn` label, the theme's accent glow (clear on flat themes).
/// - Pressed: the shared press feedback (`DSPressFeedback`): scale on Cinematic, dim elsewhere.
/// - Focused (tvOS): brighter fill, 1.04 scale, stronger glow. The call site still owns
///   `.focused($state, equals:)`; this style only draws the result.
/// - Disabled: `dsSurface` fill with a `dsTextMuted` label and no glow. A disabled primary must
///   not look like an enabled one that is merely faded, and it must read on every theme.
///
/// The label supplies content, and any accessibility-size wrapping it needs (`lineLimit`,
/// `fixedSize`); the style supplies the font, colors and box.
private struct DSPrimaryButtonStyle: ButtonStyle {
    let shape: DSPrimaryButtonShape
    let fillsWidth: Bool
    let minWidth: CGFloat?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    /// 44pt is the HIG minimum tap target; the card is taller because it is the screen's one
    /// call to action. tvOS reads from across a room, so both shapes share one larger height.
    private var minHeight: CGFloat {
        #if os(tvOS)
        54
        #else
        shape == .card ? 52 : 44
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        shape == .card ? 20 : 28
        #else
        shape == .card ? 16 : 24
        #endif
    }

    func makeBody(configuration: Configuration) -> some View {
        let theme = ThemeHolder.shared.current
        let focused = isEnabled && isFocused
        let outline: AnyShape = shape == .pill
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
        let fill: Color = isEnabled ? Color.dsAccent : Color.dsSurface
        #if os(tvOS)
        let glow: Color = isEnabled ? Color.dsAccent.opacity(focused ? 0.7 : 0.3) : .clear
        let glowRadius: CGFloat = focused ? 10 : 5
        #else
        let glow: Color = isEnabled ? Color.dsAccentGlow : .clear
        let glowRadius: CGFloat = 12
        #endif

        return configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.dsAccentOn : Color.dsTextMuted)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background { outline.fill(fill).brightness(focused ? 0.12 : 0) }
            .shadow(color: glow, radius: glowRadius, x: 0, y: 3)
            .modifier(DSPressFeedback(pressed: configuration.isPressed, dimsWhenDisabled: false))
            .scaleEffect(focused ? 1.04 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .contentShape(outline)
    }
}

extension View {
    /// Draws a Button as the screen's primary action. Apply it in place of
    /// `.buttonStyle(.plain)` plus hand-built padding, fill and clip.
    ///
    /// - Parameters:
    ///   - shape: `.card` (rounded rect) or `.pill` (capsule).
    ///   - fillsWidth: stretch to the available width (detail-screen Play, Connect).
    ///   - minWidth: a floor on the width; the button still grows to fit its label.
    ///
    /// Every tvOS use must also carry `.focused()`; this style only draws the focus look.
    func dsPrimaryButton(_ shape: DSPrimaryButtonShape = .card,
                         fillsWidth: Bool = false,
                         minWidth: CGFloat? = nil) -> some View {
        buttonStyle(DSPrimaryButtonStyle(shape: shape, fillsWidth: fillsWidth, minWidth: minWidth))
    }
}
