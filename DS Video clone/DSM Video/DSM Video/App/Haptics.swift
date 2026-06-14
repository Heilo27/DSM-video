import SwiftUI

/// Centralised haptic feedback. iOS-only — every call is a no-op on tvOS (no Taptic
/// Engine) so call sites don't need their own `#if os(iOS)` guards.
///
/// Use for imperative interactions where a `.sensoryFeedback` view modifier would be
/// awkward (player skip/seek, toggles fired from closures, download lifecycle).
enum Haptics {
  enum Style {
    case light, medium, rigid, soft
    case success, warning, error
    case selection
  }

  #if os(iOS)
  // Generators are cheap to create; UIKit recommends `prepare()` before use for
  // lowest latency, which we do per-call. Kept on the main actor — UIFeedbackGenerator
  // is not thread-safe.
  @MainActor
  static func play(_ style: Style) {
    switch style {
    case .light:     impact(.light)
    case .medium:    impact(.medium)
    case .rigid:     impact(.rigid)
    case .soft:      impact(.soft)
    case .selection:
      let g = UISelectionFeedbackGenerator()
      g.prepare()
      g.selectionChanged()
    case .success:   notify(.success)
    case .warning:   notify(.warning)
    case .error:     notify(.error)
    }
  }

  @MainActor
  private static func impact(_ s: UIImpactFeedbackGenerator.FeedbackStyle) {
    let g = UIImpactFeedbackGenerator(style: s)
    g.prepare()
    g.impactOccurred()
  }

  @MainActor
  private static func notify(_ t: UINotificationFeedbackGenerator.FeedbackType) {
    let g = UINotificationFeedbackGenerator()
    g.prepare()
    g.notificationOccurred(t)
  }
  #else
  @MainActor
  static func play(_ style: Style) {}
  #endif
}
