import SwiftUI

/// Multi-select genre filter shown above a library grid.
///
/// Built on the existing `SortChip` / `SortChipScroller` rather than a parallel control,
/// which matters more than it looks: SortChip already carries the tvOS focus handling
/// (`@Environment(\.isFocused)` + `@FocusState`), and it lives inside the scroll content
/// rather than in a toolbar.
///
/// That last point is load-bearing. `ToolbarItem(placement: .topBar*)` does NOT render on
/// tvOS — it compiles cleanly and then simply never appears. This project has shipped an
/// invisible control that way more than once (library search, and the sort controls this
/// chip was written to rescue). A focusable row inside the content is the pattern that
/// works on both platforms.
///
/// Filtering itself is server-side. Client-side filtering would only ever cover pages
/// already loaded, so on a 500-item library the filter would look like it worked while
/// missing most of the results.
struct GenreFilterBar: View {
  /// Genres available in this library, most-used first.
  let available: [GenreCount]
  /// Currently selected genres. Empty means "no filter".
  @Binding var selected: Set<String>
  /// How multiple selections combine.
  @Binding var mode: APIClient.GenreMode

  var body: some View {
    if available.isEmpty {
      // No genre data yet (or a library TMDb hasn't enriched). Render nothing rather than
      // an empty bar — a control that can't do anything is worse than no control.
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 8) {
        SortChipScroller {
          // "All" clears the filter. Always first so there is a consistent way back to the
          // unfiltered grid without hunting for which chips are lit.
          SortChip(
            label: "All",
            isActive: selected.isEmpty,
            accessibilityLabel: selected.isEmpty ? "Showing all genres" : "Clear genre filter"
          ) {
            selected.removeAll()
          }

          ForEach(available) { genre in
            let isOn = selected.contains(genre.name)
            SortChip(
              label: "\(genre.name) (\(genre.count))",
              isActive: isOn,
              accessibilityLabel: isOn
                ? "\(genre.name), \(genre.count) titles, selected. Activate to remove."
                : "\(genre.name), \(genre.count) titles. Activate to filter."
            ) {
              if isOn { selected.remove(genre.name) } else { selected.insert(genre.name) }
            }
          }
        }

        // The any/all toggle only means something with 2+ genres selected, so it stays
        // hidden until then instead of sitting there inert.
        if selected.count >= 2 {
          SortChipScroller {
            SortChip(
              label: "Any selected",
              isActive: mode == .any,
              accessibilityLabel: "Match any selected genre"
            ) { mode = .any }

            SortChip(
              label: "All selected",
              isActive: mode == .all,
              accessibilityLabel: "Match every selected genre"
            ) { mode = .all }
          }
        }
      }
    }
  }
}
