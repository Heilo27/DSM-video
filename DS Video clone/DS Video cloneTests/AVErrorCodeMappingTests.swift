import Testing
import Foundation
import AVFoundation
@testable import DSM_Video

// TASK-1007 (FR-002): the player labelled two AVFoundation codes with somebody else's meaning.
// Per AVError.h, -11819 is AVErrorMediaServicesWereReset (the system's media daemon restarted)
// and -11821 is AVErrorDecodeFailed (the device could not decode the media). The player called
// them "The operation was cancelled." and "Cannot connect to the server." — the second sent
// users hunting for a network fault on a file their device simply can't decode.
//
// The codes are taken from the SDK's own constants, not typed by hand, so the test proves the
// mapping matches Apple's meaning.

@Suite("AVFoundation code meanings (TASK-1007)")
struct AVErrorCodeMappingTests {
  private func message(_ code: AVError.Code) -> String {
    GestureVideoPlayer.friendlyPlayerError(
      NSError(domain: AVFoundationErrorDomain, code: code.rawValue))
  }

  /// Red if: decodeFailed blames the server or the connection.
  @Test func decodeFailedNamesDecodingNotTheServer() {
    #expect(AVError.Code.decodeFailed.rawValue == -11821, "precondition: Apple's code")
    let text = message(.decodeFailed)
    #expect(text.localizedCaseInsensitiveContains("decode"), "names the decode failure: \(text)")
    #expect(!text.localizedCaseInsensitiveContains("server"), "does not blame the server: \(text)")
    #expect(!text.localizedCaseInsensitiveContains("connect"), "does not blame the connection: \(text)")
    #expect(!text.localizedCaseInsensitiveContains("network"), "does not blame the network: \(text)")
  }

  #if os(iOS) || os(tvOS)
  /// Red if: mediaServicesWereReset is reported as the user cancelling.
  @Test func mediaServicesResetIsNotCancellation() {
    #expect(AVError.Code.mediaServicesWereReset.rawValue == -11819, "precondition: Apple's code")
    let text = message(.mediaServicesWereReset)
    #expect(!text.localizedCaseInsensitiveContains("cancel"), "not a cancellation: \(text)")
    #expect(text.localizedCaseInsensitiveContains("media services"), "names the reset: \(text)")
    #expect(text.localizedCaseInsensitiveContains("try again"), "the user can recover: \(text)")
  }
  #endif

  /// The other mapped codes keep their messages (AC 3).
  @Test func otherMappingsUnchanged() {
    #expect(message(.unknown) == "Playback failed. The file may be corrupted.")
    #expect(message(.fileFormatNotRecognized) == "Format not supported.")
    #expect(message(.failedToLoadMediaData) == "Could not load media.")
    #expect(message(.serverIncorrectlyConfigured) == "Playback failed. The media is not accessible.")
    #expect(message(.fileFailedToParse) == "This video's format isn't supported.")
  }
}
