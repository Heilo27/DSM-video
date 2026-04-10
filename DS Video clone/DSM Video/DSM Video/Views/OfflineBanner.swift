import SwiftUI

struct OfflineBanner: View {
  let isOffline: Bool
  let serverUnreachable: Bool

  private var message: String? {
    if isOffline { return "No internet connection" }
    if serverUnreachable { return "Can't reach your NAS" }
    return nil
  }

  var body: some View {
    if let message {
      HStack(spacing: 8) {
        Image(systemName: isOffline ? "wifi.slash" : "server.rack")
          .font(.footnote.weight(.semibold))
          .accessibilityHidden(true)
        Text(message)
          .font(.footnote.weight(.semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .background(Color(white: 0.15))
      .transition(.move(edge: .top).combined(with: .opacity))
      .onAppear {
        AccessibilityNotification.Announcement(message).post()
      }
    }
  }
}
