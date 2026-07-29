import SwiftUI

// MARK: - Theme Identity

enum ThemeID: String, CaseIterable, Identifiable {
    case classic
    case redesign
    case cinematic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:   return "Classic"
        case .redesign:  return "Nitrate"
        case .cinematic: return "Cinematic"
        }
    }

    /// Resolve a raw stored value to its concrete Theme. Single source of truth so the
    /// app entry point and any future caller stay in sync as themes are added.
    static func theme(forRaw raw: String) -> Theme {
        switch ThemeID(rawValue: raw) ?? .classic {
        case .classic:   return .classic
        case .redesign:  return .redesign
        case .cinematic: return .cinematic
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

    // MARK: - Extended tokens (added for the Cinematic redesign; shared by all themes)
    // Every field below has a default in the memberwise-init extension so the Classic
    // and Nitrate literals compile unchanged. A theme that wants depth/glow/hero
    // treatment overrides them; Classic/Nitrate keep flat, motion-free defaults.

    /// Whether this theme opts into the cinematic structural treatments (hero, card
    /// depth, glass tab bar). Classic/Nitrate = false → their layout is byte-identical.
    let usesCinematicChrome: Bool

    /// Ambient card elevation. `.none` on flat themes.
    let cardShadow: ThemeShadow
    /// Larger elevation for the hero / raised surfaces.
    let heroShadow: ThemeShadow

    /// Accent-tinted glow placed behind primary actions and the hero. `.clear` = no glow.
    let accentGlow: Color
    /// Faint atmospheric streak colors layered behind sections. Empty = none drawn.
    let atmosphereColors: [Color]

    /// Vertical gradient stops used for the hero scrim (top → bottom). Empty = no hero scrim.
    let heroScrim: [Color]

    /// Standard press-scale for interactive cards (1.0 = no scale motion).
    let pressScale: CGFloat
    /// Base spring/ease duration for theme motion.
    let motionDuration: Double

    /// Large display font for hero/movie titles. Falls back to `fontLargeTitle` on flat themes.
    let fontDisplay: Font
    /// Uppercase technical eyebrow/metadata font (mono on cinematic).
    let fontEyebrow: Font
}

// MARK: - Theme Shadow token

/// A resolvable shadow spec. `.none` renders nothing so flat themes stay flat.
struct ThemeShadow: Equatable, Sendable {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    static let none = ThemeShadow(color: .clear, radius: 0, x: 0, y: 0)
}

// MARK: - Memberwise init with extended-token defaults

extension Theme {
    /// Custom init so the Classic/Nitrate literals — written before the extended tokens
    /// existed — compile unchanged: every new parameter defaults to a flat, motion-free
    /// value. Only Cinematic passes the extended arguments.
    init(
        id: ThemeID,
        background: Color, surface: Color, surfaceHigh: Color, surfaceRaised: Color,
        accent: Color, accentOn: Color,
        success: Color, error: Color, warning: Color,
        textPrimary: Color, textSecondary: Color, textTertiary: Color, textMuted: Color, textInactive: Color,
        borderSubtle: Color, borderStrong: Color,
        radiusSm: CGFloat, radiusMd: CGFloat, radiusLg: CGFloat, radiusPill: CGFloat,
        fontLargeTitle: Font, fontTitle2: Font, fontHeadline: Font, fontBody: Font,
        fontSubheadline: Font, fontSubheadlineSB: Font, fontFootnote: Font,
        fontCaption: Font, fontCaption2: Font, fontScreenTitle: Font,
        // Extended tokens — all defaulted to the flat/no-op values.
        usesCinematicChrome: Bool = false,
        cardShadow: ThemeShadow = .none,
        heroShadow: ThemeShadow = .none,
        accentGlow: Color = .clear,
        atmosphereColors: [Color] = [],
        heroScrim: [Color] = [],
        pressScale: CGFloat = 1.0,
        motionDuration: Double = 0.25,
        fontDisplay: Font? = nil,
        fontEyebrow: Font? = nil
    ) {
        self.id = id
        self.background = background; self.surface = surface
        self.surfaceHigh = surfaceHigh; self.surfaceRaised = surfaceRaised
        self.accent = accent; self.accentOn = accentOn
        self.success = success; self.error = error; self.warning = warning
        self.textPrimary = textPrimary; self.textSecondary = textSecondary
        self.textTertiary = textTertiary; self.textMuted = textMuted; self.textInactive = textInactive
        self.borderSubtle = borderSubtle; self.borderStrong = borderStrong
        self.radiusSm = radiusSm; self.radiusMd = radiusMd
        self.radiusLg = radiusLg; self.radiusPill = radiusPill
        self.fontLargeTitle = fontLargeTitle; self.fontTitle2 = fontTitle2
        self.fontHeadline = fontHeadline; self.fontBody = fontBody
        self.fontSubheadline = fontSubheadline; self.fontSubheadlineSB = fontSubheadlineSB
        self.fontFootnote = fontFootnote; self.fontCaption = fontCaption
        self.fontCaption2 = fontCaption2; self.fontScreenTitle = fontScreenTitle
        self.usesCinematicChrome = usesCinematicChrome
        self.cardShadow = cardShadow; self.heroShadow = heroShadow
        self.accentGlow = accentGlow; self.atmosphereColors = atmosphereColors
        self.heroScrim = heroScrim
        self.pressScale = pressScale; self.motionDuration = motionDuration
        // Display/eyebrow default to the existing large-title / caption fonts on flat themes.
        self.fontDisplay = fontDisplay ?? fontLargeTitle
        self.fontEyebrow = fontEyebrow ?? fontCaption2
    }
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

// MARK: - Cinematic (redesign Theme 1 — depth, glow, hero. Approved mockup: DSVideo Cinematic)

extension Theme {
    static let cinematic = Theme(
        id: .cinematic,
        // Warm filmic charcoal ground (not pure black), richer brand red, cool counter-tone
        // reserved for atmospherics only.
        background:     Color(hex: "#0B0A0C"),
        surface:        Color(hex: "#141317"),
        surfaceHigh:    Color(hex: "#1E1C22"),
        surfaceRaised:  Color(hex: "#2A2730"),
        accent:         Color(hex: "#E23744"),
        accentOn:       .white,
        success:        Color(hex: "#32D583"),
        error:          Color(hex: "#E85A4F"),
        warning:        Color(hex: "#FFB547"),
        textPrimary:    Color(hex: "#F7F5F8"),
        textSecondary:  Color(hex: "#B8B4C0"),
        textTertiary:   Color(hex: "#847F8E"),
        textMuted:      Color(hex: "#6E6976"),
        textInactive:   Color(hex: "#4B4753"),
        borderSubtle:   Color(hex: "#221F28"),
        borderStrong:   Color(hex: "#332F3B"),
        radiusSm:   10,
        radiusMd:   14,
        radiusLg:   18,
        radiusPill: 22,
        fontLargeTitle:   Font.system(size: 34, weight: .heavy, design: .rounded),
        fontTitle2:       Font.system(size: 22, weight: .bold, design: .rounded),
        fontHeadline:     Font.system(size: 17, weight: .semibold),
        fontBody:         Font.body,
        fontSubheadline:  Font.subheadline,
        fontSubheadlineSB: Font.subheadline.weight(.semibold),
        fontFootnote:     Font.footnote,
        fontCaption:      Font.caption,
        fontCaption2:     Font.caption.weight(.semibold),
        fontScreenTitle:  Font.system(size: 30, weight: .heavy, design: .rounded),
        // Extended cinematic tokens
        usesCinematicChrome: true,
        cardShadow: ThemeShadow(color: Color.black.opacity(0.55), radius: 14, x: 0, y: 8),
        heroShadow: ThemeShadow(color: Color.black.opacity(0.65), radius: 28, x: 0, y: 14),
        accentGlow: Color(hex: "#E23744").opacity(0.45),
        atmosphereColors: [
            Color(hex: "#7A1420").opacity(0.55),   // deep crimson
            Color(hex: "#1FB6C9").opacity(0.28)    // faint cyan counter-tone
        ],
        heroScrim: [
            Color(hex: "#0B0A0C").opacity(0.0),
            Color(hex: "#0B0A0C").opacity(0.55),
            Color(hex: "#0B0A0C")
        ],
        pressScale: 0.96,
        motionDuration: 0.32,
        fontDisplay: Font.system(size: 46, weight: .heavy, design: .rounded),
        fontEyebrow: Font.system(size: 11, weight: .bold).monospaced()
    )
}
