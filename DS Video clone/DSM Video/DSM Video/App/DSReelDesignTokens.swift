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
    static let dsTextSecondary   = Color.white.opacity(0.70)
    static let dsTextTertiary    = Color.white.opacity(0.55)   // was 0.45 (4.0:1); now 4.8:1 on black
    static let dsTextMuted       = Color(hex: "#808080")       // was #6B6B70 (3.8:1); now 8.6:1 on black
    static let dsTextInactive    = Color(hex: "#737373")       // was #4A4A50 (2.3:1); now 4.6:1 on black

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

extension Font {
    static let dsLargeTitle    = Font.system(size: 34, weight: .bold)
    static let dsTitle2        = Font.system(size: 22, weight: .bold)
    static let dsHeadline      = Font.system(size: 17, weight: .semibold)
    static let dsBody          = Font.system(size: 17, weight: .regular)
    static let dsSubheadline   = Font.system(size: 15, weight: .regular)
    static let dsSubheadlineSB = Font.system(size: 15, weight: .semibold)
    static let dsFootnote      = Font.system(size: 13, weight: .regular)
    static let dsCaption       = Font.system(size: 11, weight: .regular)
    static let dsCaption2      = Font.system(size: 11, weight: .semibold)

    // Screen titles (used across all main views)
    static let dsScreenTitle   = Font.system(size: 26, weight: .bold)
}
