import Testing
import Foundation
@testable import DSM_Video

// TASK-988 repro (FR-130, FR-132, FR-141): the iOS root overlays OfflineBanner, but TVMainView
// had no equivalent. On Apple TV an unreachable NAS left cached rails looking live, with
// nothing on screen saying the server was offline.
//
// TVMainView is tvOS-only and does not compile into this iOS test target, so the placement is
// checked against its source: removing the indicator from the tvOS root fails the first test.
// The wording and the clear-on-reconnect behaviour are checked through the shared code the
// indicator renders.

private let tvMainViewSource: URL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()          // DS Video cloneTests
  .deletingLastPathComponent()          // DS Video clone
  .appendingPathComponent("DSM Video/DSM Video/Views/TVMainView.swift")

@Suite("tvOS offline indicator (TASK-988)", .serialized)
@MainActor
struct TVConnectionIndicatorTests {

  @Test("The tvOS root shows the connection indicator, driven by the live connection flags")
  func tvRootRendersIndicator() throws {
    let source = try #require(try? String(contentsOf: tvMainViewSource, encoding: .utf8),
                              "TVMainView.swift not found at \(tvMainViewSource.path)")
    #expect(source.contains(
      "ConnectionIndicator(isOffline: appState.isOffline, serverUnreachable: appState.serverUnreachable,"),
      "TVMainView no longer shows the offline indicator")
    // TASK-1006 (FR-115): the indicator is also told when Local Network access is off.
    #expect(source.contains("localNetworkDenied: appState.localNetworkDenied)"),
            "TVMainView's indicator does not pass the Local Network state")
  }

  @Test("The indicator names the cause in the same words as the iOS banner")
  func indicatorWording() {
    #expect(ConnectionIndicator.text(isOffline: true, serverUnreachable: false) == "No internet connection")
    #expect(ConnectionIndicator.text(isOffline: false, serverUnreachable: true) == "Can't reach your NAS")
    #expect(ConnectionIndicator.text(isOffline: true, serverUnreachable: true) == "No internet connection",
            "no internet is the deeper cause, so it wins")
    #expect(ConnectionIndicator.text(isOffline: false, serverUnreachable: false) == nil,
            "connected: nothing is shown")
    #expect(ConnectionIndicator.text(isOffline: false, serverUnreachable: true, localNetworkDenied: true)
            == LocalNetworkPermission.bannerMessage,
            "TASK-1006: Local Network access off is named on Apple TV as on iPhone")
  }

  @Test("Reconnecting clears the indicator and keeps the user signed in")
  func clearsOnReconnectWithoutSignOut() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset([:])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        state.serverUnreachable = true
        #expect(ConnectionIndicator.text(isOffline: state.isOffline,
                                         serverUnreachable: state.serverUnreachable) == "Can't reach your NAS")

        state.clearNetworkError()

        #expect(ConnectionIndicator.text(isOffline: state.isOffline,
                                         serverUnreachable: state.serverUnreachable) == nil)
        #expect(state.sessionToken == "stub-token", "reconnecting must not sign the user out")
      }
    }
  }
}
