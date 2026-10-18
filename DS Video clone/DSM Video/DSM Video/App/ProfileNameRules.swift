import Foundation

/// The profile-name limit, in one place and in the server's unit (FRD-002 FR-203, TASK-952).
///
/// The server counts Unicode characters (code points; Go `utf8.RuneCountInString`) after trimming,
/// and refuses a name over 20 with `invalid_profile_name`. The editor used to count Swift
/// `Character`s (grapheme clusters), so "Grandma 👨‍👩‍👧‍👦 Smith" read as 15 and Save stayed on, then
/// the server counted 21 and refused it with a message about a limit the viewer could not see
/// being broken. Both sides now count code points. A grapheme count would need a Unicode
/// segmentation table in the Go server, which has no outside dependencies by rule; a family emoji
/// costing seven is the price, and the counter shows it as it happens.
///
/// If the limit changes, change `maxLength` here and `maxProfileNameRunes` in the backend together.
nonisolated enum ProfileNameRules {
  static let maxLength = 20

  /// The trimmed name, exactly as it is sent.
  static func trimmed(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Length in the unit the server counts: Unicode scalar values of the trimmed name.
  static func length(of raw: String) -> Int {
    trimmed(raw).unicodeScalars.count
  }

  enum Status: Equatable {
    case ok(length: Int)
    case empty
    case tooLong(length: Int, over: Int)
  }

  static func status(of raw: String) -> Status {
    let length = length(of: raw)
    if length == 0 { return .empty }
    if length > maxLength { return .tooLong(length: length, over: length - maxLength) }
    return .ok(length: length)
  }

  static func isValid(_ raw: String) -> Bool {
    if case .ok = status(of: raw) { return true }
    return false
  }

  /// "n/20", shown beside the field so the limit is visible before it is hit.
  static func counter(for raw: String) -> String {
    "\(length(of: raw))/\(maxLength)"
  }

  /// Why Save is off for this name; nil when the name is fine.
  static func reason(for raw: String) -> String? {
    switch status(of: raw) {
    case .ok: return nil
    case .empty: return "Enter a name to save."
    case .tooLong(_, let over):
      return "\(over) too many. A name can be up to \(maxLength) characters, and an emoji can count as several."
    }
  }
}
