import Testing
import Foundation
@testable import DSM_Video

// TASK-1063 (FRD-002 FR-212, FR-266): choosing a PIN is two entries. NewPinView rebuilds its pad
// whenever the step changes, so a rejected confirm used to wipe the message it was about to show:
// the owner never saw "Those PINs didn't match" or that the NAS was unreachable. The flow now
// carries the reason into the step it returns to; the view hands it to the new pad as its first
// error. These tests pin that transition. That the pad draws `notice` is a view wiring covered by
// the TASK-969 UI tests, not here.
// Expected strings are literals, never read back from production.

@Suite("TASK-1063 · a rejected new PIN keeps its message")
struct NewPinFlowTests {
  private static let mismatch = "Those PINs didn't match. Choose a PIN again."
  private static let nasUnreachable =
    "Couldn't reach your NAS, so nothing was changed. Check your connection and try again."

  /// Given a first entry of 1234, when 1235 is entered to confirm, then the flow is back at the
  /// first step AND carries the mismatch sentence for the pad that replaces the old one.
  /// Red if: the reject resets the step without recording the reason (the original bug), or the
  /// flow stays on the confirm step.
  @Test func aMismatchReturnsToTheFirstStepAndCarriesTheMessage() {
    var flow = NewPinFlow()
    #expect(flow.enter("1234") == .confirm)
    #expect(flow.isConfirming)

    #expect(flow.enter("1235") == .reject(Self.mismatch))
    #expect(!flow.isConfirming)
    #expect(flow.notice == Self.mismatch)
  }

  /// Given matching entries, when the save then fails because the NAS is unreachable, then the
  /// flow is back at the first step carrying the saveNeedsNAS sentence.
  /// Red if: saveFailed leaves the flow on the confirm step or drops the message.
  @Test func aFailedSaveReturnsToTheFirstStepAndCarriesTheMessage() {
    var flow = NewPinFlow()
    _ = flow.enter("0420")
    #expect(flow.enter("0420") == .save("0420"))

    flow.saveFailed(ProfileText.saveFailure(APIError.network))
    #expect(!flow.isConfirming)
    #expect(flow.notice == Self.nasUnreachable)
  }

  /// Given a server reason for the failed save (not an unreachable NAS), then that reason, not
  /// the NAS sentence, is what the pad gets.
  /// Red if: saveFailed substitutes a fixed message for the one it is given.
  @Test func aFailedSaveCarriesTheCallersOwnReason() {
    var flow = NewPinFlow()
    _ = flow.enter("0420")
    _ = flow.enter("0420")
    flow.saveFailed("Some server reason.")
    #expect(flow.notice == "Some server reason.")
  }

  /// Given a previous reject left a notice, when a fresh first entry is taken, then the notice
  /// is gone: the confirm pad must not repeat an error from the step before.
  /// Red if: the first entry leaves `notice` set.
  @Test func takingAFirstEntryClearsTheEarlierMessage() {
    var flow = NewPinFlow()
    _ = flow.enter("1111")
    _ = flow.enter("2222")
    #expect(flow.notice != nil)

    #expect(flow.enter("3333") == .confirm)
    #expect(flow.notice == nil)
    #expect(flow.isConfirming)
  }

  /// Given matching entries, then nothing is rejected and no message is carried.
  /// Red if: a successful confirm marks the flow as failed.
  @Test func matchingEntriesAskForTheSaveWithoutAMessage() {
    var flow = NewPinFlow()
    _ = flow.enter("9876")
    #expect(flow.enter("9876") == .save("9876"))
    #expect(flow.notice == nil)
  }
}
