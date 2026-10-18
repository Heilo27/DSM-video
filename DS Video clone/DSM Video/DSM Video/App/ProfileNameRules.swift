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

  /// What Go's `strings.TrimSpace` trims (`unicode.IsSpace`), spelled out. Foundation's
  /// `.whitespacesAndNewlines` is not the same set (it also trims U+200B zero-width space, and its
  /// membership follows the OS's Unicode tables), so a name wrapped in U+200B counted short here and
  /// long on the server (TASK-1023). Checked against docs/test-vectors/profile-name.json.
  static let serverTrimSet: CharacterSet = {
    var set = CharacterSet()
    set.insert(charactersIn: "\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{20}\u{85}\u{A0}\u{1680}")
    set.insert(charactersIn: Unicode.Scalar(0x2000)!...Unicode.Scalar(0x200A)!)
    set.insert(charactersIn: "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")
    return set
  }()

  /// The trimmed name, exactly as it is sent.
  static func trimmed(_ raw: String) -> String {
    raw.trimmingCharacters(in: serverTrimSet)
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
