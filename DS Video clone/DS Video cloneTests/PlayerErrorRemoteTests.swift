import Foundation
import Testing
@testable import DSM_Video

// TASK-1047. On tvOS the failure screen ("Playback Failed") is drawn over a player that is
// hidden and broken. onPlayPauseCommand called togglePlayPause() unconditionally, so the Siri
// Remote's Play/Pause toggled that hidden player; skip, seek, the lock-screen commands and the
// VoiceOver actions reached it the same way, and Menu first "hid the controls" that were not on
// screen before it would leave.
//
// The decisions are two pure functions on GestureVideoPlayer. The source scan pins that every
// entry point asks them, since a rule nothing calls protects nothing. What the remote does on a
// real Apple TV is a device check.

@Suite("Player remote commands behind the error screen (TASK-1047)")
struct PlayerErrorRemoteTests {

  // MARK: Decisions

  @Test func transportActsOnlyWhenThereIsNoError() {
    #expect(GestureVideoPlayer.transportCommandsEnabled(playerError: nil))
    #expect(!GestureVideoPlayer.transportCommandsEnabled(playerError: "Playback Failed"))
    #expect(!GestureVideoPlayer.transportCommandsEnabled(playerError: ""))
  }

  @Test func menuOnTheErrorScreenIsDismissWhetherOrNotControlsAreShowing() {
    for showing in [true, false] {
      #expect(GestureVideoPlayer.menuAction(playerError: "Lost connection", controlsShowing: showing) == .dismissError)
    }
  }

  @Test func menuWithoutAnErrorBacksOutOneLevelAtATime() {
    #expect(GestureVideoPlayer.menuAction(playerError: nil, controlsShowing: true) == .hideControls)
    #expect(GestureVideoPlayer.menuAction(playerError: nil, controlsShowing: false) == .exitPlayer)
  }

  // MARK: Every entry point asks

  private func playerSource() throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { url.deleteLastPathComponent() }
    url.appendPathComponent("DSM Video/DSM Video/Views/GestureVideoPlayer.swift")
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The text of `private func <name>(` up to the next function declaration.
  private func functionBody(_ name: String, in text: String) throws -> String {
    let start = try #require(text.range(of: "private func \(name)("), "\(name) exists")
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
  }

  private let guardLine = "Self.transportCommandsEnabled(playerError: playerError)"

  @Test func playPauseSkipAndSeekAllStandDownBehindTheError() throws {
    let text = try playerSource()
    for name in ["togglePlayPause", "skipForward", "skipBackward", "seek"] {
      let body = try functionBody(name, in: text)
      let firstStatement = body.split(separator: "\n").first { $0.contains("guard") }.map(String.init) ?? ""
      #expect(firstStatement.contains(guardLine), "\(name) must open with the transport guard")
    }
  }

  @Test func systemTransportCommandsFollowTheSameRule() throws {
    let text = try playerSource()
    let apply = try functionBody("applyRemoteCommandAvailability", in: text)
    #expect(apply.contains(guardLine))
    for command in ["playCommand", "pauseCommand", "togglePlayPauseCommand",
                    "skipForwardCommand", "skipBackwardCommand", "changePlaybackPositionCommand"] {
      #expect(apply.contains("center.\(command).isEnabled = enabled"), "\(command) follows the rule")
    }
    let setup = try functionBody("setupNowPlaying", in: text)
    #expect(setup.contains("applyRemoteCommandAvailability()"), "setup applies the rule, not a blanket true")
    let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let hook = try #require(lines.firstIndex(of: ".onChange(of: playerError) { _, _ in"), "an onChange(of: playerError) hook exists")
    #expect(lines[hook + 1] == "applyRemoteCommandAvailability()", "a failure arriving after setup switches the commands off")
  }

  @Test func menuAsksTheDecisionAndPlayPauseGoesThroughTheGuardedToggle() throws {
    let text = try playerSource()
    #expect(text.contains("Self.menuAction(playerError: playerError, controlsShowing: showControls)"))
    #expect(text.contains(".onPlayPauseCommand { togglePlayPause() }"))
    #expect(text.contains(".accessibilityAction(named: \"Play/Pause\") { togglePlayPause() }"))
  }
}
