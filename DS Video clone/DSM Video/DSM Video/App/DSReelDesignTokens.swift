import SwiftUI

// MARK: - Color Design Tokens

// Token accessors now resolve through the active Theme (ThemeHolder.shared.current).
// They are read inside View bodies, so SwiftUI tracks the @Observable access and
// re-renders on theme swap. Values for the Classic theme are byte-identical to the
// previous literals — see Theme.classic.
@MainActor
extension Color {
    // Backgrounds
    static var dsBackground:    Color { ThemeHolder.shared.current.background }
    static var dsSurface:       Color { ThemeHolder.shared.current.surface }       // cards, inputs
    static var dsSurfaceHigh:   Color { ThemeHolder.shared.current.surfaceHigh }   // elevated elements
    static var dsSurfaceRaised: Color { ThemeHolder.shared.current.surfaceRaised } // current-state legacy

    // Accent
    static var dsAccent:        Color { ThemeHolder.shared.current.accent }        // primary red
    /// Foreground color to place ON accent fills (Classic = white).
    static var dsAccentOn:      Color { ThemeHolder.shared.current.accentOn }

    // Status / semantic
    static var dsSuccess:       Color { ThemeHolder.shared.current.success }       // watched badge, complete
    static var dsError:         Color { ThemeHolder.shared.current.error }         // error banner
    static var dsWarning:       Color { ThemeHolder.shared.current.warning }       // star ratings

    // Text
    static var dsTextPrimary:   Color { ThemeHolder.shared.current.textPrimary }
    static var dsTextSecondary: Color { ThemeHolder.shared.current.textSecondary }
    static var dsTextTertiary:  Color { ThemeHolder.shared.current.textTertiary }
    static var dsTextMuted:     Color { ThemeHolder.shared.current.textMuted }
    static var dsTextInactive:  Color { ThemeHolder.shared.current.textInactive }

    // Borders / separators
    static var dsBorderSubtle:  Color { ThemeHolder.shared.current.borderSubtle }
    static var dsBorderStrong:  Color { ThemeHolder.shared.current.borderStrong }

    // Extended cinematic tokens (flat themes resolve these to no-op values)
    static var dsAccentGlow:    Color { ThemeHolder.shared.current.accentGlow }
}

// MARK: - Hex Color Initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        // Fallback: bright yellow — intentional so bad hex values are visible in development
        default:
            (r, g, b) = (255, 255, 0)
        }
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

// MARK: - Typography Scale
// Uses semantic TextStyle variants so the system scales with Dynamic Type.
// Custom sizes (dsLargeTitle, dsScreenTitle) use system(size:) but are large enough
// to qualify as "large text" (≥18pt) so WCAG AA requires only 3:1 contrast.

@MainActor
extension Font {
    static var dsLargeTitle:    Font { ThemeHolder.shared.current.fontLargeTitle }
    static var dsTitle2:        Font { ThemeHolder.shared.current.fontTitle2 }
    static var dsHeadline:      Font { ThemeHolder.shared.current.fontHeadline }
    static var dsBody:          Font { ThemeHolder.shared.current.fontBody }
    static var dsSubheadline:   Font { ThemeHolder.shared.current.fontSubheadline }
    static var dsSubheadlineSB: Font { ThemeHolder.shared.current.fontSubheadlineSB }
    static var dsFootnote:      Font { ThemeHolder.shared.current.fontFootnote }
    static var dsCaption:       Font { ThemeHolder.shared.current.fontCaption }
    static var dsCaption2:      Font { ThemeHolder.shared.current.fontCaption2 }

    // Screen titles (used across all main views)
    static var dsScreenTitle:   Font { ThemeHolder.shared.current.fontScreenTitle }

    // Cinematic display / eyebrow (flat themes fall back to large-title / caption)
    static var dsDisplay:       Font { ThemeHolder.shared.current.fontDisplay }
    static var dsEyebrow:       Font { ThemeHolder.shared.current.fontEyebrow }
}
