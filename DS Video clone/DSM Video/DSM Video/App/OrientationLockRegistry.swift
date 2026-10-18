import Foundation
#if os(iOS)
import UIKit

/// Which window scenes are locked to landscape (the video player), keyed by scene id.
///
/// The lock used to be one global mask, signalled to `connectedScenes.first`. With
/// `UIApplicationSupportsMultipleScenes` on, an iPad can show the app in two windows, and
/// "first" is not the one playing: the player's window never rotated, and the global mask
/// leaked landscape into the other window (TASK-756). The lock is now per scene. A scene
/// with no entry is portrait, the app's default for all navigation UI.
struct OrientationLockRegistry: Equatable {
  private var locks: [String: UIInterfaceOrientationMask] = [:]

  /// The mask a scene should report. Unknown or nil scene = portrait.
  func mask(for sceneID: String?) -> UIInterfaceOrientationMask {
    guard let sceneID else { return .portrait }
    return locks[sceneID] ?? .portrait
  }

  func isLocked(_ sceneID: String) -> Bool { mask(for: sceneID) != .portrait }

  /// Records `mask` for a scene. Portrait is the default, so it clears the entry.
  mutating func set(_ mask: UIInterfaceOrientationMask, for sceneID: String) {
    if mask == .portrait {
      locks.removeValue(forKey: sceneID)
    } else {
      locks[sceneID] = mask
    }
  }

  /// Drops entries for scenes that no longer exist, so a closed window cannot leave a lock behind.
  mutating func prune(keeping liveSceneIDs: Set<String>) {
    locks = locks.filter { liveSceneIDs.contains($0.key) }
  }
}
#endif
