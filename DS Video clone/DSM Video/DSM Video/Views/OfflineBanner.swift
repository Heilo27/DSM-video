import SwiftUI

struct OfflineBanner: View {
  let isOffline: Bool
  let serverUnreachable: Bool
  /// TASK-949: the server is unreachable because Local Network access is off. Named, so the
  /// user goes to Settings instead of debugging a NAS that is fine.
  var localNetworkDenied: Bool = false

  private var message: String? {
    Self.message(isOffline: isOffline, serverUnreachable: serverUnreachable,
                 localNetworkDenied: localNetworkDenied)
  }

  static func message(isOffline: Bool, serverUnreachable: Bool, localNetworkDenied: Bool) -> String? {
    if isOffline { return "No internet connection" }
    if localNetworkDenied { return LocalNetworkPermission.bannerMessage }
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
