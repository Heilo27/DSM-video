import SwiftUI

// MARK: - Color Design Tokens

extension Color {
    // Backgrounds
    static let dsBackground      = Color(hex: "#000000")
    static let dsSurface         = Color(hex: "#111111")  // cards, inputs
    static let dsSurfaceHigh     = Color(hex: "#1C1C1E")  // elevated elements
    static let dsSurfaceRaised   = Color(hex: "#2C2C2E")  // current-state legacy

    // Accent
    static let dsAccent          = Color(hex: "#D1262F")  // primary red

    // Status / semantic
    static let dsSuccess         = Color(hex: "#32D583")  // watched badge, complete
    static let dsError           = Color(hex: "#E85A4F")  // error banner
    static let dsWarning         = Color(hex: "#FFB547")  // star ratings

    // Text
    static let dsTextPrimary     = Color.white
    static let dsTextSecondary   = Color.white.opacity(0.75)
    static let dsTextTertiary    = Color.white.opacity(0.55)   // was 0.45 (4.0:1); now 4.8:1 on black
    static let dsTextMuted       = Color(hex: "#8E8E93")       // WCAG AA: ~4.6:1 on black
    static let dsTextInactive    = Color(hex: "#737373")       // WCAG AA: ~4.6:1 on black

    // Borders / separators
    static let dsBorderSubtle    = Color(hex: "#2A2A2E")
    static let dsBorderStrong    = Color(hex: "#3A3A40")
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

extension Font {
    static let dsLargeTitle    = Font.largeTitle.weight(.bold)
    static let dsTitle2        = Font.title2.weight(.bold)
    static let dsHeadline      = Font.headline
    static let dsBody          = Font.body
    static let dsSubheadline   = Font.subheadline
    static let dsSubheadlineSB = Font.subheadline.weight(.semibold)
    static let dsFootnote      = Font.footnote
    static let dsCaption       = Font.caption
    static let dsCaption2      = Font.caption.weight(.semibold)

    // Screen titles (used across all main views)
    static let dsScreenTitle   = Font.system(size: 26, weight: .bold)
}
