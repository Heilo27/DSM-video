import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The support mailbox and what to do when the device cannot open a mail composer.
///
/// `openURL(mailto:)` reports failure through its completion handler, not by throwing. A Mac,
/// iPad or Apple TV with no mail account set up answers "not opened" and the old call site
/// dropped that on the floor: the user tapped Contact Support and nothing happened (TASK-757).
/// The fallback is the address itself, on the clipboard, with a message that says so.
enum SupportContact {
  /// The one home for the support address (Rule 9).
  static let address = "heiloprojects@icloud.com"

  static var mailURL: URL? { URL(string: "mailto:\(address)") }

  /// What to show when the mail composer could not be opened. `copied` says whether the
  /// address really reached the clipboard, so the message never claims more than happened.
  static func failureMessage(copied: Bool) -> String {
    if copied {
      return "This device couldn't open a mail composer, so no email was started. "
        + "The support address, \(address), has been copied to the clipboard. "
        + "Paste it into your mail app to write to us."
    }
    return "This device couldn't open a mail composer, and the address couldn't be copied. "
      + "Write to us at \(address)."
  }

  /// Decides what follows an attempt to open the mail composer.
  /// - Parameters:
  ///   - opened: the `openURL` completion result.
  ///   - copy: puts the address on the clipboard; returns whether it landed.
  /// - Returns: nil when the composer opened (nothing to tell the user), else the message to show.
  static func fallbackMessage(opened: Bool, copy: (String) -> Bool) -> String? {
    if opened { return nil }
    return failureMessage(copied: copy(address))
  }

  /// Writes `text` to the general pasteboard and confirms by reading it back.
  @MainActor
  static func copyToClipboard(_ text: String) -> Bool {
    #if os(iOS)
    UIPasteboard.general.string = text
    return UIPasteboard.general.string == text
    #elseif os(macOS)
    let board = NSPasteboard.general
    board.clearContents()
    guard board.setString(text, forType: .string) else { return false }
    return board.string(forType: .string) == text
    #else
    return false  // tvOS has no pasteboard; the message then shows the address instead
    #endif
  }
}
