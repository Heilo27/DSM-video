import Foundation

/// TASK-739: user-configurable subtitle appearance. Stored in UserDefaults and
/// applied via AVPlayerItem.textStyleRules in the player. Kept tiny and value-only
/// so both the player and the settings UI can share the keys and defaults.
enum SubtitleStyle {
  static let scaleKey = "dsReel.subtitleScale"                 // Double, 0.5...2.0 (1.0 = default)
  static let textColorKey = "dsReel.subtitleTextColor"         // hex string, e.g. "#FFFFFF"
  static let backgroundOpacityKey = "dsReel.subtitleBackgroundOpacity" // Double, 0...1

  /// Named text-color presets offered in settings.
  static let textColorPresets: [(name: String, hex: String)] = [
    ("White", "#FFFFFF"),
    ("Yellow", "#FFEB3B"),
    ("Cyan", "#4DD0E1"),
    ("Soft Grey", "#E0E0E0"),
  ]

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      scaleKey: 1.0,
      textColorKey: "#FFFFFF",
      backgroundOpacityKey: 0.0,
    ])
  }

  /// Parse "#RRGGBB" into normalised 0...1 components. Returns nil on malformed input.
  static func rgb(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255.0
    let g = Double((v >> 8) & 0xFF) / 255.0
    let b = Double(v & 0xFF) / 255.0
    return (r, g, b)
  }
}
