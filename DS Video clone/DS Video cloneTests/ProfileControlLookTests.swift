import Foundation
import Testing
@testable import DSM_Video

// TASK-958 · FRD-002 FR-213 / AC-002-41. While the server verifies a PIN the pad is
// `.disabled(busy)`; the custom button styles must draw that. The decisions live in
// ProfileControlLook; the source scan pins that both styles read it and that the pad is still
// disabled while busy. Red before the fix: neither style read isEnabled, and the look type did
// not exist. What a dimmed key looks like on screen is a device check.

@Suite("Profile control look")
struct ProfileControlLookTests {

  @Test func aDisabledControlIsDimmedAndAnEnabledOneIsNot() {
    #expect(ProfileControlLook.opacity(isEnabled: true) == 1)
    #expect(ProfileControlLook.opacity(isEnabled: false) == 0.4)
  }

  @Test func aDisabledKeyNeverLightsOrLifts() {
    #expect(ProfileControlLook.isLit(isFocused: true, isPressed: false, isEnabled: true))
    #expect(ProfileControlLook.isLit(isFocused: false, isPressed: true, isEnabled: true))
    #expect(!ProfileControlLook.isLit(isFocused: false, isPressed: false, isEnabled: true))
    #expect(!ProfileControlLook.isLit(isFocused: true, isPressed: true, isEnabled: false))
    #expect(ProfileControlLook.keyScale(isFocused: true, isEnabled: true) == 1.1)
    #expect(ProfileControlLook.keyScale(isFocused: true, isEnabled: false) == 1)
  }

  private func source(_ relative: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { url.deleteLastPathComponent() }
    url.appendPathComponent("DSM Video/DSM Video/\(relative)")
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The text of one `private struct <name>` up to the next top-level declaration.
  private func body(of name: String, in text: String) throws -> String {
    let start = try #require(text.range(of: "private struct \(name)"))
    let rest = text[start.lowerBound...]
    let end = rest.dropFirst(20).range(of: "\n}\n")?.upperBound ?? rest.endIndex
    return String(rest[..<end])
  }

  @Test func bothStylesReadIsEnabledAndDrawFromTokens() throws {
    let views = try source("Views/ProfileViews.swift")
    let pin = try body(of: "PinKeyStyle", in: views)
    let tile = try body(of: "ProfileTileButtonStyle", in: views)
    for (label, text) in [("PinKeyStyle", pin), ("ProfileTileButtonStyle", tile)] {
      #expect(text.contains("@Environment(\\.isEnabled)"), "\(label) reads isEnabled")
      #expect(text.contains("ProfileControlLook.opacity(isEnabled: isEnabled)"), "\(label) dims from the shared look")
    }
    #expect(!pin.contains("Color.black") && !pin.contains("Color.white"), "PIN key colours come from tokens")
  }

  @Test func theKeypadIsDisabledWhileThePinIsVerified() throws {
    let views = try source("Views/ProfileViews.swift")
    let pad = try #require(views.range(of: "private var keypad: some View"))
    let tail = String(views[pad.lowerBound...].prefix(1500))
    #expect(tail.contains(".disabled(busy)"))
  }
}
