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
      ContentUnavailableView(
        title,
        systemImage: "exclamationmark.triangle",
        description: Text(message)
      )
      .foregroundStyle(.white)

      if let retry {
        Button("Retry", action: retry)
          .buttonStyle(.borderedProminent)
          .tint(Color.dsAccent)
          .accessibilityHint("Reloads this screen")
      }
    }
  }
}
