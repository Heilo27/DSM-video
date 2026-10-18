import Foundation
#if os(iOS) && canImport(WidgetKit)
import WidgetKit
#endif

/// Tells WidgetKit the Continue Watching widget's snapshot changed (FR-154, TASK-743).
///
/// The widget reads widget-continue-watching.json from the app group and never fetches anything
/// itself, so it only redraws when its timeline is reloaded. `AppState.writeContinueWatchingSnapshot`
/// and `deleteContinueWatchingSnapshot` call `notify` after the file really changed.
///
/// `notify` is a seam: tests replace it to count calls. Apple TV has no widget, so the default does
/// nothing there.
enum ContinueWatchingWidgetRefresh {
  static var notify: () -> Void = {
    #if os(iOS) && canImport(WidgetKit)
    WidgetCenter.shared.reloadTimelines(ofKind: ContinueWatchingSnapshotPolicy.widgetKind)
    #endif
  }
}
