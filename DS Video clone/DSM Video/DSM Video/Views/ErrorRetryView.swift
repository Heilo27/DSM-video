import SwiftUI

/// TASK-649: reusable error + retry view. The "ContentUnavailableView + Retry
/// button" pattern was duplicated across ~8 screens; this is the single source of
/// truth so the wording, styling, and accessibility stay consistent.
struct ErrorRetryView: View {
  let title: String
  let message: String
  /// Optional retry handler. When nil, no Retry button is shown.
  var retry: (() -> Void)?
  /// `dsPrimaryButton` draws the focus look; the binding is what lets the tvOS focus engine land here.
  @FocusState private var retryFocused: Bool

  init(title: String = "Something went wrong", message: String, retry: (() -> Void)? = nil) {
    self.title = title
    self.message = message
    self.retry = retry
  }

  var body: some View {
    VStack(spacing: .dsSpaceMD) {
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
          .dsPrimaryButton(.card, minWidth: 200)
          .focused($retryFocused)
          .accessibilityHint("Reloads this screen")
      }
    }
  }
}

/// FR-098 (TASK-975): the non-blocking counterpart of `ErrorRetryView`. A refresh failed but the
/// content already on screen is still valid, so this sits above it as a slim bar instead of
/// replacing it. Which of the two to show is `LoadFailurePresentation.decide`.
struct RefreshFailedNotice: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    HStack(spacing: .dsSpaceMD) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(Color.dsAccent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: .dsSpaceXXS) {
        Text(LoadFailurePresentation.noticeTitle)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color.dsTextPrimary)
        Text("\(message) Showing what was already loaded.")
          .font(.caption)
          .foregroundStyle(Color.dsTextSecondary)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      Button("Retry", action: retry)
        .accessibilityHint("Tries to refresh again")
    }
    .padding(.horizontal, .dsSpaceLG)
    .padding(.vertical, .dsSpaceSM)
    .frame(maxWidth: .infinity)
    .background(Color.dsSurface)
    .accessibilityElement(children: .contain)
  }
}
