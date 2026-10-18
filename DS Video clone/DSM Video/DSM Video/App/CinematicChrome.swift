import SwiftUI

// MARK: - Cinematic chrome
//
// Shared visual building blocks for the Cinematic theme: card depth, the atmospheric
// light-streak background, and a press-scale interaction. Every one of these is a
// NO-OP on flat themes (Classic / Nitrate) — they read `usesCinematicChrome` and, when
// false, render exactly what the view rendered before. That is what keeps the other
// themes byte-identical while Cinematic gains depth and glow.

// MARK: Card depth

private struct CinematicCardDepth: ViewModifier {
    func body(content: Content) -> some View {
        let theme = ThemeHolder.shared.current
        if theme.usesCinematicChrome {
            content
                .shadow(
                    color: theme.cardShadow.color,
                    radius: theme.cardShadow.radius,
                    x: theme.cardShadow.x,
                    y: theme.cardShadow.y
                )
        } else {
            content
        }
    }
}

extension View {
    /// Ambient card elevation on the Cinematic theme; nothing on flat themes.
    func dsCardDepth() -> some View {
        modifier(CinematicCardDepth())
    }
}

// MARK: Press and disabled interaction

/// The opacity every custom button style uses for its pressed and disabled states, so
/// the states read the same across the app (TRUTHS S2: a custom ButtonStyle must render
/// pressed and disabled visibly differently from idle).
enum DSInteractionOpacity {
    /// Label opacity while pressed on flat themes; matches the dim `.plain` gave.
    static let pressed: Double = 0.6
    /// Label opacity when the control is disabled.
    static let disabled: Double = 0.4
}

/// The pressed (and optionally disabled) feedback every custom button style shares, so the
/// rule has one home: Cinematic signals a press with the themed scale; flat themes
/// (Classic / Nitrate) dim the label, which is what `.plain` did before DSPressableStyle
/// replaced it. A style that draws its own disabled look (DSPrimaryButtonStyle) passes
/// `dimsWhenDisabled: false` so the control is not dimmed twice.
struct DSPressFeedback: ViewModifier {
    let pressed: Bool
    let dimsWhenDisabled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let theme = ThemeHolder.shared.current
        let cinematic = theme.usesCinematicChrome
        let opacity: Double = (!isEnabled && dimsWhenDisabled) ? DSInteractionOpacity.disabled
            : (isEnabled && pressed && !cinematic ? DSInteractionOpacity.pressed : 1.0)
        return content
            .scaleEffect(cinematic && pressed ? theme.pressScale : 1.0)
            .opacity(opacity)
            .animation(.easeOut(duration: theme.motionDuration * 0.5), value: pressed)
    }
}

private struct DSPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(DSPressFeedback(pressed: configuration.isPressed, dimsWhenDisabled: true))
    }
}

extension View {
    /// Plain-button replacement with a themed pressed state (scale on Cinematic, opacity
    /// dim on flat themes) and a dimmed disabled state. Unlike `.buttonStyle(.plain)`,
    /// this is a custom style, so it must draw its own pressed and disabled looks.
    func dsPressable() -> some View {
        buttonStyle(DSPressableStyle())
    }
}

// MARK: Atmospheric background (blurred light streaks)

/// The filmic-glow signature: a few heavily-blurred, tilted accent streaks drawn behind
/// content. Renders only on the Cinematic theme; an empty view otherwise. Deterministic
/// (no randomness) so it never changes between renders.
struct AtmosphereBackground: View {
    /// Vertical anchor positions (0…1) for the streak centers, kept well separated.
    var seed: [CGFloat] = [0.14, 0.42, 0.68, 0.88]

    var body: some View {
        let theme = ThemeHolder.shared.current
        GeometryReader { geo in
            if theme.usesCinematicChrome, !theme.atmosphereColors.isEmpty {
                ZStack {
                    ForEach(Array(seed.enumerated()), id: \.offset) { idx, y in
                        let color = theme.atmosphereColors[idx % theme.atmosphereColors.count]
                        let tilt = idx.isMultiple(of: 2) ? 8.0 : -11.0
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * (0.7 + 0.08 * CGFloat(idx % 3)), height: 6)
                            .blur(radius: 45)
                            .rotationEffect(.degrees(tilt))
                            .position(x: geo.size.width * (idx.isMultiple(of: 2) ? 0.35 : 0.62),
                                      y: geo.size.height * y)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}
