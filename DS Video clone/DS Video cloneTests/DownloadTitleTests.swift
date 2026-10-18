import Foundation
import Testing
@testable import DSM_Video

// MARK: - Episode download labels (TASK-980 · FR-042)

@MainActor private func episode(id: String, show: String?, season: Int?, number: Int?, title: String = "Raw.File.S01E01.1080p",
                     episodeTitle: String?) -> ItemDetail {
  ItemDetail(id: id, type: "episode", title: title, showName: show, seasonNumber: season,
             episodeNumber: number, episodeTitle: episodeTitle)
}

@MainActor
struct DownloadTitleTests {

  /// Two shows with an episode called "Pilot" must not both read "Pilot" in Downloads.
  /// Red if the label is just the episode title.
  @Test func twoPilotsOfDifferentShowsAreDistinct() {
    let a = episode(id: "e1", show: "The Signal", season: 1, number: 1, episodeTitle: "Pilot")
    let b = episode(id: "e2", show: "Meridian Cross", season: 1, number: 1, episodeTitle: "Pilot")
    #expect(a.downloadTitle == "The Signal \u{00B7} S1 \u{00B7} E1 \u{00B7} Pilot")
    #expect(b.downloadTitle == "Meridian Cross \u{00B7} S1 \u{00B7} E1 \u{00B7} Pilot")
    #expect(a.downloadTitle != b.downloadTitle)
  }

  /// Two episodes of one show are told apart by season and episode number, and the show name
  /// appears once.
  @Test func twoEpisodesOfOneShowAreDistinctAndNameTheShowOnce() {
    let one = episode(id: "e1", show: "The Signal", season: 2, number: 3, episodeTitle: "Static")
    let two = episode(id: "e2", show: "The Signal", season: 2, number: 4, episodeTitle: "Static")
    #expect(one.downloadTitle != two.downloadTitle, "same episode name, different episode")
    #expect(one.downloadTitle.components(separatedBy: "The Signal").count == 2)
    // An episode whose title merely repeats the show name does not say it twice.
    let echo = episode(id: "e3", show: "The Signal", season: 1, number: 1, episodeTitle: "the signal")
    #expect(echo.downloadTitle == "The Signal \u{00B7} S1 \u{00B7} E1")
  }

  /// A blank episode title is not rendered as an empty segment, and the raw filename-derived
  /// title does not stand in for it while the show and S/E identify the episode.
  @Test func aBlankEpisodeTitleLeavesShowAndNumbers() {
    for blank in [nil, "", "   "] {
      let item = episode(id: "e", show: "The Signal", season: 1, number: 5, episodeTitle: blank)
      #expect(item.downloadTitle == "The Signal \u{00B7} S1 \u{00B7} E5", "blank=\(String(describing: blank))")
    }
    // With no show name the raw title is all there is to tell it apart.
    let orphan = episode(id: "e", show: nil, season: nil, number: nil, title: "Some.Show.S01E05", episodeTitle: nil)
    #expect(orphan.downloadTitle == "Some.Show.S01E05")
  }

  /// Movies are untouched.
  @Test func aMovieKeepsItsTitle() {
    let movie = ItemDetail(id: "m", type: "movie", title: "Heat")
    #expect(movie.downloadTitle == "Heat")
  }

  /// The stored label is what the Downloads surface displays: the manager keeps the title it
  /// was given, so two Pilots stay distinguishable in its own rows.
  @Test func theStoredRowCarriesTheEpisodeIdentity() throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel-title-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let manager = DownloadManager(containerForTesting: container)
    let url = URL(string: "http://127.0.0.1:9/stream.mp4")!
    let a = episode(id: "e1", show: "The Signal", season: 1, number: 1, episodeTitle: "Pilot")
    let b = episode(id: "e2", show: "Meridian Cross", season: 1, number: 1, episodeTitle: "Pilot")
    for item in [a, b] {
      manager.startDownload(itemId: item.id, title: item.downloadTitle, year: nil, videoURL: url,
                            posterURL: nil, token: nil, durationSeconds: 60)
    }
    #expect(manager.activeDownloads["e1"]?.title != manager.activeDownloads["e2"]?.title)
    #expect(manager.activeDownloads["e2"]?.title.contains("Meridian Cross") == true)
  }
}
