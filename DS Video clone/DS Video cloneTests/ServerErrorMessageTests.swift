import Testing
import Foundation
@testable import DSM_Video

// TASK-1040: two server codes had no copy of their own, so they fell to the readable-identifier
// default and the user read "Server error." and "Quickconnect resolve failed." Neither names a
// cause or says what to do. The pass criteria come from the bug report (those two sentences are
// what the user saw), not from the new copy.

@Suite("Server error messages name a cause and an action (TASK-1040)")
struct ServerErrorMessageTests {
  /// OC: AC-1 · `server_error` (500) is what the profile endpoints return when the server
  /// itself fails to generate an ID or hash a PIN before anything is written.
  /// Red if: it still reads "Server error." (the default), or it doesn't say nothing was saved,
  /// or it doesn't point the user at a next step.
  @Test func serverErrorNamesTheFailureAndSaysNothingWasSaved() {
    let message = APIError.server("server_error", status: 500).userMessage
    #expect(message != "Server error.", "the code has copy of its own")
    #expect(message.localizedCaseInsensitiveContains("nothing was saved"), "says what happened to the change: \(message)")
    #expect(message.localizedCaseInsensitiveContains("try again"), "gives the user a next step: \(message)")
    #expect(message.localizedCaseInsensitiveContains("logs"), "points at where the cause is recorded: \(message)")
    #expect(!message.contains("_"))
  }

  /// OC: AC-2 · `quickconnect_resolve_failed` (502) means the NAS could not get an answer from
  /// QuickConnect's lookup service.
  /// Red if: it still reads "Quickconnect resolve failed." (the default), or it blames the ID
  /// the user typed, or it offers no way forward.
  @Test func quickConnectResolveFailureBlamesTheLookupNotTheId() {
    let message = APIError.server("quickconnect_resolve_failed", status: 502).userMessage
    #expect(message != "Quickconnect resolve failed.", "the code has copy of its own")
    #expect(message.contains("QuickConnect"), "names QuickConnect, in its product spelling: \(message)")
    #expect(message.localizedCaseInsensitiveContains("internet"), "names the NAS's connection as the thing to check: \(message)")
    #expect(message.localizedCaseInsensitiveContains("address"), "offers signing in by address: \(message)")
    #expect(!message.localizedCaseInsensitiveContains("not found"), "an unreachable lookup is not an unknown ID: \(message)")
    #expect(!message.contains("_"))
  }

  /// OC: AC-3 · the two neighbouring codes on the same paths read as instructions too.
  /// Red if: either falls to the humanized default ("Missing quickconnect id." / "Invalid avatar.").
  @Test func neighbouringCodesOnTheSamePathsAreNotRawDefaults() {
    let missing = APIError.server("missing_quickconnect_id", status: 400).userMessage
    #expect(missing != "Missing quickconnect id.")
    #expect(missing.contains("QuickConnect"), "\(missing)")
    let avatar = APIError.server("invalid_avatar", status: 400).userMessage
    #expect(avatar != "Invalid avatar.")
    #expect(avatar.localizedCaseInsensitiveContains("picture"), "\(avatar)")
  }

  /// OC: AC-4 · none of these is a session problem: a 500/502/400 never signs the user out.
  @Test func noneOfTheseEndsTheSession() {
    for (code, status) in [("server_error", 500), ("quickconnect_resolve_failed", 502),
                           ("missing_quickconnect_id", 400), ("invalid_avatar", 400)] {
      #expect(!APIError.server(code, status: status).isAuthFailure, "\(code) must not end the session")
    }
  }
}
