import Testing
import Foundation
import AVFoundation
@testable import DSM_Video

// TASK-981 repro (FR-054 / FR-002): AVFoundation wraps the real cause of a failed stream in
// NSUnderlyingErrorKey. A Wi-Fi drop arrives as AVErrorUnknown (-11800) wrapping an
// NSURLError, and the player told the user the file may be corrupted.
//
// Expected strings are literals from the player's existing transport mapping; a format
// failure keeps the format message.

private func avError(_ code: Int, underlying: Error? = nil) -> NSError {
  var info: [String: Any] = [:]
  if let underlying { info[NSUnderlyingErrorKey] = underlying }
  return NSError(domain: AVFoundationErrorDomain, code: code, userInfo: info)
}

private func urlError(_ code: Int) -> NSError {
  NSError(domain: NSURLErrorDomain, code: code)
}

@Suite("Player error mapping (TASK-981)")
struct PlayerErrorMappingTests {

  @Test("-11800 wrapping NetworkConnectionLost names the network, not the file")
  func unknownWrappingConnectionLost() {
    let message = GestureVideoPlayer.friendlyPlayerError(
      avError(-11800, underlying: urlError(NSURLErrorNetworkConnectionLost)))
    #expect(message == "Lost connection to the server mid-playback. Check your network and try again.")
    #expect(!message.localizedCaseInsensitiveContains("corrupt"))
  }

  @Test("-11800 wrapping TimedOut names the server")
  func unknownWrappingTimedOut() {
    let message = GestureVideoPlayer.friendlyPlayerError(
      avError(-11800, underlying: urlError(NSURLErrorTimedOut)))
    #expect(message == "The server stopped responding. Check that your NAS is awake and reachable.")
  }

  @Test("-11800 wrapping CannotConnectToHost names the NAS")
  func unknownWrappingCannotConnect() {
    let message = GestureVideoPlayer.friendlyPlayerError(
      avError(-11800, underlying: urlError(NSURLErrorCannotConnectToHost)))
    #expect(message == "Can't reach your NAS. Check that it's powered on and on the same network.")
  }

  @Test("The transport cause is found when CoreMedia sits between AVFoundation and the URL error")
  func nestedTwoDeep() {
    let coreMedia = NSError(domain: "CoreMediaErrorDomain", code: -12938,
                            userInfo: [NSUnderlyingErrorKey: urlError(NSURLErrorNetworkConnectionLost)])
    let message = GestureVideoPlayer.friendlyPlayerError(avError(-11800, underlying: coreMedia))
    #expect(message == "Lost connection to the server mid-playback. Check your network and try again.")
  }

  @Test("A genuine -11828 keeps the format message")
  func genuineFormatError() {
    #expect(GestureVideoPlayer.friendlyPlayerError(avError(-11828)) == "Format not supported.")
  }
}
