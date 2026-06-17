import SwiftUI

/// Process-wide active theme. The legacy `Color.dsX` / `Font.dsX` token accessors
/// read `ThemeHolder.shared.current` inside View bodies, so SwiftUI tracks the
/// `@Observable` access and re-renders every token-using view when the theme swaps.
@MainActor
@Observable
final class ThemeHolder {
    static let shared = ThemeHolder()
    var current: Theme = .classic
    private init() {}
}
