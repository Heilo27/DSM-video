import Testing
import Foundation
import MediaPlayer
import UIKit
@testable import DSM_Video

// TASK-965 repro (FR-058): the Now Playing surface (lock screen, Control Center, AirPlay
// picker) showed title and progress but never any artwork; MPMediaItemPropertyArtwork was
// never set. These pin the three rules the fix adds: which image is used, that a title with
// no image leaves NO picture rather than the previous title's, and that the rest of the
// Now Playing fields survive either way.

@Suite("Now Playing artwork (TASK-965)")
@MainActor
struct NowPlayingArtworkTests {
  private let client = APIClient(baseURL: URL(string: "http://nas.local:8080")!, token: "tok")

  private func images(_ json: String) throws -> ItemDetail.Images {
    try JSONDecoder().decode(ItemDetail.Images.self, from: Data(json.utf8))
  }

  private func query(_ url: URL?) -> [String: String] {
    guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return [:] }
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  @Test("the poster is used when the title has one")
  func posterPreferred() throws {
    let imgs = try images(#"{"poster":{"id":"p1"},"backdrop":{"id":"b1"}}"#)
    let url = try #require(client.nowPlayingArtworkURL(images: imgs, version: 7))
    #expect(url.path == "/api/v1/images/p1")
    #expect(query(url)["type"] == nil)      // poster is the server default
    #expect(query(url)["v"] == "7")
  }

  @Test("the backdrop is used when there is no poster, by id or by mapper id")
  func backdropFallback() throws {
    let byID = try images(#"{"poster":null,"backdrop":{"id":"b1"}}"#)
    let url = try #require(client.nowPlayingArtworkURL(images: byID))
    #expect(url.path == "/api/v1/images/b1")
    // Without ?type=backdrop the server returns the POSTER for a shared id.
    #expect(query(url)["type"] == "backdrop")

    let byMapper = try images(#"{"backdrop":{"mapperId":"m9"}}"#)
    let mapperURL = try #require(client.nowPlayingArtworkURL(images: byMapper))
    #expect(mapperURL.path == "/api/v1/images/m9")
    #expect(query(mapperURL)["type"] == "backdrop")
  }

  @Test("no artwork URL when the title has neither image")
  func noneWhenNoImages() throws {
    #expect(client.nowPlayingArtworkURL(images: nil) == nil)
    #expect(client.nowPlayingArtworkURL(images: try images("{}")) == nil)
  }

  @Test("a title without artwork removes the previous title's picture and keeps its other fields")
  func missingArtworkClearsStalePicture() {
    let stale = GestureVideoPlayer.makeArtwork(UIImage())
    let previous: [String: Any] = [MPMediaItemPropertyTitle: "Episode 1",
                                   MPMediaItemPropertyArtwork: stale]
    var next = previous
    next[MPMediaItemPropertyTitle] = "Episode 2"

    let info = GestureVideoPlayer.nowPlayingInfo(next, artwork: nil)
    #expect(info[MPMediaItemPropertyArtwork] == nil)
    #expect(info[MPMediaItemPropertyTitle] as? String == "Episode 2")
  }

  @Test("loaded artwork is published alongside the other fields")
  func artworkPublished() {
    let artwork = GestureVideoPlayer.makeArtwork(UIImage())
    let info = GestureVideoPlayer.nowPlayingInfo(
      [MPMediaItemPropertyTitle: "Movie", MPMediaItemPropertyPlaybackDuration: 5400.0],
      artwork: artwork)
    #expect(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork === artwork)
    #expect(info[MPMediaItemPropertyTitle] as? String == "Movie")
    #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 5400)
  }
}
