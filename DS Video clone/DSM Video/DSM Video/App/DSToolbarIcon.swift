import SwiftUI

// MARK: - Toolbar icon tap target
//
// The single home for the toolbar-icon tap-target rule (FRD-001 FR-007: 44pt minimum).
// Every toolbar glyph button uses `.dsToolbarIcon()`; change the size or target here
// and every toolbar follows.

extension View {
    /// Sizes a toolbar glyph so its tappable area is at least 44x44pt.
    ///
    /// A toolbar caps its item's HEIGHT, so `.frame` alone cannot reach 44pt vertically
    /// (an unframed glyph measured 37x36; framing widened it 37->56 and it stayed 36 tall).
    /// Growing the glyph raises the intrinsic height, and `contentShape` makes the padded
    /// area tappable rather than just the symbol's own bounds.
    func dsToolbarIcon() -> some View {
        self
            .font(.system(size: 20, weight: .semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}
