import Testing
import Foundation
@testable import DSM_Video

// TASK-991 repro (FR-052, FRD-000 M5): leaving the house mid-episode switched the app from
// the LAN to the WAN address and posted .networkDidReconnect, but the open player ignored
// it. Its stream URL, built by the server from the LAN address the request came in on, kept
// pointing at a host the phone could no longer reach, and playback stopped.
//
// The player's decision on that notification is StreamReresolution.isNeeded. These tests
// simulate the address switch: the first fails if the player keeps the old LAN stream.

@Suite("Stream re-resolution on reconnect (TASK-991)")
struct StreamReresolutionTests {
  private let lan = URL(string: "http://192.168.50.148:5000")!
  private let wan = URL(string: "https://nas.example.synology.me:5001")!
  private let lanStream = URL(string: "http://192.168.50.148:5000/api/v1/playback/s1/stream")!

  @Test("a LAN-resolved stream is re-resolved when the app switches to the WAN address")
  func switchToWANReresolves() {
    #expect(StreamReresolution.isNeeded(playing: lanStream, resolvedThrough: lan,
                                        currentBase: wan, lastLoadFailedOnConnection: false))
  }

  @Test("and back again: a WAN-resolved stream is re-resolved on returning home")
  func switchToLANReresolves() {
    let wanStream = URL(string: "https://nas.example.synology.me:5001/api/v1/playback/s2/stream")!
    #expect(StreamReresolution.isNeeded(playing: wanStream, resolvedThrough: wan,
                                        currentBase: lan, lastLoadFailedOnConnection: false))
  }

  @Test("a reconnect to the same address leaves the stream alone")
  func sameAddressKeepsStream() {
    #expect(!StreamReresolution.isNeeded(playing: lanStream, resolvedThrough: lan,
                                         currentBase: lan, lastLoadFailedOnConnection: false))
  }

  @Test("a server with its own public stream host is not rebuilt on every reconnect")
  func operatorPublicURLNotChurned() {
    // requestBaseURL() on the server prefers an operator-set base URL, so the stream host
    // can differ from the client's address permanently. Only a change of the CLIENT'S
    // address means the stream is stranded.
    let publicStream = URL(string: "https://video.example.com/api/v1/playback/s3/stream")!
    #expect(!StreamReresolution.isNeeded(playing: publicStream, resolvedThrough: wan,
                                         currentBase: wan, lastLoadFailedOnConnection: false))
  }

  @Test("a downloaded file never re-resolves")
  func downloadedFileUntouched() {
    let file = URL(fileURLWithPath: "/var/mobile/Downloads/movie.mp4")
    #expect(!StreamReresolution.isNeeded(playing: file, resolvedThrough: nil,
                                         currentBase: wan, lastLoadFailedOnConnection: true))
  }

  @Test("a load that failed on the network retries on reconnect; other failures do not")
  func failedLoadRetriesOnlyForNetwork() {
    #expect(StreamReresolution.isNeeded(playing: nil, resolvedThrough: nil,
                                        currentBase: wan, lastLoadFailedOnConnection: true))
    #expect(!StreamReresolution.isNeeded(playing: nil, resolvedThrough: nil,
                                         currentBase: wan, lastLoadFailedOnConnection: false))
  }
}
