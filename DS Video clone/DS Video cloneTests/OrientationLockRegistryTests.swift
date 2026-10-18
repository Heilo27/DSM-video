import Foundation
import Testing
#if os(iOS)
import UIKit
#endif
@testable import DSM_Video

#if os(iOS)
// MARK: - Per-scene orientation lock (TASK-756 · item 6)

/// With multiple scenes enabled, a player in scene B must not rotate scene A, and must not be
/// signalled through whichever scene UIKit lists first.
@MainActor
struct OrientationLockRegistryTests {

  @Test func unknownAndNilScenesArePortrait() {
    let registry = OrientationLockRegistry()
    #expect(registry.mask(for: nil) == .portrait)
    #expect(registry.mask(for: "scene-a") == .portrait)
  }

  @Test func lockingOneSceneLeavesOthersPortrait() {
    var registry = OrientationLockRegistry()
    registry.set(.landscape, for: "scene-b")
    #expect(registry.mask(for: "scene-b") == .landscape)
    #expect(registry.mask(for: "scene-a") == .portrait)
    #expect(registry.isLocked("scene-b"))
    #expect(!registry.isLocked("scene-a"))
  }

  @Test func unlockRestoresPortraitForThatSceneOnly() {
    var registry = OrientationLockRegistry()
    registry.set(.landscape, for: "scene-a")
    registry.set(.landscape, for: "scene-b")
    registry.set(.portrait, for: "scene-b")
    #expect(registry.mask(for: "scene-b") == .portrait)
    #expect(registry.mask(for: "scene-a") == .landscape)
  }

  @Test func closedSceneCannotLeaveALockBehind() {
    var registry = OrientationLockRegistry()
    registry.set(.landscape, for: "gone")
    registry.set(.landscape, for: "live")
    registry.prune(keeping: ["live"])
    #expect(!registry.isLocked("gone"))
    #expect(registry.isLocked("live"))
  }
}
#endif
