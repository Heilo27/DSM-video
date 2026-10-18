import CoreGraphics
import Foundation
import Testing
@testable import DSM_Video

// MARK: - FR-149 · suggest a server update when the connected server is older than the app recommends
//
// Four layers, each red when its own rule breaks: the version comparator, the decide-to-show
// policy, the remembered dismissal (and AppState's use of it), and the check that
// `RecommendedServer.version` equals the version the repo's server package ships.
// Expected values are literals from the spec, never recomputed from production code.

@Suite("SPKVersion comparator (FR-149)")
struct SPKVersionTests {
  private func v(_ raw: String) -> SPKVersion? { SPKVersion(raw) }

  /// Red if: the build suffix is ignored, or the fields are compared as text ("0.3.10" < "0.3.9").
  @Test func ordersByNumberNotByText() throws {
    let a = try #require(v("0.3.9-0001"))
    let b = try #require(v("0.3.9-0002"))
    let c = try #require(v("0.3.10-0001"))
    let d = try #require(v("0.4.0-0001"))
    let e = try #require(v("1.0.0-0001"))
    #expect(a < b)
    #expect(b < c, "patch 10 is newer than patch 9 even though \"10\" sorts before \"9\" as text")
    #expect(c < d)
    #expect(d < e)
    #expect(!(b < a))
    #expect(!(b < b))
    #expect(try #require(v("0.3.9-2")) == b, "leading zeros in the build do not change its value")
  }

  /// Red if: a dev or malformed version parses (it would then compare as old, or as 0, and nag).
  @Test(arguments: [
    "dev", "", "   ", "0.3.9", "0.3.9-", "-0001", "0.3-0001", "0.3.9.1-0001", "0.3.9-0001-1",
    "a.b.c-d", "0.3.9-00x1", "v0.3.9-0001", "0.3.-9-0001", "+1.3.9-0001", "0.3.9-+1", "0..9-0001",
  ])
  func rejectsAnythingThatIsNotMajorMinorPatchBuild(raw: String) {
    #expect(SPKVersion(raw) == nil, "\"\(raw)\" must not parse")
  }

  @Test func missingIsNil() {
    #expect(SPKVersion(nil) == nil)
  }

  @Test func ignoresSurroundingWhitespace() {
    #expect(SPKVersion(" 0.3.9-0002\n") == SPKVersion("0.3.9-0002"))
  }
}

@Suite("ServerUpdatePolicy decides when to show (FR-149)")
struct ServerUpdatePolicyTests {
  private let recommended = "0.3.9-0002"

  private func notice(_ server: String?, dismissedFor: String? = nil) -> ServerUpdateNotice? {
    ServerUpdatePolicy.notice(serverVersion: server, recommended: recommended, dismissedFor: dismissedFor)
  }

  /// Red if: an older server stops getting the notice, or it names the wrong versions.
  @Test func olderServerGetsTheNotice() {
    let shown = notice("0.3.9-0001")
    #expect(shown == ServerUpdateNotice(serverVersion: "0.3.9-0001", recommendedVersion: recommended))
    #expect(notice("0.2.0-0009") != nil)
    #expect(notice("0.3.8-0099") != nil)
  }

  /// Red if: the comparison is not strict (equal nags) or runs the wrong way (newer nags).
  @Test func equalOrNewerServerGetsNothing() {
    #expect(notice("0.3.9-0002") == nil, "equal")
    #expect(notice("0.3.9-0003") == nil, "newer build")
    #expect(notice("0.3.10-0001") == nil, "newer patch")
    #expect(notice("1.0.0-0001") == nil, "newer major")
  }

  /// Red if: a dev build or an unreadable version is treated as old.
  @Test(arguments: ["dev", "", "garbage", "0.3.9"])
  func unreadableVersionGetsNothing(server: String) {
    #expect(notice(server) == nil)
  }

  @Test func missingVersionGetsNothing() {
    #expect(notice(nil) == nil)
  }

  /// Red if: a dismissal for this recommendation does not hide the notice.
  @Test func dismissedForThisRecommendationStaysHidden() {
    #expect(notice("0.3.9-0001", dismissedFor: recommended) == nil)
  }

  /// Red if: a dismissal for an older recommendation keeps hiding a newer one.
  @Test func dismissedForAnOlderRecommendationComesBack() {
    #expect(notice("0.3.9-0001", dismissedFor: "0.3.9-0001") != nil)
    #expect(notice("0.3.9-0001", dismissedFor: "0.3.8-0001") != nil)
  }

  /// Red if: the copy stops naming both versions, the address, or the Package Center steps.
  @Test func theNoticeNamesBothVersionsAndTheSteps() throws {
    let shown = try #require(notice("0.3.8-0001"))
    #expect(shown.message.contains("0.3.8-0001"))
    #expect(shown.message.contains(recommended))
    let steps = shown.steps.joined(separator: " ")
    #expect(steps.contains("heiloprojects.com/dsmvideo"))
    #expect(steps.contains("Package Center"))
    #expect(steps.contains("Manual Install"))
  }
}

@Suite("Server update notice in the app (FR-149)", .serialized)
@MainActor
struct ServerUpdateAppStateTests {
  private func versionJSON(_ v: String) -> String {
    #"{"serverVersion":"\#(v)","minClientVersion":"1.0.0","capabilities":[]}"#
  }

  /// Red if: AppState does not apply the policy, or "Not Now" is not remembered for the
  /// recommended version.
  @Test func dismissIsRememberedPerRecommendedVersion() async {
    await withIsolatedAppState { state in
      state.evaluateServerVersion("0.3.9-0001")
      #expect(state.serverUpdateNotice?.recommendedVersion == RecommendedServer.version)

      state.dismissServerUpdateNotice()
      #expect(state.serverUpdateNotice == nil)
      #expect(state.serverUpdateDismissal.dismissedFor == RecommendedServer.version)

      state.evaluateServerVersion("0.3.9-0001")
      #expect(state.serverUpdateNotice == nil, "dismissed for this recommendation")

      // The app now recommends something newer than what was dismissed.
      let next = ServerUpdatePolicy.notice(
        serverVersion: "0.3.9-0001", recommended: "99.0.0-0001",
        dismissedFor: state.serverUpdateDismissal.dismissedFor)
      #expect(next?.recommendedVersion == "99.0.0-0001")
    }
  }

  /// Red if: the dismissal is kept in memory only (a relaunch would nag again).
  @Test func dismissalSurvivesAFreshReader() {
    let suite = "ServerUpdate.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      Issue.record("no throwaway defaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ServerUpdateDismissal(defaults: defaults).dismissedFor == nil)
    ServerUpdateDismissal(defaults: defaults).dismiss(recommendedVersion: "0.3.9-0002")
    #expect(ServerUpdateDismissal(defaults: defaults).dismissedFor == "0.3.9-0002")
  }

  /// Red if: the check does not read /api/v1/version, or does not raise the notice from it.
  @Test func checkReadsTheServerVersionAndRaisesTheNotice() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/version": .json(200, versionJSON("0.3.9-0001"))])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        await state.checkServerVersion()
        #expect(ProfileStubServer.count("GET /api/v1/version") == 1)
        #expect(state.serverUpdateNotice?.serverVersion == "0.3.9-0001")
        state.sessionToken = nil
      }
    }
  }

  /// Red if: a current server still gets the notice.
  @Test func checkAgainstACurrentServerShowsNothing() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/version": .json(200, versionJSON(RecommendedServer.version))])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        await state.checkServerVersion()
        #expect(ProfileStubServer.count("GET /api/v1/version") == 1)
        #expect(state.serverUpdateNotice == nil)
        state.sessionToken = nil
      }
    }
  }

  /// Red if: a dev server (BuildVersion "dev") is told to update.
  @Test func checkAgainstADevServerShowsNothing() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/version": .json(200, versionJSON("dev"))])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        await state.checkServerVersion()
        #expect(ProfileStubServer.count("GET /api/v1/version") == 1)
        #expect(state.serverUpdateNotice == nil)
        state.sessionToken = nil
      }
    }
  }

  /// Red if: the check asks the server while it is unreachable or the device is offline.
  @Test func checkWhileOfflineOrUnreachableDoesNotAsk() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/version": .json(200, versionJSON("0.3.9-0001"))])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        state.isOffline = true
        await state.checkServerVersion()
        state.isOffline = false
        state.serverUnreachable = true
        await state.checkServerVersion()
        #expect(ProfileStubServer.count("GET /api/v1/version") == 0)
        #expect(state.serverUpdateNotice == nil)
        state.serverUnreachable = false
        state.sessionToken = nil
      }
    }
  }

  /// Red if: demo mode asks a server that does not exist.
  @Test func checkInDemoModeDoesNotAsk() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/version": .json(200, versionJSON("0.3.9-0001"))])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        state.sessionToken = "demo"
        await state.checkServerVersion()
        #expect(ProfileStubServer.count("GET /api/v1/version") == 0)
        #expect(state.serverUpdateNotice == nil)
        state.sessionToken = nil
      }
    }
  }

  /// Red if: a failed read changes the notice (it says nothing about the server's version).
  @Test func aFailedReadLeavesTheNoticeAlone() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/version": .json(500, #"{"error":"internal"}"#)])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        state.evaluateServerVersion("0.3.9-0001")
        let before = state.serverUpdateNotice
        #expect(before != nil)
        await state.checkServerVersion()
        #expect(ProfileStubServer.count("GET /api/v1/version") == 1)
        #expect(state.serverUpdateNotice == before)
        state.sessionToken = nil
      }
    }
  }

  /// Red if: signing in (which lands on homeLoad) stops reading the server's version.
  @Test func loadingHomeAfterSignInChecksTheServerVersion() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/version": .json(200, versionJSON("0.3.9-0001"))])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        await state.homeLoad()
        for _ in 0..<300 where state.serverUpdateNotice == nil {
          try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.serverUpdateNotice?.serverVersion == "0.3.9-0001")
        state.reconnectRetryTask?.cancel()
        state.sessionToken = nil
      }
    }
  }

  /// Red if: coming back to the foreground stops re-reading the server's version (a server updated
  /// or downgraded while the app was away would keep showing the old answer). The foreground pass
  /// probes /version itself for reachability, which never sets the notice, so the notice appearing
  /// proves the check ran.
  @Test func returningToTheForegroundChecksTheServerVersion() async {
    await ProfileStateGate.shared.run {
      ProfileStubServer.reset(["GET /api/v1/version": .json(200, versionJSON("0.3.9-0001"))])
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        await state.foregroundReconnectAndRefresh()
        for _ in 0..<300 where state.serverUpdateNotice == nil {
          try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.serverUpdateNotice?.serverVersion == "0.3.9-0001")
        state.reconnectRetryTask?.cancel()
        state.sessionToken = nil
      }
    }
  }

  /// Red if: the notice about one server outlives signing out of it.
  @Test func signingOutClearsTheNotice() async {
    await withIsolatedAppState { state in
      state.evaluateServerVersion("0.3.9-0001")
      #expect(state.serverUpdateNotice != nil)
      state.logout()
      #expect(state.serverUpdateNotice == nil)
    }
  }
}

@Suite("Recommended server version matches the shipped package (FR-149)")
struct RecommendedServerSyncTests {
  /// The repo root, found from this file's compile-time path:
  /// <root>/DS Video clone/DS Video cloneTests/<this file>.
  private static func repoRoot(_ file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  /// Red if: someone raises `version` in spk/DSVideoServer/INFO (a new server release) without
  /// raising `RecommendedServer.version`, or the reverse. This is the release gate for FR-149.
  @Test func recommendedVersionEqualsTheVersionInTheServerPackageINFO() throws {
    let info = Self.repoRoot().appendingPathComponent("spk/DSVideoServer/INFO")
    let text = try String(contentsOf: info, encoding: .utf8)
    let line = try #require(
      text.split(separator: "\n").first { $0.hasPrefix("version=") },
      "no version= line in \(info.path)")
    let shipped = line.dropFirst("version=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" \r"))
    #expect(SPKVersion(shipped) != nil, "INFO version \"\(shipped)\" is not MAJOR.MINOR.PATCH-BUILD")
    #expect(RecommendedServer.version == shipped,
            "RecommendedServer.version is \(RecommendedServer.version) but spk/DSVideoServer/INFO ships \(shipped); raise it with the release")
  }

  @Test func recommendedVersionIsReadable() {
    #expect(SPKVersion(RecommendedServer.version) != nil)
  }

  @Test func theDownloadPageIsTheProductPageNotARelease() {
    #expect(RecommendedServer.downloadURL.absoluteString == "https://heiloprojects.com/dsmvideo/")
    #expect(RecommendedServer.downloadURL.absoluteString.contains(RecommendedServer.displayURL))
  }
}

@Suite("On-device QR code (FR-149)")
struct QRCodeTests {
  /// Red if: the generator returns nothing, or an image that is not a usable square.
  @Test func rendersASquareBitmap() throws {
    let image = try #require(QRCode.image(for: RecommendedServer.downloadURL.absoluteString))
    #expect(image.width == image.height)
    #expect(image.width >= 100)
  }

  /// Red if: the code ignores its message.
  @Test func differentMessagesGiveDifferentCodes() throws {
    func pixels(_ s: String) throws -> Data {
      let image = try #require(QRCode.image(for: s, side: 200))
      let provider = try #require(image.dataProvider)
      return try #require(provider.data) as Data
    }
    #expect(try pixels("https://heiloprojects.com/dsmvideo/") != pixels("https://example.com/other/"))
  }
}
