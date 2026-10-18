import Testing
import Foundation
import AVFoundation
@testable import DSM_Video

// TASK-1006 repro (FR-115, FR-054): with Local Network access off, a stream from the NAS on the
// LAN fails with -1009 (.notConnectedToInternet), and the player said "No network connection."
// on a device whose network works. AVFoundation loads the stream out of process, so the error
// may not carry the path that names the denial; the app's own localNetworkDenied state does.

private func avError(_ code: Int, underlying: Error? = nil) -> NSError {
  var info: [String: Any] = [:]
  if let underlying { info[NSUnderlyingErrorKey] = underlying }
  return NSError(domain: AVFoundationErrorDomain, code: code, userInfo: info)
}

private let playerSource: URL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()          // DS Video cloneTests
  .deletingLastPathComponent()          // DS Video clone
  .appendingPathComponent("DSM Video/DSM Video/Views/GestureVideoPlayer.swift")

@Suite("Local Network denial in the player and watchlist notice (TASK-1006)")
struct LocalNetworkPlayerErrorTests {

  @Test("A -1009 stream failure while Local Network access is off names the permission")
  func deniedStreamFailureNamesPermission() {
    let failure = avError(-11800, underlying: NSError(domain: NSURLErrorDomain,
                                                      code: NSURLErrorNotConnectedToInternet))
    let message = GestureVideoPlayer.friendlyPlayerError(failure, localNetworkDenied: true)
    #expect(message == LocalNetworkPermission.deniedMessage)
    #expect(message != "No network connection.")
  }

  @Test("A -1009 with Local Network access allowed is still no network")
  func plainNoNetworkUnchanged() {
    let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    #expect(GestureVideoPlayer.friendlyPlayerError(failure, localNetworkDenied: false) == "No network connection.")
  }

  @Test("Every player error site passes the Local Network state into the one mapping")
  func everyPlayerSitePassesTheState() throws {
    let source = try #require(try? String(contentsOf: playerSource, encoding: .utf8))
    let calls = source.components(separatedBy: "friendlyPlayerError(").count - 1
    let informed = source.components(separatedBy: "friendlyPlayerError($0, localNetworkDenied: localNetworkDenied)").count - 1
    // One occurrence of "friendlyPlayerError(" is the declaration itself.
    #expect(calls - 1 >= 2, "precondition: the player has its error sites")
    #expect(informed == calls - 1, "a player error site maps errors without the Local Network state")
  }

  @Test("A failed watchlist change names Local Network access, not the NAS") @MainActor
  func watchlistNoticeNamesPermission() {
    #expect(AppState.watchlistNotice(isOffline: false, serverUnreachable: true, localNetworkDenied: true)
            == "Couldn't update your watchlist. \(LocalNetworkPermission.bannerMessage).")
  }
}
