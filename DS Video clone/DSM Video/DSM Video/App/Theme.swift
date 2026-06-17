import SwiftUI

// MARK: - Theme Identity

enum ThemeID: String, CaseIterable, Identifiable {
    case classic
    case redesign

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:  return "Classic"
        case .redesign: return "Nitrate"
        }
    }
}

// MARK: - Theme

/// A complete, swappable token set. Every value SwiftUI reads at render time
/// resolves through the active `Theme`, so swapping themes re-renders the UI.
struct Theme: Equatable, Sendable {
    let id: ThemeID

    // Backgrounds
    let background: Color
    let surface: Color
    let surfaceHigh: Color
    let surfaceRaised: Color

    // Accent
    let accent: Color
    /// Foreground color placed ON accent fills (e.g. text/icons over the accent red).
    let accentOn: Color

    // Status / semantic
    let success: Color
    let error: Color
    let warning: Color

    // Text
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textMuted: Color
    let textInactive: Color

    // Borders / separators
    let borderSubtle: Color
    let borderStrong: Color

    // Radii
    let radiusSm: CGFloat
    let radiusMd: CGFloat
    let radiusLg: CGFloat
    let radiusPill: CGFloat

    // Typography
    let fontLargeTitle: Font
    let fontTitle2: Font
    let fontHeadline: Font
    let fontBody: Font
    let fontSubheadline: Font
    let fontSubheadlineSB: Font
    let fontFootnote: Font
    let fontCaption: Font
    let fontCaption2: Font
    let fontScreenTitle: Font
}

// MARK: - Classic (current production look — values copied verbatim from tokens)

extension Theme {
    static let classic = Theme(
        id: .classic,
        background:     Color(hex: "#000000"),
        surface:        Color(hex: "#111111"),
        surfaceHigh:    Color(hex: "#1C1C1E"),
        surfaceRaised:  Color(hex: "#2C2C2E"),
        accent:         Color(hex: "#D1262F"),
        accentOn:       .white,
        success:        Color(hex: "#32D583"),
        error:          Color(hex: "#E85A4F"),
        warning:        Color(hex: "#FFB547"),
        textPrimary:    .white,
        textSecondary:  .white.opacity(0.75),
        textTertiary:   .white.opacity(0.55),
        textMuted:      Color(hex: "#8E8E93"),
        textInactive:   Color(hex: "#737373"),
        borderSubtle:   Color(hex: "#2A2A2E"),
        borderStrong:   Color(hex: "#3A3A40"),
        radiusSm:   8,
        radiusMd:   12,
        radiusLg:   16,
        radiusPill: 20,
        fontLargeTitle:   Font.largeTitle.weight(.bold),
        fontTitle2:       Font.title2.weight(.bold),
        fontHeadline:     Font.headline,
        fontBody:         Font.body,
        fontSubheadline:  Font.subheadline,
        fontSubheadlineSB: Font.subheadline.weight(.semibold),
        fontFootnote:     Font.footnote,
        fontCaption:      Font.caption,
        fontCaption2:     Font.caption.weight(.semibold),
        fontScreenTitle:  Font.system(size: 26, weight: .bold)
    )
}

// MARK: - Redesign / "Nitrate" (STUB — mirrors Classic until the palette phase)

extension Theme {
    static let redesign = Theme(
        id: .redesign,
        // Nitrate: warm filmic dark, amber-gold accent, ivory text (red kept only for errors).
        background:     Color(hex: "#14110C"),
        surface:        Color(hex: "#1E1A13"),
        surfaceHigh:    Color(hex: "#2A241A"),
        surfaceRaised:  Color(hex: "#38301F"),
        accent:         Color(hex: "#E8B04B"),
        accentOn:       Color(hex: "#0B0A08"),
        success:        Color(hex: "#6FCF8E"),
        error:          Color(hex: "#E5594C"),
        warning:        Color(hex: "#F2C14E"),
        textPrimary:    Color(hex: "#F5EFE3"),
        textSecondary:  Color(hex: "#C9C0AE"),
        textTertiary:   Color(hex: "#968C78"),
        textMuted:      Color(hex: "#6E6657"),
        textInactive:   Color(hex: "#4D483E"),
        borderSubtle:   Color(hex: "#2A241B"),
        borderStrong:   Color(hex: "#3C3528"),
        radiusSm:   8,
        radiusMd:   12,
        radiusLg:   16,
        radiusPill: 20,
        fontLargeTitle:   Font.largeTitle.weight(.bold),
        fontTitle2:       Font.title2.weight(.bold),
        fontHeadline:     Font.headline,
        fontBody:         Font.body,
        fontSubheadline:  Font.subheadline,
        fontSubheadlineSB: Font.subheadline.weight(.semibold),
        fontFootnote:     Font.footnote,
        fontCaption:      Font.caption,
        fontCaption2:     Font.caption.weight(.semibold),
        fontScreenTitle:  Font.system(size: 26, weight: .bold)
    )
}
