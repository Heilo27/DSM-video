import Foundation
#if os(tvOS)
import TVServices
#endif

/// Tells the system the Top Shelf's content changed (FRD-001 FR-146, TASK-992).
///
/// The app writes topshelf.json to the shared App Group container, but tvOS only asks the
/// extension for content when the app is focused or when told the content changed. Nothing told
/// it, so a title finished or a profile added left the old shelf on the Home Screen until tvOS
/// happened to reload it. `AppState.writeTopShelfSnapshot` and `deleteTopShelfSnapshot` call
/// `notify` after the file really changed.
///
/// `notify` is a seam: tests replace it to count calls without a tvOS system. iPhone and iPad have
/// no Top Shelf, so the default does nothing there.
enum TopShelfRefresh {
  static var notify: () -> Void = {
    #if os(tvOS)
    TVTopShelfContentProvider.topShelfContentDidChange()
    #endif
  }
}
