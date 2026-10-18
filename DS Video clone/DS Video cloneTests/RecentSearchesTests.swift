import Foundation
import Testing
@testable import DSM_Video

// MARK: - Recent searches (TASK-1043 · OC-1096 · FR-092)
//
// Ordering, de-duplication, the cap and persistence, observed through a FRESH instance read
// back from an isolated UserDefaults suite (what the next launch would see). Expected values
// are literals.

private func isolatedDefaults() throws -> (UserDefaults, () -> Void) {
  let name = "dsreel-recents-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: name))
  return (defaults, { defaults.removePersistentDomain(forName: name) })
}

@Suite("Recent searches")
@MainActor
struct RecentSearchesTests {

  /// Records `phrases` in order, saves, and reads back through a fresh instance.
  private func roundTrip(_ phrases: [String], into defaults: UserDefaults) -> [String] {
    var recents = RecentSearches(defaults: defaults)
    for phrase in phrases { recents.add(phrase) }
    recents.save(to: defaults)
    return RecentSearches(defaults: defaults).items
  }

  /// OC-1096 · nothing stored reads as an empty list; one search is one entry.
  @Test func emptyAndOneEntry() throws {
    let (defaults, cleanup) = try isolatedDefaults()
    defer { cleanup() }
    #expect(RecentSearches(defaults: defaults).items == [])
    #expect(roundTrip(["The Signal"], into: defaults) == ["The Signal"])
  }

  /// OC-1096 · newest first.
  /// Red if: new searches are appended to the end instead of the front.
  @Test func newestComesFirst() throws {
    let (defaults, cleanup) = try isolatedDefaults()
    defer { cleanup() }
    #expect(roundTrip(["alpha", "bravo", "charlie"], into: defaults) == ["charlie", "bravo", "alpha"])
  }

  /// OC-1096 · exactly ten are kept; the eleventh pushes the oldest out.
  /// Red if: the cap moves (9 or 11 kept), or the newest rather than the oldest is dropped.
  @Test func tenAreKeptAndTheEleventhDropsTheOldest() throws {
    let (defaults, cleanup) = try isolatedDefaults()
    defer { cleanup() }
    let ten = (1...10).map { "q\($0)" }
    #expect(roundTrip(ten, into: defaults) == ["q10", "q9", "q8", "q7", "q6", "q5", "q4", "q3", "q2", "q1"])

    let (defaults2, cleanup2) = try isolatedDefaults()
    defer { cleanup2() }
    let eleven = (1...11).map { "q\($0)" }
    #expect(roundTrip(eleven, into: defaults2) == ["q11", "q10", "q9", "q8", "q7", "q6", "q5", "q4", "q3", "q2"])
  }

  /// OC-1096 · repeating a search moves it to the front, once, ignoring case; the other
  /// entries keep their order.
  /// Red if: a repeat is listed twice, case makes it a new entry, or it stays where it was.
  @Test func aRepeatMovesToTheFrontOnceIgnoringCase() throws {
    let (defaults, cleanup) = try isolatedDefaults()
    defer { cleanup() }
    #expect(roundTrip(["alpha", "bravo", "charlie", "ALPHA"], into: defaults) == ["ALPHA", "charlie", "bravo"])
  }

  /// OC-1096 · a repeat at the cap does not push an unrelated entry out.
  /// Red if: the cap is applied before the duplicate is removed.
  @Test func aRepeatAtTheCapKeepsEveryOtherEntry() throws {
    let (defaults, cleanup) = try isolatedDefaults()
    defer { cleanup() }
    let ten = (1...10).map { "q\($0)" }
    #expect(roundTrip(ten + ["q1"], into: defaults) == ["q1", "q10", "q9", "q8", "q7", "q6", "q5", "q4", "q3", "q2"])
  }

  /// OC-1096 · removing one entry leaves the rest; clearing empties the list, and both survive
  /// a fresh read.
  @Test func removeAndClearPersist() throws {
    let (defaults, cleanup) = try isolatedDefaults()
    defer { cleanup() }
    var recents = RecentSearches(items: ["c", "b", "a"])
    recents.remove("b")
    recents.save(to: defaults)
    #expect(RecentSearches(defaults: defaults).items == ["c", "a"])

    recents.clear()
    recents.save(to: defaults)
    #expect(RecentSearches(defaults: defaults).items == [])
  }

  /// OC-1096 · phrases are stored and returned as typed, and the screen's stored form
  /// round-trips (the view keeps the same string under `RecentSearches.defaultsKey`).
  @Test func storedFormAndKeyAreStable() throws {
    #expect(RecentSearches.defaultsKey == "dsReel.recentSearches")
    #expect(RecentSearches(items: ["a b", "c"]).raw == "a b\u{001F}c")
    #expect(RecentSearches(raw: "a b\u{001F}c").items == ["a b", "c"])
    #expect(RecentSearches(raw: "").items == [])
    #expect(RecentSearches(raw: "\u{001F}x\u{001F}").items == ["x"], "empty segments are ignored")
  }
}
