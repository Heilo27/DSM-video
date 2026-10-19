import Foundation
import Testing
@testable import DSM_Video

// TASK-1065 repro (FR-262, AC-002-43), from the bug report: a Teens (PG-13 / TV-14) profile
// opened The Expanse (TV-MA) from Just Added and could press Play. The detail page is the one
// screen that starts playback, and it consulted nothing about the active profile's ceiling.
// `ItemDetailView.playRestricted` is the rule that withholds Play and Start Over.

@MainActor
@Suite("Detail page withholds Play above the ceiling (TASK-1065)")
struct PlayRestrictedTests {
  /// The server's ladder: 1 = kids ... 3 = teens (TV-14), 4 = adult / unrated.
  private let teens = ProfileScope(id: "pf_teen", maxAgeLevel: 3, unratedLevel: 4)
  private let adult = ProfileScope(id: "pf_adult", maxAgeLevel: 4, unratedLevel: 4)

  @Test("A TV-MA title (level 4) is restricted for Teens, an allowed one is not")
  func loadedTitleAgainstCeiling() {
    #expect(ItemDetailView.playRestricted(.loaded(ageLevel: 4), isDownloaded: false, scope: teens))
    #expect(!ItemDetailView.playRestricted(.loaded(ageLevel: 3), isDownloaded: false, scope: teens))
    #expect(!ItemDetailView.playRestricted(.loaded(ageLevel: 1), isDownloaded: false, scope: teens))
  }

  @Test("The boundary: a title exactly at the ceiling plays, one above does not")
  func boundary() {
    let pg = ProfileScope(id: "pf_x", maxAgeLevel: 2, unratedLevel: 4)
    #expect(!ItemDetailView.playRestricted(.loaded(ageLevel: 2), isDownloaded: false, scope: pg))
    #expect(ItemDetailView.playRestricted(.loaded(ageLevel: 3), isDownloaded: false, scope: pg))
  }

  @Test("An unrated title counts as the unrated level, so Teens cannot start it")
  func unratedCountsAsUnratedLevel() {
    #expect(ItemDetailView.playRestricted(.loaded(ageLevel: nil), isDownloaded: false, scope: teens))
    #expect(!ItemDetailView.playRestricted(.loaded(ageLevel: nil), isDownloaded: false, scope: adult))
  }

  @Test("The server's refusal wins, even for a file on disk")
  func serverRefusalAlwaysRestricts() {
    #expect(ItemDetailView.playRestricted(.restricted, isDownloaded: false, scope: adult))
    #expect(ItemDetailView.playRestricted(.restricted, isDownloaded: true, scope: adult))
  }

  @Test("A failed load restricts unless the file is already on disk (offline downloads still play)")
  func failedLoad() {
    #expect(ItemDetailView.playRestricted(.failed, isDownloaded: false, scope: teens))
    #expect(!ItemDetailView.playRestricted(.failed, isDownloaded: true, scope: teens))
  }

  @Test("While the load is in flight Play is not hidden (no flash on every open)")
  func loadingIsNotRestricted() {
    #expect(!ItemDetailView.playRestricted(.loading, isDownloaded: false, scope: teens))
  }

  @Test("The server's content_restricted and a bare 403 both classify as a ceiling refusal; others do not")
  func apiErrorClassification() {
    #expect(APIError.server("content_restricted", status: 403).isContentRestricted)
    #expect(APIError.server("forbidden", status: 403).isContentRestricted)
    #expect(APIError.http(403).isContentRestricted)
    #expect(!APIError.http(404).isContentRestricted)
    #expect(!APIError.server("not_found", status: 404).isContentRestricted)
    #expect(!APIError.connection(.notConnectedToInternet).isContentRestricted)
  }
}
