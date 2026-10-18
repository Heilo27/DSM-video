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
      HStack(spacing: .dsSpaceSM) {
        Image(systemName: Self.symbol(isOffline: isOffline))
          .font(.footnote.weight(.semibold))
          .accessibilityHidden(true)
        Text(message)
          .font(.footnote.weight(.semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, .dsSpaceLG)
      .padding(.vertical, .dsSpaceSM)
      .frame(maxWidth: .infinity)
      .background(Color.dsSurfaceRaised)
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
          .padding(.horizontal, .dsSpaceXXL)
          .padding(.vertical, .dsSpaceMD)
          .background(Capsule().fill(Color.dsSurfaceRaised))
          .transition(.opacity)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier(A11y.Shared.offlineBanner)
          .onAppear { AccessibilityNotification.Announcement(text).post() }
      }
    }
    .focusable(false)
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.3),
               value: AppState.serverUnavailable(isOffline: isOffline, serverUnreachable: serverUnreachable)
                 || localNetworkDenied)
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
          .padding(.horizontal, .dsSpaceLG)
          .padding(.vertical, 10)
          .background(Capsule().fill(Color.dsSurfaceRaised))
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

/// This device's local store could not open, so watch history is not kept here (TASK-1012,
/// FR-015). Shown for as long as that lasts; there is nothing to tap, so it never takes focus
/// on tvOS. The text is LocalStore.unavailableReason, passed through AppState.
struct LocalStoreBanner: View {
  let message: String?
  /// Lets LocalStoreRecoveryBanner reuse this look under its own identifier.
  var identifier: String = A11y.Shared.localStoreBanner

  var body: some View {
    ZStack {
      if let message {
        Label(message, systemImage: "externaldrive.badge.exclamationmark")
          #if os(tvOS)
          .font(.callout.weight(.semibold))
          .padding(.horizontal, .dsSpaceXXL)
          .padding(.vertical, .dsSpaceMD)
          .background(Capsule().fill(Color.dsSurfaceRaised))
          #else
          .font(.footnote.weight(.semibold))
          .padding(.horizontal, .dsSpaceLG)
          .padding(.vertical, .dsSpaceSM)
          .frame(maxWidth: .infinity)
          .background(Color.dsSurfaceRaised)
          #endif
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .transition(.opacity)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier(identifier)
          .onAppear { AccessibilityNotification.Announcement(message).post() }
      }
    }
    .focusable(false)
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.3), value: message)
  }
}

/// This device's local store was found damaged and rebuilt empty on this launch (TASK-1034,
/// FR-015). The store works, so this is information rather than a fault: it explains why the
/// library is empty for a moment, then clears itself after `displaySeconds`. Same look as
/// LocalStoreBanner; never takes focus on tvOS. The text is LocalStore.recoveryNotice,
/// passed through AppState.
struct LocalStoreRecoveryBanner: View {
  @Binding var message: String?

  /// Longer than TransientNoticeBanner's 4 seconds: this is two sentences the user has to
  /// read, not a one-line confirmation.
  static let displaySeconds: UInt64 = 12

  var body: some View {
    LocalStoreBanner(message: message, identifier: A11y.Shared.localStoreRecoveryBanner)
      // Keyed on the message, and only clears the message it was started for.
      .task(id: message) {
        guard let shown = message else { return }
        try? await Task.sleep(nanoseconds: Self.displaySeconds * 1_000_000_000)
        if !Task.isCancelled, message == shown { message = nil }
      }
  }
}
