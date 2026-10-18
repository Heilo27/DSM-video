import Foundation

/// How the profile screens' custom button styles draw, decided in one place (FRD-002 FR-213,
/// TASK-958).
///
/// `ProfileTileButtonStyle` and `PinKeyStyle` draw their own press and focus looks, and a custom
/// `ButtonStyle` does not dim itself when the button is disabled. While a PIN was being verified the
/// pad was `.disabled(busy)` but every key still looked live, so on a slow WAN link the viewer kept
/// tapping keys that did nothing. Both styles now read `\.isEnabled` and take their dimming from
/// here, so the two cannot disagree about what "disabled" looks like.
nonisolated enum ProfileControlLook {
  /// Opacity of a disabled control: clearly inert, still legible.
  static let disabledOpacity = 0.4

  static func opacity(isEnabled: Bool) -> Double {
    isEnabled ? 1 : disabledOpacity
  }

  /// A key is lit (inverted) while focused or pressed. A disabled key never lights: it cannot be
  /// pressed, and a stale focus ring on a dead key reads as live.
  static func isLit(isFocused: Bool, isPressed: Bool, isEnabled: Bool) -> Bool {
    isEnabled && (isFocused || isPressed)
  }

  /// tvOS focus lift for a PIN key; none while disabled.
  static func keyScale(isFocused: Bool, isEnabled: Bool) -> Double {
    isEnabled && isFocused ? 1.1 : 1
  }
}
