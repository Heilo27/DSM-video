import Foundation
import Testing
@testable import DSM_Video

// MARK: - "Nothing found" and "could not ask" are different answers (TASK-967 · OC-1094, OC-1138)
//
// OC-1094: a nonsense search and a search with the NAS unreachable must never read the same.
// OC-1138: tapping Download with the NAS unreachable is refused with the real reason (the
// download starts by asking the server for a playback session; that ask is what fails).
// Every request goes through the real APIClient to ProfileStubServer; expected values are
// literals. The two screens' rendering of these outcomes (the "No Results" panel vs the
// "Search Failed" panel with Retry, and the absence of a download row) is view code and is
// tracked under TASK-1044.

@Suite("OC-1094 / OC-1138 · empty is not unreachable", .serialized)
@MainActor
struct OfflineRefusalTests {

  /// OC-1094 · given a search for a nonsense term the server answers with no matches, when the
  /// search runs, then the outcome is a SUCCESS with zero items (the screen says "No Results");
  /// and given the NAS is unreachable, then the outcome is a FAILURE carrying a connection
  /// sentence (the screen says "Search Failed" with Retry). Never the same state.
  /// Red if: a transport failure is swallowed into an empty result list, or an empty answer is
  /// reported as an error.
  @Test func aSearchWithNoMatchesAndASearchThatCouldNotAskAreDifferentOutcomes() async {
    await ProfileStateGate.shared.run {
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        ProfileStubServer.reset(["GET /api/v1/search": .json(200, #"{"items":[],"total":0}"#)])
        let empty = await SearchRules.fetch("qzxjvk", explicit: true, api: state.api)
        guard case .success(let items)? = empty else {
          Issue.record("no matches must be a success with an empty list, got \(String(describing: empty))")
          return
        }
        #expect(items.isEmpty)

        ProfileStubServer.reset(["GET /api/v1/search": .unreachable])
        let down = await SearchRules.fetch("qzxjvk", explicit: true, api: state.api)
        guard case .failure(let error)? = down else {
          Issue.record("an unreachable NAS must be a failure, got \(String(describing: down))")
          return
        }
        #expect((error as? APIError)?.userMessage == "Couldn't connect to the server. Check the address and port, and that DSVideoServer is running.")

        ProfileStubServer.reset(["GET /api/v1/search": .offline])
        let offline = await SearchRules.fetch("qzxjvk", explicit: true, api: state.api)
        guard case .failure(let offlineError)? = offline else {
          Issue.record("no network must be a failure, got \(String(describing: offline))")
          return
        }
        #expect((offlineError as? APIError)?.userMessage == "No network connection.")
      }
    }
  }

  /// OC-1138 · given the NAS is unreachable (or the phone has no network), when Download is
  /// tapped and the app asks for the playback session, then the ask fails with the real reason
  /// in plain words, and no download of any kind has been started on the server side.
  /// Red if: the transport failure is reported with the generic fallback sentence or someone
  /// else's cause, so the user is told the wrong thing about why nothing downloaded.
  @Test func askingToDownloadWithNoNASIsRefusedWithTheRealReason() async {
    await ProfileStateGate.shared.run {
      await withIsolatedAppState(stubHost: ProfileStubServer.host) { state in
        ProfileStubServer.reset(["GET /api/v1/items/mv-1/playback": .unreachable])
        do {
          _ = try await state.api.playback(id: "mv-1")
          Issue.record("playback must not succeed against an unreachable NAS")
        } catch {
          #expect((error as? APIError)?.userMessage == "Couldn't connect to the server. Check the address and port, and that DSVideoServer is running.")
        }
        #expect(ProfileStubServer.count("GET /api/v1/items/mv-1/playback") == 1)

        ProfileStubServer.reset(["GET /api/v1/items/mv-1/playback": .offline])
        do {
          _ = try await state.api.playback(id: "mv-1")
          Issue.record("playback must not succeed with no network")
        } catch {
          #expect((error as? APIError)?.userMessage == "No network connection.")
        }
      }
    }
  }
}
