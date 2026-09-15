import Foundation

/// A collection element paired with its position, so a list can never lose an element to a
/// duplicate identity.
///
/// THE PROBLEM THIS SOLVES
/// ----------------------
/// SwiftUI's `ForEach` is keyed on identity. When two elements produce the same key, it does
/// not render both — it collapses them, and which one survives depends on scroll position.
/// The user sees a blank cell, or a missing row, or a row that flickers between two values.
/// Nothing logs, nothing throws, and the damage often lands on a NEIGHBOUR of the duplicate
/// rather than on the duplicate itself, so the visible symptom points at the wrong data.
///
/// That happened here twice, with different collision shapes:
///
///   1. Two distinct shows sharing one folder, so they shared `id`. Patched by keying on a
///      composite of id + title (`gridID`).
///   2. A part-matched folder emitting two entries with the same id AND the same title, so
///      the composite collided as well. Four shows duplicated and — because the collision
///      corrupts the rows around it — Star Trek: The Next Generation disappeared entirely
///      from a real Apple TV despite the server holding all 176 episodes and a valid poster.
///
/// The second one is why this type exists rather than a third composite. Every fix of that
/// shape is a guess about which fields will be unique next time, and the server can always
/// send two rows that agree on all of them. A key derived from CONTENT can collide; a key
/// derived from POSITION cannot.
///
/// WHAT THIS GUARANTEES
/// --------------------
/// `offset` is unique within one enumeration by construction, so `ForEach` renders exactly
/// as many cells as the array has elements — always. Duplicate server data may then be
/// visible to the user as a repeated row, which is a data problem worth seeing and fixing.
/// It can no longer be INVISIBLE, which is what made this take a device report to find.
///
/// Identity is positional, so it is stable only within one array. That is the correct
/// trade-off for a rendered list: the list is rebuilt when its data changes anyway, and a
/// wrong-but-unique key costs an unnecessary redraw, while a duplicated key costs a missing
/// show. Do not use this to key persistent state across reloads.
// nonisolated: a pure value pairing, usable from any context. Without it the
// project's default main-actor isolation makes it unusable from a nonisolated test.
nonisolated struct Identified<Element>: Identifiable {
  let id: Int
  let value: Element

  init(offset: Int, value: Element) {
    self.id = offset
    self.value = value
  }
}

extension Identified: Equatable where Element: Equatable {}
extension Identified: Hashable where Element: Hashable {}

nonisolated extension Collection {
  /// Pairs each element with its offset for rendering.
  ///
  /// Use this wherever a `ForEach` would otherwise key on a field that came from the server:
  ///
  ///     ForEach(shows.identified) { item in
  ///       ShowCell(show: item.value)
  ///     }
  ///
  /// Prefer it over `ForEach(_:id:)` with a content-derived key, and over
  /// `Array(enumerated())` with `id: \.offset`, which reads as if it were safe but leaves
  /// the key choice to the next person who edits the line.
  var identified: [Identified<Element>] {
    enumerated().map { Identified(offset: $0.offset, value: $0.element) }
  }
}

/// Decides when a local delta-sync cursor has run ahead of the server's.
///
/// A local cursor can only ever LAG the server. When it leads, both delta gates in
/// runDeltaSync (`status.seq > cursors.seq`) are false forever: the client stops fetching
/// item deltas entirely, new shows and episodes never appear again, and nothing surfaces —
/// progress keeps syncing on its own cursor, so the app looks healthy while going stale.
///
/// Observed on a real device: iOS held itemSeq 348155 against a server at 13789, and the
/// server advanced 115 changes that were never fetched.
///
/// The cause is server-side: a rebuilt or restored database restarts the sequence counter.
/// The client cannot prevent that, only refuse to be wedged by it.
///
/// Extracted from AppState purely so the rule is testable without a database or a live
/// server — the predicate is the part that has to be right.
nonisolated enum SyncCursorClamp {
  /// True when EITHER cursor leads its server counterpart.
  ///
  /// Either alone is enough: the two cursors gate different fetches, so one being ahead
  /// stalls its own delta stream regardless of the other.
  static func isAhead(localItem: Int, localProgress: Int, serverItem: Int, serverProgress: Int) -> Bool {
    localItem > serverItem || localProgress > serverProgress
  }

  static func isAhead(local: SyncCursors, server: SyncStatusResponse) -> Bool {
    isAhead(localItem: local.itemSeq, localProgress: local.progressSeq,
            serverItem: server.itemSeq, serverProgress: server.progressSeq)
  }
}
