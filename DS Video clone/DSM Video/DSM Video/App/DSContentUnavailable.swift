import SwiftUI

/// Themed empty-state wrapper around `ContentUnavailableView` (A28).
///
/// Standardizes the look of empty states across the app: a white primary title
/// and a `dsTextSecondary` description, so they read consistently on the dark
/// surfaces rather than inheriting muted system defaults.
struct DSContentUnavailable: View {
    let title: String
    let systemImage: String
    var description: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.white)
        } description: {
            if let description {
                Text(description)
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }
    }
}
