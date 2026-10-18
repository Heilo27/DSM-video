import Foundation
import Testing
@testable import DSM_Video

// TASK-952 · FRD-002 FR-203. The editor counts a profile name in the server's unit, Unicode code
// points of the trimmed name, so Save is on exactly when the server accepts. The literals are the
// same ones the Go server pins in profiles_name_units_test.go; change both together.
// Red if the editor counts Swift Characters again: the family emoji below is one Character but
// seven code points, so a 21-point name would read as 15 and Save would stay on.

@Suite("Profile name rules")
struct ProfileNameRulesTests {

  private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"

  @Test func twentyIsTheLastAcceptedLength() {
    #expect(ProfileNameRules.isValid(String(repeating: "a", count: 20)))
    #expect(!ProfileNameRules.isValid(String(repeating: "a", count: 21)))
  }

  @Test func emptyAndBlankNamesAreRefused() {
    #expect(ProfileNameRules.status(of: "") == .empty)
    #expect(ProfileNameRules.status(of: "  \t\n ") == .empty)
  }

  @Test func paddingIsTrimmedNotCounted() {
    let padded = "  " + String(repeating: "a", count: 20) + "  "
    #expect(ProfileNameRules.length(of: padded) == 20)
    #expect(ProfileNameRules.isValid(padded))
  }

  @Test func aFamilyEmojiCostsSevenLikeTheServerCountsIt() {
    let over = "Grandma \(family) Smith"
    let fits = "Grandma \(family) Smit"
    #expect(over.count == 15, "Swift sees 15 characters, which is why the old check let it through")
    #expect(ProfileNameRules.length(of: over) == 21)
    #expect(!ProfileNameRules.isValid(over))
    #expect(ProfileNameRules.length(of: fits) == 20)
    #expect(ProfileNameRules.isValid(fits))
  }

  @Test func combiningMarksCountAsTheirOwnPoints() {
    #expect(ProfileNameRules.isValid(String(repeating: "e\u{301}", count: 10)))
    #expect(!ProfileNameRules.isValid(String(repeating: "e\u{301}", count: 11)))
    #expect(ProfileNameRules.isValid(String(repeating: "\u{E9}", count: 20)))
  }

  @Test func theCounterAndTheReasonSayWhySaveIsOff() {
    #expect(ProfileNameRules.counter(for: "Ann") == "3/20")
    #expect(ProfileNameRules.reason(for: "Ann") == nil)
    #expect(ProfileNameRules.reason(for: "  ") == "Enter a name to save.")
    let long = String(repeating: "a", count: 23)
    #expect(ProfileNameRules.counter(for: long) == "23/20")
    #expect(ProfileNameRules.reason(for: long)?.hasPrefix("3 too many.") == true)
  }
}
