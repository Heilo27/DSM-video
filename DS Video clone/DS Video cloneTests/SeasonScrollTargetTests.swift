import Foundation
import Testing
@testable import DSM_Video

// MARK: - Which season the show page scrolls to on arrival (TASK-757 · item 8)

@MainActor
struct SeasonScrollTargetTests {

  private func freshShowID() -> String { "show_\(UUID().uuidString)" }

  /// A resume point in season 6 opens season 6, which sits below the fold: scroll to it.
  @Test func highlightedLaterSeasonIsTheTarget() {
    let id = freshShowID()
    defer { SeasonExpansionStore.clear(showID: id) }
    let target = SeasonExpansionStore.initialScrollSeason(
      showID: id, allSeasons: [1, 2, 3, 6], highlightSeason: 6)
    #expect(target == 6)
  }

  /// The first season sits right under the header; scrolling would only hide the header.
  @Test func firstSeasonNeverScrolls() {
    let id = freshShowID()
    defer { SeasonExpansionStore.clear(showID: id) }
    #expect(SeasonExpansionStore.initialScrollSeason(
      showID: id, allSeasons: [1, 2, 3], highlightSeason: nil) == nil)
    #expect(SeasonExpansionStore.initialScrollSeason(
      showID: id, allSeasons: [1, 2, 3], highlightSeason: 1) == nil)
  }

  /// With no resume point, a season the user left expanded last visit is the target.
  @Test func rememberedExpansionIsTheTarget() {
    let id = freshShowID()
    defer { SeasonExpansionStore.clear(showID: id) }
    SeasonExpansionStore.setExpanded(true, season: 4, showID: id,
                                     allSeasons: [1, 2, 3, 4], highlightSeason: nil)
    SeasonExpansionStore.setExpanded(false, season: 1, showID: id,
                                     allSeasons: [1, 2, 3, 4], highlightSeason: nil)
    #expect(SeasonExpansionStore.initialScrollSeason(
      showID: id, allSeasons: [1, 2, 3, 4], highlightSeason: nil) == 4)
  }

  /// The user collapsed the highlighted season: nothing is open there, so don't scroll to it.
  @Test func collapsedHighlightIsNotScrolledTo() {
    let id = freshShowID()
    defer { SeasonExpansionStore.clear(showID: id) }
    SeasonExpansionStore.setExpanded(false, season: 6, showID: id,
                                     allSeasons: [1, 6], highlightSeason: 6)
    #expect(SeasonExpansionStore.initialScrollSeason(
      showID: id, allSeasons: [1, 6], highlightSeason: 6) == nil)
  }

  @Test func noSeasonsMeansNoTarget() {
    #expect(SeasonExpansionStore.initialScrollSeason(
      showID: freshShowID(), allSeasons: [], highlightSeason: nil) == nil)
  }
}
