import SwiftUI
import WidgetKit

// MARK: - Continue Watching widget (FR-154, TASK-743 B2)
//
// iPhone only. Reads ONE thing: the snapshot the app writes to the app group
// (ContinueWatchingSnapshot.swift, compiled into this target from the app's Models folder, not
// copied). It never opens a network connection (TRUTHS A2) and never decides what is shown:
// ContinueWatchingSnapshotPolicy.read is the whole rule, including "only the active profile's".

/// One render of the widget: the entries the policy allows right now (possibly none).
struct ContinueWatchingTimelineEntry: TimelineEntry {
  let date: Date
  let entries: [ContinueWatchingSnapshot.Entry]
}

/// Reads the snapshot. The timeline never expires on its own (`.never`): the app reloads it through
/// WidgetCenter whenever it writes a different snapshot (ContinueWatchingWidgetRefresh), so a
/// periodic wake-up would only re-read the same file.
struct ContinueWatchingProvider: TimelineProvider {
  func placeholder(in context: Context) -> ContinueWatchingTimelineEntry {
    ContinueWatchingTimelineEntry(date: .now, entries: [])
  }

  func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingTimelineEntry) -> Void) {
    completion(ContinueWatchingTimelineEntry(date: .now, entries: Self.currentEntries()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingTimelineEntry>) -> Void) {
    let entry = ContinueWatchingTimelineEntry(date: .now, entries: Self.currentEntries())
    completion(Timeline(entries: [entry], policy: .never))
  }

  /// The visible entries, or none when the file, the app group or the active profile is missing:
  /// every one of those reads as "Nothing in progress", never as an error.
  private static func currentEntries() -> [ContinueWatchingSnapshot.Entry] {
    guard let fileURL = ContinueWatchingSnapshotPolicy.containerFileURL(),
          let defaults = UserDefaults(suiteName: SharedAppGroup.identifier) else { return [] }
    return ContinueWatchingSnapshotPolicy.read(from: fileURL, defaults: defaults)
  }
}

@main
struct ContinueWatchingWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: ContinueWatchingSnapshotPolicy.widgetKind,
                        provider: ContinueWatchingProvider()) { entry in
      ContinueWatchingWidgetView(entries: entry.entries)
    }
    .configurationDisplayName("Continue Watching")
    .description("Pick up where you left off.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
