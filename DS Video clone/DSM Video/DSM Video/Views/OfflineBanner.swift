import SwiftUI

struct OfflineBanner: View {
  let isOffline: Bool
  let serverUnreachable: Bool
  /// TASK-949: the server is unreachable because Local Network access is off. Named, so the
  /// user goes to Settings instead of debugging a NAS that is fine.
  var localNetworkDenied: Bool = false

  private var message: String? {
    Self.cause(isOffline: isOffline, serverUnreachable: serverUnreachable,
               localNetworkDenied: localNetworkDenied)
  }

  /// The one wording for the connection state (FR-130, FR-141). The iOS banner, the tvOS
  /// indicator and messages about a failed write all name the cause with these strings.
  static func cause(isOffline: Bool, serverUnreachable: Bool, localNetworkDenied: Bool = false) -> String? {
    if isOffline { return "No internet connection" }
    if localNetworkDenied { return LocalNetworkPermission.bannerMessage }
    if serverUnreachable { return "Can't reach your NAS" }
    return nil
  }

  /// The icon paired with `cause`, shared with the tvOS indicator.
  static func symbol(isOffline: Bool) -> String {
    isOffline ? "wifi.slash" : "server.rack"
  }

  var body: some View {
    if let message {
      HStack(spacing: 8) {
        Image(systemName: Self.symbol(isOffline: isOffline))
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
      .accessibilityIdentifier(A11y.Shared.offlineBanner)
      .onAppear {
        AccessibilityNotification.Announcement(message).post()
      }
    }
  }
}

/// The tvOS form of OfflineBanner (TASK-988, FR-130/FR-132/FR-141): a compact capsule over
/// the top of the screen rather than a full-width bar, so it sits in the header's open space
/// instead of pushing the 10-foot layout down. Same wording and icon as the iOS banner.
/// Not focusable and not hit-testable: it reports state and must never take focus.
struct ConnectionIndicator: View {
  let isOffline: Bool
  let serverUnreachable: Bool
  /// TASK-1006 (FR-115): named on Apple TV exactly as on iPhone.
  var localNetworkDenied: Bool = false

  static func text(isOffline: Bool, serverUnreachable: Bool, localNetworkDenied: Bool = false) -> String? {
    OfflineBanner.cause(isOffline: isOffline, serverUnreachable: serverUnreachable,
                        localNetworkDenied: localNetworkDenied)
  }

  var body: some View {
    ZStack {
      if let text = Self.text(isOffline: isOffline, serverUnreachable: serverUnreachable,
                              localNetworkDenied: localNetworkDenied) {
        Label(text, systemImage: OfflineBanner.symbol(isOffline: isOffline))
          .font(.callout.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 24)
          .padding(.vertical, 12)
          .background(Capsule().fill(Color(white: 0.2)))
          .transition(.opacity)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier(A11y.Shared.offlineBanner)
          .onAppear { AccessibilityNotification.Announcement(text).post() }
      }
    }
    .focusable(false)
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.3), value: isOffline || serverUnreachable || localNetworkDenied)
  }
}

/// A short-lived message about a change that just failed and was undone (TASK-989, FR-137),
/// e.g. a watchlist toggle the NAS never received. It is neither focusable nor tappable, so
/// it never takes focus on tvOS, and it clears itself after `displaySeconds`.
struct TransientNoticeBanner: View {
  @Binding var message: String?
  /// False for a second copy shown over a sheet, so VoiceOver hears the message once.
  var announces: Bool = true

  static let displaySeconds: UInt64 = 4

  var body: some View {
    ZStack {
      if let message {
        Text(message)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(Capsule().fill(Color(white: 0.15)))
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .accessibilityIdentifier(A11y.Shared.transientNotice)
      }
    }
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.3), value: message)
    // Keyed on the message: a new message announces itself and restarts the timer, and the
    // timer only clears the message it was started for.
    .task(id: message) {
      guard let shown = message else { return }
      if announces { AccessibilityNotification.Announcement(shown).post() }
      try? await Task.sleep(nanoseconds: Self.displaySeconds * 1_000_000_000)
      if !Task.isCancelled, message == shown { message = nil }
    }
  }
}
