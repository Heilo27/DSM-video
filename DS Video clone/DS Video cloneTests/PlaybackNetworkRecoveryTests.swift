import Testing
import Foundation
import AVFoundation
@testable import DSM_Video

// TASK-1008 (FR-052): TASK-991 rebuilt the stream on an ADDRESS switch and retried a failed
// LOAD, but a stream that died mid-playback on a network failure stayed on its error when the
// network came back at the same address: StreamReresolution saw the same base and said no.
//
// The ticket's report, simulated: the stream fails on a dropped connection at the LAN address,
// the network returns at that same LAN address, and the player must rebuild. A failure that is
// not the network (a decode error, an HTTP 404 on a stale session) must not auto-retry.

private func avError(_ code: Int, underlying: Error? = nil) -> NSError {
  var info: [String: Any] = [:]
  if let underlying { info[NSUnderlyingErrorKey] = underlying }
  return NSError(domain: AVFoundationErrorDomain, code: code, userInfo: info)
}

private func urlError(_ code: Int) -> NSError { NSError(domain: NSURLErrorDomain, code: code) }

@Suite("Mid-playback network failure recovers at the same address (TASK-1008)")
struct PlaybackNetworkRecoveryTests {
  private let lan = URL(string: "http://192.168.50.148:5000")!
  private let lanStream = URL(string: "http://192.168.50.148:5000/api/v1/playback/s1/stream")!

  /// Red if: a stream that failed on the network is left on its error when the network
  /// returns at the address it was resolved through.
  @Test func networkFailureRetriesAtTheSameAddress() {
    #expect(StreamReresolution.isNeeded(playing: lanStream, resolvedThrough: lan, currentBase: lan,
                                        lastLoadFailedOnConnection: false,
                                        playbackFailedOnConnection: true))
  }

  /// A healthy stream, or one that failed for another reason, is not rebuilt on a same-address
  /// reconnect (AC 2), and a local file never is.
  @Test func otherFailuresDoNotAutoRetry() {
    #expect(!StreamReresolution.isNeeded(playing: lanStream, resolvedThrough: lan, currentBase: lan,
                                         lastLoadFailedOnConnection: false,
                                         playbackFailedOnConnection: false))
    let file = URL(fileURLWithPath: "/var/mobile/Downloads/movie.mp4")
    #expect(!StreamReresolution.isNeeded(playing: file, resolvedThrough: nil, currentBase: lan,
                                         lastLoadFailedOnConnection: false,
                                         playbackFailedOnConnection: true))
  }

  /// Red if: a dropped connection is not classified as a network failure, or a decode error,
  /// an HTTP error from the server, or a cancellation is.
  @Test func classifiesNetworkFailures() {
    #expect(GestureVideoPlayer.isNetworkPlaybackFailure(
      avError(-11800, underlying: urlError(NSURLErrorNetworkConnectionLost))))
    let coreMedia = NSError(domain: "CoreMediaErrorDomain", code: -12938,
                            userInfo: [NSUnderlyingErrorKey: urlError(NSURLErrorTimedOut)])
    #expect(GestureVideoPlayer.isNetworkPlaybackFailure(avError(-11800, underlying: coreMedia)))
    #expect(GestureVideoPlayer.isNetworkPlaybackFailure(urlError(NSURLErrorNotConnectedToInternet)))

    #expect(!GestureVideoPlayer.isNetworkPlaybackFailure(avError(AVError.Code.decodeFailed.rawValue)))
    #expect(!GestureVideoPlayer.isNetworkPlaybackFailure(
      avError(-11800, underlying: NSError(domain: "CoreMediaErrorDomain", code: -12938))))
    #expect(!GestureVideoPlayer.isNetworkPlaybackFailure(urlError(NSURLErrorCancelled)))
  }

  /// The decision only helps if the player reports its errors and the sheet listens for both
  /// "network is back" signals. Red if: an error site stops reporting, or the sheet stops
  /// passing the flag or watching the same-address recovery.
  @Test func playerReportsAndSheetListens() throws {
    let views = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("DSM Video/DSM Video/Views")
    let player = try String(contentsOf: views.appendingPathComponent("GestureVideoPlayer.swift"), encoding: .utf8)
    let sheet = try String(contentsOf: views.appendingPathComponent("ItemDetailView.swift"), encoding: .utf8)
    let errorSites = player.components(separatedBy: "friendlyPlayerError($0, localNetworkDenied: localNetworkDenied)").count - 1
    let reports = player.components(separatedBy: "onPlaybackError?(").count - 1
    #expect(errorSites == 2, "precondition: two AVPlayer error sites")
    #expect(reports == errorSites, "every AVPlayer error site reports to the sheet")
    // Sticky since TASK-991: AVPlayer can report one drop twice, the second time with no
    // underlying error, and that second report must not clear the first.
    #expect(sheet.contains("if failedOnNetwork { playbackFailedOnConnection = true }"))
    #expect(sheet.contains("playbackFailedOnConnection: playbackFailedOnConnection"))
    #expect(sheet.contains(".onChange(of: appState.serverUnreachable)"))
  }
}
