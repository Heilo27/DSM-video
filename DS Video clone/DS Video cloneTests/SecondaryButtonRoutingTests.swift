import Foundation
import Testing
@testable import DSM_Video

// TASK-1050. The quiet action beside a primary one has one style, `dsSecondaryButton`, drawn from
// tokens only. Four sites used to hand-roll it with a system `.borderedProminent` / `.bordered`
// plus a tint; this pins that each one goes through the style, and that the style itself reaches
// for no literal colour. Source scans, in the style of ProfileControlLookTests: how the style
// looks on a device is a device check, but "this site stopped using it" is mechanical.
// Red before the change: the style did not exist and all four sites used system styles.

@Suite("Secondary button routing")
struct SecondaryButtonRoutingTests {

  private func source(_ relative: String) throws -> [String] {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { url.deleteLastPathComponent() }
    url.appendPathComponent("DSM Video/DSM Video/\(relative)")
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
  }

  /// The Button that opens at the first line containing `anchor`, through its modifiers: from the
  /// line holding `opener` (searched back from the anchor) up to the next Button.
  private func site(in lines: [String], opener: String, anchor: String) throws -> String {
    let anchorAt = try #require(lines.firstIndex { $0.contains(anchor) }, "anchor \(anchor) not found")
    let start = try #require(lines[...anchorAt].lastIndex { $0.contains(opener) }, "\(opener) not found")
    var end = start + 1
    while end < lines.count, end - start < 24 {
      if end > anchorAt, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("Button") { break }
      end += 1
    }
    return lines[start..<end].joined(separator: "\n")
  }

  private struct Site {
    let name: String
    let file: String
    let opener: String
    let anchor: String
  }

  private let sites: [Site] = [
    Site(name: "profile Done", file: "Views/ProfileViews.swift",
         opener: "Button(\"Done\", action: close)", anchor: "Button(\"Done\", action: close)"),
    Site(name: "pairing Generate New Code", file: "Views/TVPairingView.swift",
         opener: "Button {", anchor: "Text(\"Generate New Code\")"),
    Site(name: "home Sign Out", file: "Views/TVMainView.swift",
         opener: "Button {", anchor: "Label(\"Sign Out\""),
    Site(name: "iOS rail Retry", file: "Views/CollectionViews.swift",
         opener: "Button {", anchor: "Task { await appState.loadCollections() }"),
  ]

  @Test func everySecondarySiteUsesTheStyleAndNoSystemStyle() throws {
    for s in sites {
      let text = try site(in: try source(s.file), opener: s.opener, anchor: s.anchor)
      #expect(text.contains(".dsSecondaryButton("), "\(s.name) uses dsSecondaryButton")
      #expect(!text.contains(".borderedProminent"), "\(s.name) has no .borderedProminent")
      #expect(!text.contains(".buttonStyle(.bordered)"), "\(s.name) has no .bordered")
      #expect(!text.contains(".tint("), "\(s.name) is not re-tinted by hand")
    }
  }

  @Test func theTvOSSitesBindFocus() throws {
    let binds: [(file: String, anchor: String, bound: String)] = [
      ("Views/ProfileViews.swift", "Button(\"Done\", action: close)", ".focused($focusedControl, equals: .done)"),
      ("Views/TVPairingView.swift", "Text(\"Generate New Code\")", ".focused($control, equals: .generateNew)"),
      ("Views/TVMainView.swift", "Label(\"Sign Out\"", ".focused($homeControl, equals: .signOut)"),
    ]
    for b in binds {
      let lines = try source(b.file)
      let opener = b.anchor.hasPrefix("Button") ? b.anchor : "Button {"
      let text = try site(in: lines, opener: opener, anchor: b.anchor)
      #expect(text.contains(b.bound), "\(b.file) binds \(b.bound)")
    }
  }

  @Test func theStyleDrawsFromTokensOnly() throws {
    let code = try source("App/DSSecondaryButton.swift")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    #expect(code.contains("private struct DSSecondaryButtonStyle"))
    #expect(code.contains("Color.dsSurfaceRaised") && code.contains("Color.dsTextPrimary"))
    for literal in ["Color.white", "Color.black", ".white", ".black", "Color(", "UIColor", "NSColor", ".tint("] {
      #expect(!code.contains(literal), "the secondary style uses a literal colour: \(literal)")
    }
  }

  @Test func theFocusCheckKnowsTheNewStyle() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    url.appendPathComponent("scripts/check-tvos-focus.sh")
    let script = try String(contentsOf: url, encoding: .utf8)
    #expect(script.contains("'dsSecondaryButton' in chain"),
            "an unbound dsSecondaryButton must fail check_focus the way an unbound dsPrimaryButton does")
  }
}
