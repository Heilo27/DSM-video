import Foundation
import Testing
@testable import DSM_Video

// MARK: - Contact Support mail fallback (TASK-757 · item 7)

/// `openURL(mailto:)` reports failure only through its completion handler. These pin the
/// decision made from that result: opened -> say nothing; not opened -> copy the address and
/// tell the user, without claiming a copy that did not happen.
@MainActor
struct SupportContactTests {

  @Test func mailURLTargetsTheSupportAddress() {
    #expect(SupportContact.mailURL?.absoluteString == "mailto:\(SupportContact.address)")
  }

  @Test func openedMailComposerNeedsNoMessageAndNoCopy() {
    var copied: [String] = []
    let message = SupportContact.fallbackMessage(opened: true) { copied.append($0); return true }
    #expect(message == nil)
    #expect(copied.isEmpty)
  }

  @Test func failedOpenCopiesTheAddressAndSaysSo() {
    var copied: [String] = []
    let message = SupportContact.fallbackMessage(opened: false) { copied.append($0); return true }
    #expect(copied == [SupportContact.address])
    let text = message ?? ""
    #expect(text.contains(SupportContact.address))
    #expect(text.contains("copied to the clipboard"))
  }

  @Test func failedOpenAndFailedCopyDoesNotClaimACopy() {
    let message = SupportContact.fallbackMessage(opened: false) { _ in false } ?? ""
    #expect(message.contains(SupportContact.address))
    #expect(!message.contains("has been copied"))
  }
}
