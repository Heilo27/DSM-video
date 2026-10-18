import Testing
import Foundation
@testable import DSM_Video

// TASK-1009 (FR-052): the server builds a stream URL from the address the request arrived on.
// If the app switched address while the playback-info request was in flight, the reply still
// carried the OLD address's stream. The networkDidReconnect for the switch had already been
// handled (nothing was playing yet, so there was nothing to rebuild), and the player adopted a
// stream on a host it could no longer reach.
//
// The race is simulated by a fetch that switches the app's address while it is "in flight".

@MainActor
private final class Network {
  var base: URL
  var fetches = 0
  var discarded: [String] = []
  init(base: URL) { self.base = base }
}

@Suite("Playback-info race on an address switch (TASK-1009)")
@MainActor
struct PlaybackInfoRaceTests {
  private let lan = URL(string: "http://192.168.50.148:5000")!
  private let wan = URL(string: "https://nas.example.synology.me:5001")!

  /// Red if: the reply resolved through the old address is used.
  @Test func staleReplyIsDiscardedAndReResolved() async throws {
    let net = Network(base: lan)
    let result = try await StreamReresolution.fetchThroughCurrentBase(
      currentBase: { net.base },
      fetch: { () async throws -> String in
        net.fetches += 1
        let through = net.base.absoluteString  // the stream URL is built from this address
        if net.fetches == 1 { net.base = wan }  // the app leaves home mid-request
        return through
      },
      discard: { net.discarded.append($0) })

    #expect(result.info == wan.absoluteString, "the stream used came through the current address")
    #expect(result.base == wan)
    #expect(net.discarded == [lan.absoluteString], "the stale reply's session is released")
    #expect(net.fetches == 2)
  }

  /// AC 2: no switch, one request, used as before.
  @Test func currentReplyIsUsedAsBefore() async throws {
    let net = Network(base: lan)
    let result = try await StreamReresolution.fetchThroughCurrentBase(
      currentBase: { net.base },
      fetch: { () async throws -> String in net.fetches += 1; return net.base.absoluteString },
      discard: { net.discarded.append($0) })

    #expect(result.info == lan.absoluteString)
    #expect(result.base == lan)
    #expect(net.fetches == 1)
    #expect(net.discarded.isEmpty)
  }

  /// An address that flips on every request cannot loop forever. The last reply is used; its
  /// resolvedThrough is then stale, so the next reconnect rebuilds it (StreamReresolution.isNeeded).
  @Test func flappingAddressIsBounded() async throws {
    let net = Network(base: lan)
    let result = try await StreamReresolution.fetchThroughCurrentBase(
      currentBase: { net.base },
      fetch: { () async throws -> String in
        net.fetches += 1
        let through = net.base.absoluteString
        net.base = net.base == lan ? wan : lan
        return through
      },
      discard: { net.discarded.append($0) })

    #expect(net.fetches == 3)
    #expect(net.discarded.count == 2)
    #expect(result.base.absoluteString == result.info, "base and reply stay paired")
  }

  /// Both playback requests in the player go through the guard. Red if: a second direct
  /// direct `api.playback(id:` call anywhere in the app bypasses it (the player, its reconnect
  /// retry, a download and a download restart all had one).
  @Test func everyPlaybackRequestIsGuarded() throws {
    let appRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("DSM Video")
    var direct: [String] = []
    var guarded = 0
    let files = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)
    while let file = files?.nextObject() as? URL {
      guard file.pathExtension == "swift" else { continue }
      let source = try String(contentsOf: file, encoding: .utf8)
      let calls = source.components(separatedBy: ".playback(id:").count - 1
      if calls > 0 { direct += Array(repeating: file.lastPathComponent, count: calls) }
      guarded += source.components(separatedBy: ".playbackThroughCurrentAddress(").count - 1
    }
    #expect(direct == ["ItemDetailView.swift"], "only playbackThroughCurrentAddress asks directly")
    #expect(guarded == 4, "player, reconnect retry, download, download restart")
  }
}
