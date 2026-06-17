import SwiftUI

/// Environment access to the active theme, for views that need values not exposed
/// via the legacy `Color.dsX` / `Font.dsX` accessors (e.g. radii: `theme.radiusMd`).
private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: Theme = .classic
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
