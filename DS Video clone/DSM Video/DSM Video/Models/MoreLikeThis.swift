import Foundation

/// The More Like This shelf's show/hide rules (FR-151), kept pure so they can be tested without
/// a view or a server.
///
/// The shelf is an extra under the detail page, never a reason for the page to look broken: every
/// outcome other than "the server returned at least one title" hides it.
enum MoreLikeThis {
  /// How many titles the shelf asks for (the server's own default).
  static let limit = 12

  /// What the shelf shows for a finished `/similar` request.
  enum Outcome: Equatable {
    case shelf([ItemSummary])
    case hidden
  }

  /// Hide on an empty list and on any failure; show otherwise.
  static func outcome(_ result: Result<ItemsResponse, Error>) -> Outcome {
    switch result {
    case .success(let response):
      return response.items.isEmpty ? .hidden : .shelf(response.items)
    case .failure:
      return .hidden
    }
  }

  /// True for the two answers the server gives on purpose to say "no shelf here": 403
  /// `content_restricted` (the title is above this profile's level) and 404 (the title is gone).
  /// Those are normal and need no log line; any other failure is worth one.
  static func isExpectedHide(_ error: Error) -> Bool {
    guard let api = error as? APIError else { return false }
    switch api {
    case .http(let status):
      return status == 403 || status == 404
    case .server(let code, let status, _):
      return status == 403 || status == 404 || code == "content_restricted" || code == "not_found"
    default:
      return false
    }
  }
}
