import Foundation

// MARK: - When a search runs (FRD-001 FR-089, FR-100, TASK-977)

/// One home for "does this text start a search", shared by the iPhone/iPad and Apple TV search
/// screens so neither can drift back to silently ignoring a short query.
///
/// Two ways to start a search:
/// - **live**: the user is still typing. Searching on every keystroke would send a request per
///   letter, so live search waits for two characters (and a pause).
/// - **explicit**: the user pressed Search/return, tapped a recent search, or asked Siri. That is a
///   statement of intent, so any non-empty query runs. Titles such as "M", "Z" or "1" are only
///   reachable this way. The server escapes LIKE metacharacters, so a short query is safe to send.
enum SearchRules {
  /// Characters live (as-you-type) search waits for.
  static let liveMinimumLength = 2

  /// The trimmed query to send, or nil when this trigger should not search.
  static func queryToSend(_ raw: String, explicit: Bool) -> String? {
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    guard explicit || query.count >= liveMinimumLength else { return nil }
    return query
  }

  /// True while the field holds text too short for live search: the screen shows a hint so it
  /// does not look frozen.
  static func needsExplicitSubmit(_ raw: String) -> Bool {
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return !query.isEmpty && query.count < liveMinimumLength
  }

  static let shortQueryTitle = "Press Search to look"
  static func shortQueryHint(for raw: String) -> String {
    "Live results start at \(liveMinimumLength) characters. Press Search to look for \"\(raw.trimmingCharacters(in: .whitespacesAndNewlines))\" now."
  }

  /// Runs the search against the server. nil when the trigger does not search (see `queryToSend`).
  static func fetch(
    _ raw: String, explicit: Bool, api: APIClient, limit: Int = 100
  ) async -> Result<[ItemSummary], any Error>? {
    guard let query = queryToSend(raw, explicit: explicit) else { return nil }
    do {
      return .success(try await api.search(query: query, limit: limit).items)
    } catch {
      return .failure(error)
    }
  }
}
