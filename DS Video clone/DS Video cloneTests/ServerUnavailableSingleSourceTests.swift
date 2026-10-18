import Foundation
import Testing
@testable import DSM_Video

// MARK: - One "the server cannot be reached" rule (TASK-1022 · FRD-001 FR-071, FR-133)
//
// `isOffline || serverUnreachable` was written out in AppState (seven times) and in four views, each
// a chance to be changed in one place and not another. The rule lives in `AppState.serverUnavailable`
// (and `appState.isServerUnavailable`); this file pins the rule and fails if an inline copy returns.

struct ServerUnavailableRuleTests {

  @Test(arguments: [
    (false, false, false),
    (true, false, true),
    (false, true, true),
    (true, true, true),
  ])
  func theRuleIsEitherFlag(flags: (Bool, Bool, Bool)) {
    #expect(AppState.serverUnavailable(isOffline: flags.0, serverUnreachable: flags.1) == flags.2)
  }

  @MainActor
  @Test func theInstancePropertyFollowsBothFlags() async {
    await withIsolatedAppState { state in
      #expect(!state.isServerUnavailable)
      state.isOffline = true
      #expect(state.isServerUnavailable)
      state.isOffline = false
      state.serverUnreachable = true
      #expect(state.isServerUnavailable)
      state.serverUnreachable = false
      #expect(!state.isServerUnavailable)
    }
  }

  /// The Play gate keeps its signature and answers through the same rule.
  @Test func playIsUnavailableWhenTheServerIsAndTheTitleIsNotDownloaded() {
    #expect(ItemDetailView.playUnavailableOffline(serverUnreachable: false, isOffline: true, isDownloaded: false))
    #expect(ItemDetailView.playUnavailableOffline(serverUnreachable: true, isOffline: false, isDownloaded: false))
    #expect(!ItemDetailView.playUnavailableOffline(serverUnreachable: true, isOffline: true, isDownloaded: true))
    #expect(!ItemDetailView.playUnavailableOffline(serverUnreachable: false, isOffline: false, isDownloaded: false))
  }
}

/// Reads every app source file: fails if the two flags are combined by hand anywhere but the one
/// definition.
struct ServerUnavailableSingleSourceTests {

  private static let appSourceDirectory: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()           // DS Video cloneTests
    .deletingLastPathComponent()           // DS Video clone
    .appendingPathComponent("DSM Video/DSM Video", isDirectory: true)

  /// `isOffline || serverUnreachable`, `serverUnreachable && !isOffline`, and the comma form of a
  /// `guard !isOffline, !serverUnreachable`, with or without a receiver (`appState.isOffline`).
  private static let inlinePairs: [NSRegularExpression] = [
    #"\bisOffline\b\s*(\|\||&&)\s*!?\s*[\w.]*\bserverUnreachable\b"#,
    #"\bserverUnreachable\b\s*(\|\||&&)\s*!?\s*[\w.]*\bisOffline\b"#,
    #"!\s*[\w.]*\bisOffline\b\s*,\s*!\s*[\w.]*\bserverUnreachable\b"#,
    #"!\s*[\w.]*\bserverUnreachable\b\s*,\s*!\s*[\w.]*\bisOffline\b"#,
  ].map { try! NSRegularExpression(pattern: $0) }  // swiftlint:disable:this force_try

  private struct Hit: CustomStringConvertible {
    let file: String
    let line: Int
    let text: String
    var description: String { "\(file):\(line): \(text)" }
  }

  private func inlineCopies() throws -> [Hit] {
    let manager = FileManager.default
    guard let walker = manager.enumerator(at: Self.appSourceDirectory, includingPropertiesForKeys: nil) else {
      Issue.record("cannot read \(Self.appSourceDirectory.path)")
      return []
    }
    var hits: [Hit] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      for (index, raw) in text.components(separatedBy: "\n").enumerated() {
        // Code only: a comment may name the rule it replaced.
        let code = raw.components(separatedBy: "//").first ?? raw
        let range = NSRange(code.startIndex..., in: code)
        if Self.inlinePairs.contains(where: { $0.firstMatch(in: code, range: range) != nil }) {
          hits.append(Hit(file: url.lastPathComponent, line: index + 1,
                          text: raw.trimmingCharacters(in: .whitespaces)))
        }
      }
    }
    return hits
  }

  /// The one allowed combination is the definition itself.
  @Test func onlyTheDefinitionCombinesTheTwoFlags() throws {
    let hits = try inlineCopies()
    #expect(hits.count == 1, "expected only AppState.serverUnavailable, found: \(hits)")
    #expect(hits.first?.file == "AppState.swift")
    #expect(hits.first?.text == "isOffline || serverUnreachable")
  }
}
