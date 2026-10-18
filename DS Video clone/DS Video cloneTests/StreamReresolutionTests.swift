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

// TASK-991 gap: the player can fail BEFORE the app notices the address change. The failure
// itself now starts the re-resolve (StreamRecovery), so the error screen no longer waits for
// the next reconnect signal. These cover the ordering and single-flight rules of that gate;
// the reconnect probe itself is AppState.reconnect(), exercised on a device walk-out.

@MainActor
@Suite("Stream recovery when playback fails on the network (TASK-991)")
struct StreamRecoveryTests {
  private final class Runs {
    var triggers: [StreamRecovery.Trigger] = []
    var sawCancellation = false
    var gaveUp = 0
    var nestedStarts: [Bool] = []
  }

  private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
  private let lostConnection = "Lost connection to the server. Check that your NAS is reachable, then try again."

  @Test("a network failure before any reconnect signal starts the re-resolve at once")
  func failureFirstStartsRecovery() async {
    let recovery = StreamRecovery()
    let runs = Runs()
    let started = recovery.begin(.playbackFailed(onNetwork: true), isNeeded: true, now: t0) {
      runs.triggers.append($0)
    }
    #expect(started)
    #expect(recovery.isRecovering)
    await recovery.task?.value
    #expect(runs.triggers == [.playbackFailed(onNetwork: true)])
    #expect(!recovery.isRecovering)
  }

  @Test("failure and reachability arriving together re-resolve once, in either order")
  func failureAndReachabilityTogetherRunOnce() async {
    let failureFirst = StreamRecovery()
    let runsA = Runs()
    #expect(failureFirst.begin(.playbackFailed(onNetwork: true), isNeeded: true, now: t0) {
      runsA.triggers.append($0)
    })
    #expect(!failureFirst.begin(.networkReturned, isNeeded: true, now: t0) {
      runsA.triggers.append($0)
    })
    await failureFirst.task?.value
    #expect(runsA.triggers == [.playbackFailed(onNetwork: true)])

    let reachabilityFirst = StreamRecovery()
    let runsB = Runs()
    #expect(reachabilityFirst.begin(.networkReturned, isNeeded: true, now: t0) {
      runsB.triggers.append($0)
    })
    #expect(!reachabilityFirst.begin(.playbackFailed(onNetwork: true), isNeeded: true, now: t0) {
      runsB.triggers.append($0)
    })
    await reachabilityFirst.task?.value
    #expect(runsB.triggers == [.networkReturned])
  }

  @Test("a failure that is not a network failure never re-resolves")
  func nonNetworkFailureDoesNotRecover() {
    let recovery = StreamRecovery()
    let runs = Runs()
    #expect(!recovery.begin(.playbackFailed(onNetwork: false), isNeeded: true, now: t0) {
      runs.triggers.append($0)
    })
    #expect(!recovery.isRecovering)
    #expect(recovery.task == nil)
    #expect(runs.triggers.isEmpty)
  }

  @Test("nothing to re-resolve (a downloaded file, a stream on the current address) starts nothing")
  func notNeededDoesNotRecover() {
    let recovery = StreamRecovery()
    #expect(!recovery.begin(.playbackFailed(onNetwork: true), isNeeded: false, now: t0) { _ in })
    #expect(!recovery.begin(.networkReturned, isNeeded: false, now: t0) { _ in })
    #expect(!recovery.isRecovering)
  }

  @Test("a re-resolve that finds no address shows the real error again, and does not loop")
  func failedRecoveryShowsHonestErrorWithoutLooping() async {
    let recovery = StreamRecovery(failureWindow: 30)
    let runs = Runs()
    // The operation returning without rebuilding is what PlayerSheet does when reconnect()
    // finds no reachable address.
    #expect(recovery.begin(.playbackFailed(onNetwork: true), isNeeded: true, now: t0) {
      runs.triggers.append($0)
    })
    #expect(GestureVideoPlayer.failureScreen(playerError: lostConnection,
                                             reconnecting: recovery.isRecovering) == .reconnecting)
    await recovery.task?.value
    #expect(GestureVideoPlayer.failureScreen(playerError: lostConnection,
                                             reconnecting: recovery.isRecovering)
            == .failed(lostConnection))

    // The same stream failing again straight away does not start another round.
    #expect(!recovery.begin(.playbackFailed(onNetwork: true), isNeeded: true,
                            now: t0.addingTimeInterval(5)) { runs.triggers.append($0) })
    #expect(runs.triggers.count == 1)

    // The network returning is new information and still rebuilds.
    #expect(recovery.begin(.networkReturned, isNeeded: true, now: t0.addingTimeInterval(6)) {
      runs.triggers.append($0)
    })
    await recovery.task?.value
    #expect(runs.triggers == [.playbackFailed(onNetwork: true), .networkReturned])

    // A later, separate drop is recovered again once the window has passed.
    #expect(recovery.begin(.playbackFailed(onNetwork: true), isNeeded: true,
                           now: t0.addingTimeInterval(31)) { runs.triggers.append($0) })
    await recovery.task?.value
    #expect(runs.triggers.count == 3)
  }

  @Test("no failure on screen means no failure screen, reconnecting or not")
  func noErrorNoScreen() {
    #expect(GestureVideoPlayer.failureScreen(playerError: nil, reconnecting: true) == nil)
    #expect(GestureVideoPlayer.failureScreen(playerError: nil, reconnecting: false) == nil)
  }

  @Test("closing the player cancels the re-resolve, and a late finish cannot clobber a new one")
  func cancelStopsRecovery() async {
    let recovery = StreamRecovery()
    let runs = Runs()
    #expect(recovery.begin(.playbackFailed(onNetwork: true), isNeeded: true, now: t0) { _ in
      try? await Task.sleep(for: .seconds(5))
      runs.sawCancellation = Task.isCancelled
    })
    let first = recovery.task
    recovery.cancel()
    #expect(!recovery.isRecovering)
    #expect(recovery.task == nil)

    #expect(recovery.begin(.networkReturned, isNeeded: true, now: t0) { _ in
      try? await Task.sleep(for: .seconds(5))
    })
    await first?.value
    #expect(runs.sawCancellation)
    #expect(recovery.isRecovering, "the cancelled rebuild finishing must not end the new one")
    recovery.cancel()
  }

  @Test("a reconnect that outlasts the overall deadline is cancelled and shows the real error")
  func deadlineEndsRecoveryWithRealError() async {
    let recovery = StreamRecovery(deadline: .milliseconds(50))
    let runs = Runs()
    #expect(recovery.begin(.playbackFailed(onNetwork: true), isNeeded: true, now: t0) { _ in
      // A probe chain far longer than the deadline (the real worst case is ~2 minutes).
      try? await Task.sleep(for: .seconds(5))
      runs.sawCancellation = Task.isCancelled
    } onDeadline: {
      runs.gaveUp += 1
    })
    let rebuild = recovery.task
    let timer = recovery.deadlineTask
    #expect(GestureVideoPlayer.failureScreen(playerError: lostConnection,
                                             reconnecting: recovery.isRecovering) == .reconnecting)
    await timer?.value
    #expect(runs.gaveUp == 1)
    #expect(!recovery.isRecovering)
    #expect(recovery.task == nil)
    #expect(GestureVideoPlayer.failureScreen(playerError: lostConnection,
                                             reconnecting: recovery.isRecovering)
            == .failed(lostConnection))
    await rebuild?.value
    #expect(runs.sawCancellation, "the rebuild must be cancelled at the deadline, not left running")
    #expect(runs.gaveUp == 1)
  }

  @Test("a rebuild that finishes inside the deadline never reports giving up")
  func finishedRecoveryDisarmsDeadline() async {
    let recovery = StreamRecovery(deadline: .milliseconds(50))
    let runs = Runs()
    #expect(recovery.begin(.networkReturned, isNeeded: true, now: t0) {
      runs.triggers.append($0)
    } onDeadline: {
      runs.gaveUp += 1
    })
    let timer = recovery.deadlineTask
    await recovery.task?.value
    await timer?.value
    #expect(runs.triggers == [.networkReturned])
    #expect(runs.gaveUp == 0)
    #expect(recovery.deadlineTask == nil)
  }

  @Test("signals raised by the rebuild itself never start a second, nested one")
  func noNestedRecovery() async {
    let recovery = StreamRecovery()
    let runs = Runs()
    #expect(recovery.begin(.playbackFailed(onNetwork: true), isNeeded: true, now: t0) { trigger in
      runs.triggers.append(trigger)
      // The reload inside a rebuild can post .networkDidReconnect, clear serverUnreachable or
      // fail the new stream on the network. None of them may start a rebuild of its own.
      runs.nestedStarts.append(recovery.begin(.networkReturned, isNeeded: true, now: t0) {
        runs.triggers.append($0)
      })
      runs.nestedStarts.append(recovery.begin(.playbackFailed(onNetwork: true), isNeeded: true,
                                              now: t0.addingTimeInterval(60)) {
        runs.triggers.append($0)
      })
    })
    await recovery.task?.value
    #expect(runs.nestedStarts == [false, false])
    #expect(runs.triggers == [.playbackFailed(onNetwork: true)])
    #expect(!recovery.isRecovering)
  }
}
