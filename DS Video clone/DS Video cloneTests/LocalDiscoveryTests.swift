import Foundation
import Network
import Testing
@testable import DSM_Video

// MARK: - TASK-950 / TASK-949 · server discovery always ends somewhere the screen can name
//
// FR-113 (FRD-001): finding nothing is not an error, and the scan must say so instead of
// spinning forever. FR-115: Local Network access being off is named as such, never reported
// as "No network connection.".

@Suite("Local discovery", .serialized)
@MainActor
struct LocalDiscoveryTests {

  /// OC: TASK-950 AC · after the no-results window with nothing found, the scan reaches a
  /// terminal empty state: the spinner stops and status is `.noneFound`.
  /// Red if: nothing ends the scan (NWBrowser never reports "none").
  @Test func scanWithNoResultsEndsInNoneFound() async throws {
    // The app's own service type: it is the one declared in NSBonjourServices, so the browser
    // goes `.ready` and stays there, as on a real network with no server. (An undeclared type
    // fails at once with NoAuth, which would end the scan without the window.) A short window
    // keeps the test fast.
    let discovery = BonjourDiscovery(noResultsTimeout: .milliseconds(150))
    #expect(discovery.status == .idle, "nothing started yet")
    discovery.startScan()
    #expect(discovery.isScanning)
    #expect(discovery.status == .scanning)

    try await Task.sleep(for: .milliseconds(800))

    #expect(discovery.isScanning == false, "the spinner stops")
    // A DSVideoServer advertising on the test machine's network would legitimately be found.
    if discovery.servers.isEmpty {
      #expect(discovery.status == .noneFound)
    } else {
      #expect(discovery.status == .found)
    }
    discovery.stopScan()
    #expect(discovery.status == .idle, "stopping resets the screen state")
  }

  /// OC: TASK-950 · a browser that fails outright (here, a type the app never declared) also
  /// ends the scan as nothing found, not a spinner.
  @Test func failedBrowserEndsInNoneFound() async throws {
    let discovery = BonjourDiscovery(serviceType: "_dsvnonetest._tcp.",
                                     noResultsTimeout: .seconds(60))
    discovery.startScan()
    try await Task.sleep(for: .milliseconds(800))
    #expect(discovery.isScanning == false)
    #expect(discovery.status == .noneFound)
    discovery.stopScan()
  }

  /// OC: TASK-949 AC · NWBrowser's `.waiting(PolicyDenied)` is Local Network access denied:
  /// a denied state, and the spinner stops.
  /// Red if: `.waiting` is ignored and the scan keeps "looking".
  @Test func policyDeniedWaitIsTheDeniedState() {
    let discovery = BonjourDiscovery(noResultsTimeout: .seconds(60))
    discovery.startScan()
    discovery.handleBrowserState(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
    #expect(discovery.status == .denied)
    #expect(discovery.isScanning == false)

    // The user turns Local Network on in Settings: the browser goes ready and scanning resumes.
    discovery.handleBrowserState(.ready)
    #expect(discovery.status == .scanning)
    discovery.stopScan()
  }

  /// OC: TASK-949 · a wait for any other reason is not a denial.
  @Test func otherWaitIsNotDenied() {
    let discovery = BonjourDiscovery(noResultsTimeout: .seconds(60))
    discovery.startScan()
    discovery.handleBrowserState(.waiting(.posix(.ENETDOWN)))
    #expect(discovery.status == .scanning)
    discovery.stopScan()
  }

  /// OC: TASK-949 AC · a -1009 whose path was refused for Local Network privacy is the denial;
  /// any other -1009 really is a device with no network.
  @Test func notConnectedToInternetIsADenialOnlyWithTheLocalNetworkReason() {
    #expect(LocalNetworkPermission.isDenied(code: .notConnectedToInternet,
                                            unsatisfiedReason: .localNetworkDenied))
    #expect(!LocalNetworkPermission.isDenied(code: .notConnectedToInternet, unsatisfiedReason: nil))
    #expect(!LocalNetworkPermission.isDenied(code: .notConnectedToInternet,
                                             unsatisfiedReason: .notAvailable))
    #expect(!LocalNetworkPermission.isDenied(code: .timedOut, unsatisfiedReason: .localNetworkDenied))
    // A bare -1009 carries no path: the client keeps calling it a connection failure.
    if case .connection(.notConnectedToInternet) = APIError.transport(URLError(.notConnectedToInternet)) {
    } else {
      Issue.record("a -1009 with no Local Network reason must stay .connection")
    }
  }

  /// OC: TASK-949 AC · the denial names the Local Network permission, never "No network connection.".
  @Test func deniedMessageNamesThePermission() {
    let message = APIError.localNetworkDenied.userMessage
    #expect(message.contains("Local Network"))
    #expect(message != APIError.connection(.notConnectedToInternet).userMessage)
    #expect(!APIError.localNetworkDenied.serverReached, "the request never left the device")
  }

  /// OC: TASK-949 AC · a mid-session denial (no WAN to fall back on) names the permission in the
  /// banner and never marks the device offline.
  /// Red if: the denial reaches handleConnectionFailure as -1009 / falls to its no-op default.
  @Test func midSessionDenialNamesThePermissionInTheBanner() async {
    await withIsolatedAppState { state in
      #expect(!state.serverUnreachable && !state.isOffline, "precondition: healthy")
      state.handleConnectionFailure(APIError.localNetworkDenied)
      #expect(state.localNetworkDenied)
      #expect(state.serverUnreachable, "the reconnect loop still runs")
      #expect(!state.isOffline, "the device's own network works")
      let banner = OfflineBanner.cause(isOffline: state.isOffline,
                                         serverUnreachable: state.serverUnreachable,
                                         localNetworkDenied: state.localNetworkDenied)
      #expect(banner?.contains("Local Network") == true)

      state.clearNetworkError()
      #expect(!state.localNetworkDenied, "the server answering again takes it down")
    }
  }
}
