import Testing
import Foundation
@testable import DSM_Video

// TASK-969 / FR-263, FR-266 (AC-002-41, AC-002-43): the picker and the management screens must
// say the real cause of a failed PIN check or save. The screens only display
// `ProfileText.pinFailure` / `saveFailure`; choosing between "the NAS could not be reached" and
// the server's own reason is decided here, so it is observable without a UI runner. What stays
// UI-only (the picker declining to open the pad offline) is listed in TASK-969.
//
// Expected strings are literals from FRD-002 / ProfilesAPI.md, never read back from production.

@Suite("FR-263/266 · the failure text names the real cause")
struct ProfileFailureWordingTests {

  private static let nasUnreachablePin = "Your NAS needs to be reachable to check this PIN."
  private static let nasUnreachableSave =
    "Couldn't reach your NAS, so nothing was changed. Check your connection and try again."

  /// OC-2179 (the picker shows this same sentence) + OC-2192 · given the NAS cannot be reached, whatever the transport
  /// failure, when a PIN check fails, then the text is the NAS-must-be-reachable sentence and
  /// never a wrong-PIN message.
  /// Red if: pinFailure stops testing `serverReached` (a transport error would then be worded by
  /// APIError.userMessage), or maps an unreachable NAS to "Incorrect PIN".
  @Test(arguments: [
    APIError.network,
    APIError.connection(.notConnectedToInternet),
    APIError.connection(.timedOut),
    APIError.localNetworkDenied,
  ])
  func anUnreachableNASIsNeverReportedAsAWrongPin(_ error: APIError) {
    let text = ProfileText.pinFailure(error)
    #expect(text == Self.nasUnreachablePin)
    #expect(!text.contains("Incorrect"))
  }

  /// OC-2179 · given the failure is not an APIError at all (a cancelled task, a decoding bug
  /// upstream), then the user still gets the unreachable-NAS sentence, not an empty or crashing
  /// message.
  /// Red if: the cast guard is removed or the fallback becomes an empty string.
  @Test func aNonAPIErrorFallsBackToTheUnreachableNASSentence() {
    #expect(ProfileText.pinFailure(CancellationError()) == Self.nasUnreachablePin)
  }

  /// OC-2192 (wider than PinFailuresKeepTheSessionTests, which drives one stub) · given the NAS answered, then the server's own reason is shown: a wrong
  /// PIN with the tries left, and a lock with the time left (rounded up to whole minutes).
  /// Red if: pinFailure returns the unreachable sentence for every error, or drops the counts.
  @Test func anAnsweringServerGetsItsOwnReason() {
    let wrong = APIError.server("pin_incorrect", status: 403,
                                detail: APIErrorDetail(attemptsRemaining: 3, retryAfterSeconds: nil))
    #expect(ProfileText.pinFailure(wrong) == "Incorrect PIN. 3 tries left before this profile locks.")

    let lastTry = APIError.server("pin_incorrect", status: 403,
                                  detail: APIErrorDetail(attemptsRemaining: 1, retryAfterSeconds: nil))
    #expect(ProfileText.pinFailure(lastTry) == "Incorrect PIN. 1 try left before this profile locks.")

    let locked = APIError.server("pin_locked", status: 429,
                                 detail: APIErrorDetail(attemptsRemaining: nil, retryAfterSeconds: 125))
    #expect(ProfileText.pinFailure(locked) == "Too many incorrect PINs. Try again in 3 minutes.")

    let lockedShort = APIError.server("pin_locked", status: 429,
                                      detail: APIErrorDetail(attemptsRemaining: nil, retryAfterSeconds: 1))
    #expect(ProfileText.pinFailure(lockedShort) == "Too many incorrect PINs. Try again in 1 second.")
  }

  /// Boundary · given a wrong PIN that used the last try (0 left) or a lock with no time
  /// reported, then the text still says what happened (locked / wait) instead of "0 tries left".
  /// Red if: the `...0` case of incorrectPinMessage or the no-seconds branch of
  /// pinLockedMessage is removed.
  @Test func zeroTriesLeftAndAnUnknownLockTimeStillExplainThemselves() {
    let none = APIError.server("pin_incorrect", status: 403,
                               detail: APIErrorDetail(attemptsRemaining: 0, retryAfterSeconds: nil))
    #expect(ProfileText.pinFailure(none)
            == "Incorrect PIN. No tries left, so PIN entry for this profile is locked for a while.")

    let lockedNoTime = APIError.server("pin_locked", status: 429)
    #expect(ProfileText.pinFailure(lockedNoTime)
            == "Too many incorrect PINs. Wait a few minutes and try again.")
  }

  /// FR-266 · given a failed create/edit/delete, then an unreachable NAS says nothing was
  /// changed, and an answering server gives its own reason (a duplicate name is not "couldn't
  /// reach your NAS").
  /// Red if: saveFailure loses the serverReached test in either direction.
  @Test func saveFailureSeparatesAnUnreachableNASFromAServerRefusal() {
    #expect(ProfileText.saveFailure(APIError.connection(.cannotConnectToHost)) == Self.nasUnreachableSave)
    #expect(ProfileText.saveFailure(APIError.localNetworkDenied) == Self.nasUnreachableSave)
    #expect(ProfileText.saveFailure(CancellationError()) == Self.nasUnreachableSave)

    let dup = APIError.server("duplicate_profile_name", status: 409)
    #expect(ProfileText.saveFailure(dup) == "Another profile already has that name.")
    let limit = APIError.server("profile_limit_reached", status: 409)
    #expect(ProfileText.saveFailure(limit)
            == "This account already has the most profiles allowed. Delete one to add another.")
  }
}
