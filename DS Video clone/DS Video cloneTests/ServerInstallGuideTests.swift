import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-748 · FR-152 · guided server install and the first-connection moment
//
// The install-link decision, the honest "answered but not DSVideo Server" message, and the
// once-per-server memory behind "Found N libraries, M videos". The 404 test drives the real
// login() against a URLProtocol stub that answers a bodyless 404, which is what a DSM host with
// no DSVideo Server installed does.

@Suite("FR-152 install link decision")
struct InstallLinkPolicyTests {

  @Test func offeredWhenNothingAnswered() {
    #expect(InstallLinkPolicy.shouldOffer(lastError: APIError.network))
    #expect(InstallLinkPolicy.shouldOffer(lastError: APIError.connection(.timedOut)))
    #expect(InstallLinkPolicy.shouldOffer(lastError: APIError.connection(.cannotConnectToHost)))
    #expect(InstallLinkPolicy.shouldOffer(lastError: URLError(.cannotFindHost)))
  }

  @Test func offeredWhenAHostAnswersButIsNotDSVideo() {
    #expect(InstallLinkPolicy.shouldOffer(lastError: APIError.http(404)))
  }

  @Test func neverOfferedWhenADSVideoServerAnswered() {
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.http(401)))
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.http(403)))
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.http(500)))
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.server("invalid_credentials", status: 401, detail: nil)))
  }

  @Test func neverOfferedForLocalNetworkDenialOrQuickConnectLookupFailure() {
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.localNetworkDenied))
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.network, localNetworkRefused: true))
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.network, quickConnectLookupFailed: true))
  }

  @Test func neverOfferedForTransportSecurityFailures() {
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.connection(.secureConnectionFailed)))
    #expect(!InstallLinkPolicy.shouldOffer(lastError: APIError.connection(.serverCertificateUntrusted)))
    #expect(!InstallLinkPolicy.shouldOffer(lastError: URLError(.appTransportSecurityRequiresSecureConnection)))
  }

  @Test func neverOfferedWithoutAnError() {
    #expect(!InstallLinkPolicy.shouldOffer(lastError: nil))
  }

  @Test func theLinkIsTheRecommendedServerDownloadPage() {
    #expect(ServerInstallGuide.steps.first?.detail.contains(RecommendedServer.displayURL) == true)
    #expect(!ServerInstallGuide.steps.contains { $0.detail.contains("github.com") })
    #expect(ServerInstallGuide.steps.count == 4)
  }

  @MainActor @Test func notDSVideoMessageDoesNotTriggerTheGenericPrettifier() {
    // ServerSetupView.friendlyError rewrites strings holding these phrases into a vaguer cause.
    let lower = ServerInstallGuide.notDSVideoMessage.lowercased()
    for phrase in ["couldn't find", "refused", "timed out"] {
      #expect(!lower.contains(phrase), "message contains \"\(phrase)\"")
    }
    #expect(AppState.pairingErrorMessage(APIError.http(404)) == ServerInstallGuide.notDSVideoMessage)
  }
}

@Suite("FR-152 sign-in against a host that is not DSVideo Server", .serialized)
@MainActor
struct NotDSVideoLoginTests {

  private func signIn(route: (Int, String)) async -> (error: String?, offersInstall: Bool) {
    var result: (String?, Bool) = (nil, false)
    await ProfileStateGate.shared.run {
      await withIsolatedAppState { state in
        let saved = SavedAddresses(state)
        ClientContractStub.reset(["POST /api/v1/auth/login": route])
        state.rememberMe = false
        state.useHTTPS = false
        state.lanAddress = ""
        state.wanAddress = ""
        state.lastGoodAddress = ""
        state.quickConnectID = ""
        state.baseURL = ClientContractStub.host
        state.username = "someone"
        state.setPassword("secret")
        await state.login()
        result = (state.loginError, state.loginErrorOffersInstall)
        state.sessionToken = nil
        saved.restore(state)
        ClientContractStub.reset()
      }
    }
    return result
  }

  @Test func bodylessNotFoundSaysSomethingAnsweredAndOffersInstall() async {
    let outcome = await signIn(route: (404, ""))
    #expect(outcome.error == ServerInstallGuide.notDSVideoMessage, "shown: \(outcome.error ?? "nil")")
    #expect(outcome.offersInstall)
  }

  @Test func wrongPasswordNeverOffersInstall() async {
    let outcome = await signIn(route: (401, #"{"error":"invalid_credentials"}"#))
    #expect(outcome.error != nil)
    #expect(outcome.error != ServerInstallGuide.notDSVideoMessage)
    #expect(!outcome.offersInstall)
  }
}

@Suite("FR-152 first connection moment")
struct FirstConnectionRecordTests {

  private func record() -> (FirstConnectionRecord, () -> Void) {
    let suite = "FirstConnectionRecordTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    return (FirstConnectionRecord(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
  }

  @Test func aServerIsWelcomedOnceAndOnlyOnce() {
    let (record, cleanup) = record()
    defer { cleanup() }
    let key = FirstConnectionRecord.serverKey(quickConnectID: nil, baseURL: "192.168.1.20:8097") ?? ""
    #expect(!key.isEmpty)
    #expect(!record.hasWelcomed(key))
    record.markWelcomed(key)
    #expect(record.hasWelcomed(key))
    record.markWelcomed(key)
    #expect(record.defaults.stringArray(forKey: FirstConnectionRecord.defaultsKey)?.count == 1)
  }

  @Test func aSecondServerIsStillNew() {
    let (record, cleanup) = record()
    defer { cleanup() }
    let first = FirstConnectionRecord.serverKey(quickConnectID: nil, baseURL: "192.168.1.20")!
    let second = FirstConnectionRecord.serverKey(quickConnectID: nil, baseURL: "192.168.1.21")!
    record.markWelcomed(first)
    #expect(first != second)
    #expect(!record.hasWelcomed(second))
  }

  @Test func quickConnectIDIdentifiesTheServerAcrossAddresses() {
    let home = FirstConnectionRecord.serverKey(quickConnectID: "My-NAS", baseURL: "192.168.1.20")
    let away = FirstConnectionRecord.serverKey(quickConnectID: " my-nas ", baseURL: "203.0.113.9:5000")
    #expect(home == away)
  }

  @Test func addressFormsOfOneHostShareAKey() {
    let a = FirstConnectionRecord.serverKey(quickConnectID: nil, baseURL: "http://Nas.local:8097")
    let b = FirstConnectionRecord.serverKey(quickConnectID: "", baseURL: "nas.local:8097")
    #expect(a == b)
  }

  @Test func noAddressMeansNoKey() {
    #expect(FirstConnectionRecord.serverKey(quickConnectID: nil, baseURL: "  ") == nil)
  }

  @Test func messageCountsLibrariesAndVideos() {
    let us = Locale(identifier: "en_US")
    #expect(FirstConnectionRecord.message(libraries: 2, videos: 1204, locale: us) == "Found 2 libraries, 1,204 videos")
    #expect(FirstConnectionRecord.message(libraries: 1, videos: 1, locale: us) == "Found 1 library, 1 video")
  }

  @Test func nothingFoundShowsNoMessage() {
    #expect(FirstConnectionRecord.message(libraries: 0, videos: 0) == nil)
  }
}
