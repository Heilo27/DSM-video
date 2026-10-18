import SwiftUI

// MARK: - Spacing Tokens
//
// One named scale for padding and stack spacing (TASK-948). A view picks the step by NAME
// (`.padding(.dsSpaceLG)`, `HStack(spacing: .dsSpaceMD)`), never by a bare number, so the
// rhythm of the app lives in one file and a re-tune is one edit.
//
// The scale is theme-independent: spacing is layout, not skin, so a theme swap never moves it.
// It does differ by platform in exactly two places, both roles rather than steps:
//   - dsSpaceGutter   the screen-edge inset: 16 on iOS, 60 on tvOS (title-safe area)
//   - dsSpaceCompact  tight control padding and gaps: 8 on iOS, 16 on tvOS (10-foot targets)
// Every other step is the same number on both platforms; the tvOS screens simply reach
// further up the scale (dsSpaceHuge, dsSpaceGiant, ...).
//
// Off-scale literals (5, 6, 9, 10, 14, 18, 28, 56, 72, 120) are deliberately not tokens:
// a value with no role is a layout one-off, and promoting it would bless the drift. Zero is
// not a spacing step.

extension CGFloat {
    // MARK: Scale (same on iOS and tvOS)

    /// 2pt. Hairline gaps between stacked text lines.
    static let dsSpaceXXS: CGFloat = 2
    /// 4pt. Icon-to-label gaps, tight stacks.
    static let dsSpaceXS: CGFloat = 4
    /// 8pt. Default gap inside a control or a row of small items.
    static let dsSpaceSM: CGFloat = 8
    /// 12pt. Gap between related elements in a card or form row.
    static let dsSpaceMD: CGFloat = 12
    /// 16pt. Default content inset and section gap.
    static let dsSpaceLG: CGFloat = 16
    /// 20pt. Roomy control padding.
    static let dsSpaceXL: CGFloat = 20
    /// 24pt. Gap between groups.
    static let dsSpaceXXL: CGFloat = 24
    /// 32pt. Gap between sections.
    static let dsSpaceXXXL: CGFloat = 32
    /// 40pt. Large 10-foot gap.
    static let dsSpaceJumbo: CGFloat = 40
    /// 48pt. Large 10-foot inset.
    static let dsSpaceHuge: CGFloat = 48
    /// 64pt. Hero and page-level inset.
    static let dsSpaceGiant: CGFloat = 64
    /// 80pt. Hero top and bottom clearance.
    static let dsSpaceColossal: CGFloat = 80

    // MARK: Fixed role

    /// 60pt. The tvOS title-safe inset: content closer to the edge than this can clip under
    /// overscan on a real TV. A constant (not platform-switched) because only tvOS screens use it.
    static let dsSpaceTitleSafe: CGFloat = 60

    // MARK: Platform-scaled roles

    /// Screen-edge inset: 16 on iOS, 60 (title-safe) on tvOS.
    static var dsSpaceGutter: CGFloat {
        #if os(tvOS)
        return dsSpaceTitleSafe
        #else
        return dsSpaceLG
        #endif
    }

    /// Tight control padding and gaps: 8 on iOS, 16 on tvOS.
    static var dsSpaceCompact: CGFloat {
        #if os(tvOS)
        return dsSpaceLG
        #else
        return dsSpaceSM
        #endif
    }
}
