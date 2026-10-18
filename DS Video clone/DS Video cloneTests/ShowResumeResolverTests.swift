import Testing
import Foundation
@testable import DSM_Video

// MARK: - TASK-1060 · the show page's Resume/Play target (FRD-001 FR-011, FR-016)
//
// ShowResumeResolver is the one home for "which episode does the Resume/Play button open", shared
// by the iOS and tvOS show pages. These drive it through the real APIClient against a URLProtocol
// stub (and through demo mode). Expected values are literals from the FRD: the latest in-progress
// episode resumes itself; otherwise the first unwatched episode after the last finished one; with
// everything watched or nothing started, the first episode of the first season as Play.

/// A server for `resume.stub.test` only: other hosts fall through to the network.
nonisolated final class ResumeStubServer: URLProtocol, @unchecked Sendable {
  static let host = "resume.stub.test"
  private static let lock = NSLock()
  /// season number -> (status, JSON body)
  nonisolated(unsafe) private static var seasons: [Int: (Int, String)] = [:]
  nonisolated(unsafe) private static var seasonsRequested: [Int] = []
  static let registered: Bool = {
    URLProtocol.registerClass(ResumeStubServer.self)
    return true
  }()

  static func reset(_ newSeasons: [Int: (Int, String)]) {
    _ = registered
    lock.lock(); defer { lock.unlock() }
    seasons = newSeasons
    seasonsRequested = []
  }
  static var requested: [Int] {
    lock.lock(); defer { lock.unlock() }
    return seasonsRequested
  }

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let season = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "season" })?.value.flatMap(Int.init) ?? -1
    Self.lock.lock()
    Self.seasonsRequested.append(season)
    let reply = Self.seasons[season] ?? (404, #"{"error":"not_found"}"#)
    Self.lock.unlock()
    let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Suite("ShowResumeResolver", .serialized)
@MainActor
struct ShowResumeResolverTests {
  private let show = TVShow(id: "show-1", title: "Stub Show", year: 2024, seasonCount: 2,
                            episodeCount: 6, posterImageId: nil, lastWatchedAt: nil, addedAt: nil)
  private let library = Library(id: "lib-1", title: "Shows", kind: "tv")

  // 22-minute episodes: 1320 s.
  private enum Watch { case done, half, unseen }

  private func season(_ n: Int, _ watch: [Watch]) -> (Int, (Int, String)) {
    let items = watch.enumerated().map { i, w -> ItemSummary in
      let progress: ItemProgress?
      switch w {
      case .done: progress = ItemProgress(positionSeconds: 1320, durationSeconds: 1320, updatedAt: "2026-10-01T09:00:00Z")
      case .half: progress = ItemProgress(positionSeconds: 660, durationSeconds: 1320, updatedAt: "2026-10-02T09:00:00Z")
      case .unseen: progress = nil
      }
      return ItemSummary(id: "s\(n)e\(i + 1)", type: "episode", title: "Episode \(i + 1)",
                         durationSeconds: 1320, addedAt: "2026-01-01T00:00:00Z", progress: progress,
                         showName: "Stub Show", seasonNumber: n, episodeNumber: i + 1)
    }
    let data = (try? JSONEncoder().encode(ItemsResponseBody(items: items))) ?? Data()
    return (n, (200, String(decoding: data, as: UTF8.self)))
  }

  private struct ItemsResponseBody: Encodable { let items: [ItemSummary] }

  private func failing(_ n: Int) -> (Int, (Int, String)) { (n, (500, #"{"error":"boom"}"#)) }

  private func resolve(_ routes: [(Int, (Int, String))], seasonCount: Int) async -> ShowResumeTarget? {
    ResumeStubServer.reset(Dictionary(uniqueKeysWithValues: routes))
    let seasons = (1...seasonCount).map { TVSeason(seasonNumber: $0, episodeCount: 3) }
    var result: ShowResumeTarget?
    await withIsolatedAppState(stubHost: ResumeStubServer.host) { state in
      result = await ShowResumeResolver.resolve(show: show, library: library, seasons: seasons, appState: state)
    }
    return result
  }

  @Test func anInProgressEpisodeResumesThatEpisode() async {
    let target = await resolve([season(1, [.done, .half, .unseen])], seasonCount: 1)

    #expect(target?.isResume == true)
    #expect(target?.index == 1)
    #expect(target?.id == "s1e2")
    #expect(target?.label == "Resume S1·E2")
  }

  @Test func withNoneInProgressTheNextUnwatchedEpisodePlays() async {
    let target = await resolve([season(1, [.done, .done, .unseen, .unseen])], seasonCount: 1)

    #expect(target?.isResume == false)
    #expect(target?.index == 2)
    #expect(target?.label == "Play S1·E3")
  }

  /// The branch the tvOS copy lacked: a fully watched show resolved no target, so the page
  /// offered nothing to play. It offers S1·E1.
  @Test func everythingWatchedFallsBackToSeasonOneEpisodeOne() async {
    let target = await resolve([season(1, [.done, .done]), season(2, [.done, .done])], seasonCount: 2)

    #expect(target?.isResume == false)
    #expect(target?.seasonNumber == 1)
    #expect(target?.seasonIndex == 0)
    #expect(target?.index == 0)
    #expect(target?.label == "Play S1·E1")
  }

  @Test func nothingStartedPlaysSeasonOneEpisodeOne() async {
    let target = await resolve([season(1, [.unseen, .unseen, .unseen])], seasonCount: 1)

    #expect(target?.isResume == false)
    #expect(target?.index == 0)
    #expect(target?.label == "Play S1·E1")
  }

  /// A season whose fetch fails is skipped for the pick (it does not abort the scan).
  @Test func aSeasonThatFailsToLoadIsSkipped() async {
    let target = await resolve([failing(1), season(2, [.unseen, .half])], seasonCount: 2)

    #expect(target?.isResume == true)
    #expect(target?.seasonNumber == 2)
    #expect(target?.seasonIndex == 1)
    #expect(target?.label == "Resume S2·E2")
  }

  /// TASK-654: the scan stops at the first season holding an in-progress episode.
  @Test func theScanStopsAtTheFirstSeasonWithAnInProgressEpisode() async {
    _ = await resolve([season(1, [.done, .half]), season(2, [.unseen])], seasonCount: 2)

    #expect(ResumeStubServer.requested == [1])
  }

  /// TASK-654: at most five seasons are scanned.
  @Test func theScanIsCappedAtFiveSeasons() async {
    let routes = (1...7).map { season($0, [.done]) }
    let target = await resolve(routes, seasonCount: 7)

    #expect(ResumeStubServer.requested == [1, 2, 3, 4, 5])
    #expect(target?.label == "Play S1·E1")
  }

  @Test func noSeasonsResolvesNothing() async {
    var result: ShowResumeTarget?
    await withIsolatedAppState(stubHost: ResumeStubServer.host) { state in
      result = await ShowResumeResolver.resolve(show: show, library: library, seasons: [], appState: state)
    }

    #expect(result == nil)
  }

  // MARK: Demo mode (tvOS had no resume point in demo mode before TASK-1060)

  /// Demo "Meridian Cross" has episode 1 at 1404 of 3120 s (45%): it resumes.
  @Test func demoModeResumesTheDemoShowsInProgressEpisode() async {
    var result: ShowResumeTarget?
    await withIsolatedAppState { state in
      state.sessionToken = "demo"
      let demoShow = DemoData.tvShows[1]
      result = await ShowResumeResolver.resolve(show: demoShow, library: library,
                                                seasons: DemoData.seasons(for: demoShow.id), appState: state)
    }

    #expect(result?.isResume == true)
    #expect(result?.id == "dx-1")
    #expect(result?.label == "Resume S1·E1")
  }

  /// Demo "The Signal" has no progress anywhere: Play S1·E1.
  @Test func demoModeWithNothingStartedPlaysSeasonOneEpisodeOne() async {
    var result: ShowResumeTarget?
    await withIsolatedAppState { state in
      state.sessionToken = "demo"
      let demoShow = DemoData.tvShows[0]
      result = await ShowResumeResolver.resolve(show: demoShow, library: library,
                                                seasons: DemoData.seasons(for: demoShow.id), appState: state)
    }

    #expect(result?.isResume == false)
    #expect(result?.id == "dt-1")
    #expect(result?.label == "Play S1·E1")
  }
}
