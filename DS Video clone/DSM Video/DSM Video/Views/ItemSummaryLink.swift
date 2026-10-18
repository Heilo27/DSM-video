import SwiftUI

/// One poster that opens its title: the show for an episode entry, the item otherwise.
///
/// The single home of "tap a summary, land on the right page" for the collection grid and the
/// More Like This shelf (FR-151). A show is one entry: an episode row whose showName names the
/// show. It opens the show, the same way the Just Added rail opens one. The library the show
/// belongs to is the entry's own, else the first TV library.
struct ItemSummaryLink: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

  var body: some View {
    if item.type == "episode", let showName = item.showName, !showName.isEmpty,
       let tvLibrary = appState.homeLibraries.first(where: { $0.id == item.libraryId })
        ?? appState.homeFirstTVLibrary {
      NavigationLink {
        TVShowDetailView(
          show: TVShow(id: item.showFolderId ?? showName, title: showName, year: item.year,
                       seasonCount: nil, episodeCount: nil, posterImageId: item.posterImageId,
                       lastWatchedAt: nil, addedAt: nil),
          library: tvLibrary)
      } label: {
        ItemPosterCell(item: item)
      }
      .cellStyle()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(showName + (item.year.map { ", \($0)" } ?? ""))
      .accessibilityHint("Opens TV show")
    } else {
      NavigationLink {
        ItemDetailView(itemID: item.id, fallbackTitle: item.title)
      } label: {
        ItemPosterCell(item: item)
      }
      .cellStyle()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(item.title + (item.year.map { ", \($0)" } ?? ""))
      .accessibilityHint("Opens video details")
    }
  }
}

extension View {
  /// The poster-link style each platform's library grid uses: the system card on tvOS (which
  /// brings its own focus), the pressable look elsewhere.
  @ViewBuilder func cellStyle() -> some View {
    #if os(tvOS)
    self.buttonStyle(.card)
    #else
    self.dsPressable()
    #endif
  }
}
