import Testing
import Foundation
import UIKit
@testable import DSM_Video

// TASK-1011 (FR-058): a title played from Downloads showed no lock-screen artwork. The
// downloads player was built with no artworkURL at all; TASK-965 had wired it for streaming
// only. A download played from the title's own page did pass one, but only the server's
// poster URL, which an offline device cannot fetch.
//
// One rule still decides the picture (APIClient.nowPlayingArtworkURL): the poster, else the
// backdrop, else none. A download's saved poster file is that same poster, used first because
// it needs no network.

@Suite("Download Now Playing artwork (TASK-1011)")
@MainActor
struct DownloadArtworkTests {
  private let client = APIClient(baseURL: URL(string: "http://nas.local:8080")!, token: "tok")

  private func query(_ url: URL?) -> [String: String] {
    guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return [:] }
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("dl-artwork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Red if: the downloaded poster is ignored, so an offline download asks the server.
  @Test func theDownloadedPosterIsUsedFirst() throws {
    let file = URL(fileURLWithPath: "/var/mobile/Downloads/m1.poster.jpg")
    let images = ItemDetail.Images(poster: .init(id: "p1", mapperId: nil),
                                   backdrop: .init(id: "b1", mapperId: nil))
    #expect(client.nowPlayingArtworkURL(images: images, version: 3, downloadedPoster: file) == file)
    #expect(client.nowPlayingArtworkURL(images: nil, downloadedPoster: file) == file)
  }

  /// A download with no saved poster (the title has none) still shows its backdrop, from the
  /// catalog's ids. Red if: the catalog lookup drops the backdrop or its version.
  @Test func aDownloadWithNoPosterShowsTheCatalogBackdrop() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = await LocalStore.makeForTesting(databaseURL: dir.appendingPathComponent("dsreel.db"))
    await store.upsertItems([
      ItemSummary(id: "m-backdrop", type: "movie", title: "Only a backdrop", addedAt: "2026-01-01",
                  posterImageId: nil, backdropImageId: "b7", libraryId: "lib", changeSeq: 4),
      ItemSummary(id: "m-poster", type: "movie", title: "Has a poster", addedAt: "2026-01-01",
                  posterImageId: "p9", backdropImageId: "b9", libraryId: "lib", changeSeq: 2),
    ])

    let backdropOnly = try #require(await store.artworkImages(forItemID: "m-backdrop"))
    let url = try #require(client.nowPlayingArtworkURL(images: backdropOnly.images,
                                                       version: backdropOnly.changeSeq))
    #expect(url.path == "/api/v1/images/b7")
    #expect(query(url)["type"] == "backdrop")
    #expect(query(url)["v"] == "4")

    let withPoster = try #require(await store.artworkImages(forItemID: "m-poster"))
    let posterURL = try #require(client.nowPlayingArtworkURL(images: withPoster.images,
                                                             version: withPoster.changeSeq))
    #expect(posterURL.path == "/api/v1/images/p9")
    #expect(query(posterURL)["v"] == "2")

    #expect(await store.artworkImages(forItemID: "not-in-catalog") == nil)
  }

  /// The player's artwork loader reads a downloaded poster's file URL from disk (URLSession
  /// serves file URLs). Red if: the loader stops accepting file URLs, so no artwork offline.
  @Test func thePlayerLoadsADownloadedPosterFromDisk() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("m1.poster.jpg")
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1  // 20x30 pixels, so the decoded file reads back as 20x30
    let poster = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format).image { ctx in
      UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
    }
    try #require(poster.jpegData(compressionQuality: 0.9)).write(to: file)

    let image = await AuthenticatedImageLoader.image(url: file, token: nil, usesTunnelCookie: false)
    #expect(image?.size.width == 20)
    #expect(image?.size.height == 30)
  }

  /// Every player the app builds is handed artwork, and every artwork URL comes from the one
  /// rule. Red if: the downloads player is built without `artworkURL:` again, or a second
  /// place picks artwork its own way.
  @Test func everyPlayerGetsArtworkFromTheOneRule() throws {
    let appRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("DSM Video")
    var playersWithoutArtwork: [String] = []
    var ruleCalls: [String] = []
    let files = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)
    while let file = files?.nextObject() as? URL {
      guard file.pathExtension == "swift" else { continue }
      let source = try String(contentsOf: file, encoding: .utf8)
      // Each `GestureVideoPlayer(` construction, up to its trailing closure arguments.
      for chunk in source.components(separatedBy: "GestureVideoPlayer(").dropFirst() {
        let head = chunk.components(separatedBy: "onDismiss:").first ?? chunk
        if head.hasPrefix("\n        url: URL(string: \"https://commondatastorage") { continue }  // #Preview
        if !head.contains("artworkURL:") { playersWithoutArtwork.append(file.lastPathComponent) }
      }
      let calls = source.components(separatedBy: ".nowPlayingArtworkURL(").count - 1
      ruleCalls += Array(repeating: file.lastPathComponent, count: calls)
    }
    #expect(playersWithoutArtwork.isEmpty, "players built with no artwork: \(playersWithoutArtwork)")
    #expect(ruleCalls.sorted() == ["ItemDetailView.swift", "MainView.swift"],
            "the title page's player and the downloads player both ask the one rule")
  }
}
