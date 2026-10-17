import XCTest

/// TASK-917 · FR-206, FR-211: the profile editor's Save, Cancel and Delete sit below the
/// fold on a 1080p tvOS screen. They must be reachable by the Siri Remote from the first
/// focused control, or a profile can be neither saved nor deleted on the TV.
///
/// Red if: Save/Cancel/Delete lose their `.focused()` binding or accessibility identifier,
/// are placed where the focus engine cannot arrive (no focus path), or the editor stops
/// being the screen `-UITestProfileScreen editor` opens (DEBUG fixture: Maya, not the owner).
final class TVProfileEditorReachabilityTests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func focusedIdentifier(_ app: XCUIApplication) -> String {
    let focused = app.descendants(matching: .any)
      .matching(NSPredicate(format: "hasFocus == true"))
    guard focused.count > 0 else { return "" }
    return focused.element(boundBy: 0).identifier
  }

  /// Presses `button` up to `limit` times until `target` holds focus. Returns the trail.
  @discardableResult
  private func press(_ button: XCUIRemote.Button, until target: String, limit: Int,
                     app: XCUIApplication) -> [String] {
    var trail = [focusedIdentifier(app)]
    var steps = 0
    while trail.last != target && steps < limit {
      XCUIRemote.shared.press(button)
      Thread.sleep(forTimeInterval: 0.7)
      trail.append(focusedIdentifier(app))
      steps += 1
    }
    return trail
  }

  func testEditorSaveCancelAndDeleteAreReachableByRemote() {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestProfileScreen", "editor"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
    XCTAssertTrue(app.buttons["profileEditor.save"].waitForExistence(timeout: 20),
                  "editor did not appear (or Save lost its identifier)")

    let down = press(.down, until: "profileEditor.save", limit: 14, app: app)
    XCTAssertEqual(down.last, "profileEditor.save",
                   "Save unreachable going down; focus trail: \(down)")

    let toCancel = press(.right, until: "profileEditor.cancel", limit: 3, app: app)
    XCTAssertEqual(toCancel.last, "profileEditor.cancel",
                   "Cancel unreachable from Save; trail: \(toCancel)")

    let toDelete = press(.right, until: "profileEditor.delete", limit: 3, app: app)
    XCTAssertEqual(toDelete.last, "profileEditor.delete",
                   "Delete unreachable from Cancel; trail: \(toDelete)")
  }
}
