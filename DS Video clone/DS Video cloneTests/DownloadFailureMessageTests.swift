import Foundation
import Testing
@testable import DSM_Video

// MARK: - TASK-961 · a refused download is not an expired session
//
// FR-033 (FRD-001): a download failure names the real cause and never blames the user's
// credentials. The stream route answers 403 `content_restricted` for a title above the profile's
// age rating and 403 `unknown_profile` for a deleted profile. Before this fix every 403 read
// "Your session expired", though the user was still signed in and signing in again fixes nothing.
//
// The failure is driven through `recordHTTPFailure`, the method the download delegate calls, on
// a manager that owns its own container. The body is read from a real file by the same function
// the delegate uses.

@Suite("Download failure messages", .serialized)
@MainActor
struct DownloadFailureMessageTests {

  private func makeManager() throws -> (DownloadManager, URL) {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel-dlfail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    return (DownloadManager(containerForTesting: container), container)
  }

  /// Writes `body` the way URLSession leaves a finished transfer on disk, and reads its code back
  /// through the delegate's own reader.
  private func code(fromBody body: String) throws -> String? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dlfail-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(body.utf8).write(to: file)
    return DownloadManager.errorCode(fromErrorBodyAt: file)
  }

  /// OC: TASK-961 AC1 · 403 content_restricted shows the age-rating message.
  /// Red if: every 403 reads "Your session expired".
  @Test func contentRestrictedDownloadNamesTheAgeRating() throws {
    let (manager, container) = try makeManager()
    defer { try? FileManager.default.removeItem(at: container) }
    let code = try code(fromBody: #"{"error":"content_restricted"}"#)
    #expect(code == "content_restricted")

    manager.recordHTTPFailure(itemId: "oc961-r", status: 403, errorCode: code)

    let message = manager.failedDownloads["oc961-r"]?.message
    #expect(message == APIError.server("content_restricted", status: 403).userMessage)
    #expect(message?.contains("session") == false, "\(message ?? "nil")")
  }

  /// OC: TASK-961 AC2 · 403 unknown_profile goes to the profile-gone handling (FR-206).
  /// Red if: no `.activeProfileRejected` is posted, or the row says the session expired.
  @Test func unknownProfileDownloadReturnsToThePicker() async throws {
    let (manager, container) = try makeManager()
    defer { try? FileManager.default.removeItem(at: container) }
    final class Seen: @unchecked Sendable { var ids: [String?] = [] }
    let seen = Seen()
    // queue nil: delivered synchronously on the posting (main) thread.
    let token = NotificationCenter.default.addObserver(
      forName: .activeProfileRejected, object: nil, queue: nil
    ) { note in seen.ids.append(note.object as? String) }
    defer { NotificationCenter.default.removeObserver(token) }

    manager.recordHTTPFailure(itemId: "oc961-p", status: 403, errorCode: "unknown_profile",
                              sentProfileID: "pf_gone")

    #expect(seen.ids == ["pf_gone"])
    let message = manager.failedDownloads["oc961-p"]?.message
    #expect(message == APIError.server("unknown_profile", status: 403).userMessage)
    #expect(message?.contains("session") == false, "\(message ?? "nil")")
  }

  /// OC: TASK-961 AC3 · only a session failure says the session expired.
  @Test func onlyASessionFailureSaysSessionExpired() throws {
    let session = "Your session expired. Sign in again, then retry the download."
    #expect(DownloadManager.httpFailureMessage(status: 401, errorCode: try code(fromBody: #"{"error":"invalid_token"}"#)) == session)
    #expect(DownloadManager.httpFailureMessage(status: 401, errorCode: nil) == session)
    for code in ["content_restricted", "unknown_profile", "profile_restricted", "permission_denied",
                 "path_not_allowed", "forbidden"] {
      #expect(DownloadManager.httpFailureMessage(status: 403, errorCode: code) != session, "403 \(code)")
    }
    #expect(DownloadManager.httpFailureMessage(status: 403, errorCode: nil) != session, "bare 403")
    #expect(try code(fromBody: "Forbidden") == nil, "a non-JSON body has no code")
  }

  /// OC: TASK-961 AC4 · FRD-002 FR-216: an owner-PIN reset on a two-factor DSM account without a
  /// code. Red if: it renders the raw identifier "Otp required.".
  @Test func otpRequiredAsksForTheVerificationCode() {
    #expect(APIError.server("otp_required", status: 403).userMessage
            == "This DSM account uses two-factor sign-in. Enter your DSM verification code along with your password.")
  }
}
