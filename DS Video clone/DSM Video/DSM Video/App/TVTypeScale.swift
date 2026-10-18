import SwiftUI

// MARK: - tvOS type scale
//
// The 10-foot text roles. tvOS has no Dynamic Type, so its sizes are fixed points, but they
// still belong to the theme: Cinematic sets its display, title and section faces in the rounded
// heavy design on iOS, and the TV screens must pick that up too instead of hard-coding
// `.system(size:)` per screen (TASK-951). Screens read `Font.dsTV*`; a theme supplies the scale.
//
// Glyph sizes (an SF Symbol sized with `.font(.system(size:))`) are not text and stay at the
// call site. The pairing code (TVPairingView) uses `code`/`codeField`: a code is read digit by
// digit, so every theme keeps it monospaced.

struct TVTypeScale: Equatable, Sendable {
    /// Hero wordmark on the sign-in screen.
    let display: Font
    /// Screen and show titles.
    let largeTitle: Font
    /// Dialog titles, form headings, the sign-in heading.
    let title: Font
    /// Row, shelf and chip titles.
    let sectionTitle: Font
    /// Button labels and emphasised lines.
    let headline: Font
    /// Inline action labels and episode titles (medium weight).
    let label: Font
    /// Supporting copy at the larger reading size (empty states, countdowns).
    let bodyLarge: Font
    /// Supporting copy.
    let body: Font
    /// Metadata under artwork: year, duration, hints, server addresses.
    let caption: Font
    /// Card titles under artwork and compact badges (medium weight).
    let captionEmphasis: Font
    /// Search field text.
    let field: Font
    /// The six-digit pairing code on display.
    let code: Font
    /// The pairing-code entry field.
    let codeField: Font

    /// The scale every flat theme uses (Classic, Nitrate): plain system faces. These are the
    /// sizes the TV screens carried before the scale existed, collapsed onto 13 roles.
    static let standard = TVTypeScale(
        display:         .system(size: 72, weight: .bold),
        largeTitle:      .system(size: 48, weight: .bold),
        title:           .system(size: 36, weight: .bold),
        sectionTitle:    .system(size: 28, weight: .semibold),
        headline:        .system(size: 22, weight: .semibold),
        label:           .system(size: 20, weight: .medium),
        bodyLarge:       .system(size: 24),
        body:            .system(size: 20),
        caption:         .system(size: 17),
        captionEmphasis: .system(size: 17, weight: .medium),
        field:           .system(size: 36),
        code:            .system(size: 80, weight: .bold, design: .monospaced),
        codeField:       .system(size: 56, weight: .bold, design: .monospaced)
    )

    /// Cinematic: the display, title and section roles take the rounded heavy face the iOS
    /// scale uses (fontLargeTitle / fontTitle2); reading sizes stay plain so body copy is calm.
    static let cinematic = TVTypeScale(
        display:         .system(size: 72, weight: .heavy, design: .rounded),
        largeTitle:      .system(size: 48, weight: .heavy, design: .rounded),
        title:           .system(size: 36, weight: .heavy, design: .rounded),
        sectionTitle:    .system(size: 28, weight: .bold, design: .rounded),
        headline:        standard.headline,
        label:           standard.label,
        bodyLarge:       standard.bodyLarge,
        body:            standard.body,
        caption:         standard.caption,
        captionEmphasis: standard.captionEmphasis,
        field:           standard.field,
        code:            standard.code,
        codeField:       standard.codeField
    )
}

@MainActor
extension Font {
    static var dsTVDisplay:         Font { ThemeHolder.shared.current.tvType.display }
    static var dsTVLargeTitle:      Font { ThemeHolder.shared.current.tvType.largeTitle }
    static var dsTVTitle:           Font { ThemeHolder.shared.current.tvType.title }
    static var dsTVSectionTitle:    Font { ThemeHolder.shared.current.tvType.sectionTitle }
    static var dsTVHeadline:        Font { ThemeHolder.shared.current.tvType.headline }
    static var dsTVLabel:           Font { ThemeHolder.shared.current.tvType.label }
    static var dsTVBodyLarge:       Font { ThemeHolder.shared.current.tvType.bodyLarge }
    static var dsTVBody:            Font { ThemeHolder.shared.current.tvType.body }
    static var dsTVCaption:         Font { ThemeHolder.shared.current.tvType.caption }
    static var dsTVCaptionEmphasis: Font { ThemeHolder.shared.current.tvType.captionEmphasis }
    static var dsTVField:           Font { ThemeHolder.shared.current.tvType.field }
    static var dsTVCode:            Font { ThemeHolder.shared.current.tvType.code }
    static var dsTVCodeField:       Font { ThemeHolder.shared.current.tvType.codeField }
}
