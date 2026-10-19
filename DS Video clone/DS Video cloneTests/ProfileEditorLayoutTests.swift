import Testing
import Foundation
import SwiftUI
@testable import DSM_Video

#if canImport(UIKit)
import UIKit

// TASK-1066. Ryan's iPhone 17 Pro showed the profile editor's action row as a wide Save, a Cancel
// wrapped one letter per line ("Ca/nc/el") and a Delete that was a 110x600 vertical pill: one
// fixed HStack inside an 80pt side inset (242pt of form), and nothing said what gave way first.
//
// This hosts the real `ProfileEditorActions` / `ProfilePinRow` in a UIHostingController at the
// width the editor leaves them (screen width less `ProfileEditorView.sideInset` twice) and reads
// the height SwiftUI settles on, across every iPhone width, iPad, and Dynamic Type from xSmall to
// AX5. A label broken inside a word makes a button many lines tall, so the height is the signal:
//   - never more than two lines per button (words may wrap at AX sizes, they may not be split);
//   - at default sizes the compact arrangement is chosen, not the full stack, when it fits.
// Red against the old HStack (see the TASK-1066 mutation record). Pixels are a device check; the
// before/after screenshots are in docs/evidence/TASK-1066-*.png.

@Suite("Profile editor layout")
@MainActor
struct ProfileEditorLayoutTests {

  /// The widths in points: iPhone SE/mini, 16/17, 17 Pro, Plus/Pro Max, then iPad mini, 11-inch, 13-inch.
  private static let phoneWidths: [CGFloat] = [320, 375, 393, 402, 430, 440]
  private static let padWidths: [CGFloat] = [744, 834, 1024]

  private static let sizes: [(DynamicTypeSize, UIContentSizeCategory)] = [
    (.xSmall, .extraSmall), (.large, .large), (.xxxLarge, .extraExtraExtraLarge),
    (.accessibility1, .accessibilityMedium), (.accessibility3, .accessibilityExtraLarge),
    (.accessibility5, .accessibilityExtraExtraExtraLarge),
  ]

  private struct ActionsHost: View {
    @FocusState private var focus: ProfileEditorView.EditorControl?
    let showsDelete: Bool
    var body: some View {
      ProfileEditorActions(saveTitle: "Save", canSave: true, showsDelete: showsDelete,
                           focus: $focus, onSave: {}, onCancel: {}, onDelete: {})
    }
  }

  private struct PinHost: View {
    @FocusState private var focus: ProfileEditorView.EditorControl?
    let hasPin: Bool
    let showsRemove: Bool
    var body: some View {
      ProfilePinRow(hasPin: hasPin, showsRemove: showsRemove, focus: $focus,
                    onSetOrChange: {}, onRemove: {})
    }
  }

  private func height(of view: some View, screenWidth: CGFloat, _ size: DynamicTypeSize) -> CGFloat {
    let width = screenWidth - 2 * ProfileEditorView.sideInset
    let host = UIHostingController(
      rootView: view.environment(\.dynamicTypeSize, size).frame(width: width))
    return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
  }

  /// One button's tallest acceptable height: two lines of its label, never under the style's floor.
  private func buttonCeiling(_ category: UIContentSizeCategory) -> CGFloat {
    let font = UIFont.preferredFont(forTextStyle: .headline,
                                    compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    return max(52, 2 * font.lineHeight.rounded(.up))
  }

  private let gaps: CGFloat = 4 * .dsSpaceXXL  // far more than the row's own spacing

  @Test func actionRowNeverSplitsAWordAtAnyWidthOrTextSize() {
    for width in Self.phoneWidths + Self.padWidths {
      for (size, category) in Self.sizes {
        for showsDelete in [true, false] {
          let h = height(of: ActionsHost(showsDelete: showsDelete), screenWidth: width, size)
          let buttons: CGFloat = showsDelete ? 3 : 2
          let ceiling = buttons * buttonCeiling(category) + gaps
          #expect(h <= ceiling,
                  "actions at \(width)pt, \(size), delete=\(showsDelete): \(h)pt tall, over \(ceiling)")
        }
      }
    }
  }

  @Test func actionRowSharesALineWhenItFits() {
    for width in Self.phoneWidths + Self.padWidths {
      for size in [DynamicTypeSize.xSmall, .large] {
        let h = height(of: ActionsHost(showsDelete: false), screenWidth: width, size)
        #expect(h <= 52.5, "Save and Cancel should share one row at \(width)pt, \(size): \(h)pt tall")
        let withDelete = height(of: ActionsHost(showsDelete: true), screenWidth: width, size)
        #expect(withDelete <= 2 * 52 + .dsSpaceXXL + 0.5,
                "Delete sits on one row below at \(width)pt, \(size): \(withDelete)pt tall")
      }
    }
  }

  @Test func pinRowNeverSplitsAWordAtAnyWidthOrTextSize() {
    for width in Self.phoneWidths + Self.padWidths {
      for (size, category) in Self.sizes {
        for (hasPin, showsRemove) in [(false, false), (true, false), (true, true)] {
          let h = height(of: PinHost(hasPin: hasPin, showsRemove: showsRemove), screenWidth: width, size)
          let rows: CGFloat = showsRemove ? 3 : 2
          let ceiling = rows * buttonCeiling(category) + gaps
          #expect(h <= ceiling,
                  "PIN row at \(width)pt, \(size), pin=\(hasPin)/\(showsRemove): \(h)pt tall, over \(ceiling)")
        }
      }
    }
  }

  @Test func pinRowIsOneLineWhenItFits() {
    for width in Self.phoneWidths.filter({ $0 >= 375 }) + Self.padWidths {
      for size in [DynamicTypeSize.xSmall, .large] {
        for (hasPin, showsRemove) in [(false, false), (true, false), (true, true)] {
          let h = height(of: PinHost(hasPin: hasPin, showsRemove: showsRemove), screenWidth: width, size)
          #expect(h <= 52.5, "PIN row should be one line at \(width)pt, \(size), pin=\(hasPin)/\(showsRemove): \(h)pt")
        }
      }
    }
  }

  // MARK: Routing: the editor uses these rows, and no system `.bordered` is back in them.

  private func source(_ relative: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { url.deleteLastPathComponent() }
    url.appendPathComponent("DSM Video/DSM Video/\(relative)")
    return try String(contentsOf: url, encoding: .utf8)
  }

  @Test func theEditorRoutesThroughTheRowsAndTheirStylesAreTheAppsOwn() throws {
    let editor = try source("Views/ProfileViews.swift")
    #expect(editor.contains("ProfileEditorActions("), "the editor draws its action row with ProfileEditorActions")
    #expect(editor.contains("ProfilePinRow("), "the editor draws its PIN row with ProfilePinRow")
    #expect(editor.contains(".padding(.horizontal, Self.sideInset)"), "the form's inset is ProfileEditorView.sideInset")
    let rows = try source("Views/ProfileEditorActions.swift")
    #expect(rows.contains(".dsPrimaryButton(") && rows.contains(".dsSecondaryButton("))
    #expect(!rows.contains(".buttonStyle(") && !rows.contains(".borderedProminent"),
            "the rows use dsPrimaryButton / dsSecondaryButton, not a system style")
    #expect(!rows.contains("Color(") && !rows.contains(".red") && !rows.contains("cornerRadius:"),
            "no ad-hoc colour or radius in the rows")
  }
}
#endif
