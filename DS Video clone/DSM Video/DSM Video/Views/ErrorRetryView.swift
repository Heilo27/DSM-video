import SwiftUI

/// TASK-649: reusable error + retry view. The "ContentUnavailableView + Retry
/// button" pattern was duplicated across ~8 screens; this is the single source of
/// truth so the wording, styling, and accessibility stay consistent.
struct ErrorRetryView: View {
  let title: String
  let message: String
  /// Optional retry handler. When nil, no Retry button is shown.
  var retry: (() -> Void)?

  init(title: String = "Something went wrong", message: String, retry: (() -> Void)? = nil) {
    self.title = title
    self.message = message
    self.retry = retry
  }

  var body: some View {
    VStack(spacing: 12) {
      // Compose the themed empty state rather than re-rolling ContentUnavailableView with
      // a manual .foregroundStyle(.white). Two "canonical" components that didn't know
      // about each other meant a styling change to one silently skipped the other.
      DSContentUnavailable(
        title: title,
        systemImage: "exclamationmark.triangle",
        description: message
      )

      if let retry {
        Button("Retry", action: retry)
          .buttonStyle(.borderedProminent)
          .tint(Color.dsAccent)
          .accessibilityHint("Reloads this screen")
      }
    }
  }
}
