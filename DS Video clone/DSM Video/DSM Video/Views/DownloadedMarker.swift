import SwiftUI

// FR-041 / FR-133 / FR-134 (TASK-983): which titles are playable from local storage, shown on
// the cards and rows that list them. iOS only: tvOS has no download surface (FR-030's Downloads
// UI is not built there), so nothing on tvOS asks for this.
//
// One home for the rule. The state comes from `DownloadManager.playableDownloadedItem`
// (FR-043/FR-262: on disk AND allowed for the active profile), read in the view body so the
// manager's observed manifest cache re-renders the card the moment a download completes or is
// deleted, with no relaunch.

/// What a card or row says about its title's local copy.
enum DownloadBadgeState: Equatable, Sendable {
  /// Online and not downloaded: nothing to say.
  case none
  /// Playable from local storage.
  case downloaded
  /// The server cannot be reached and there is no local copy: Play is unavailable (FR-133).
  case unavailableOffline
}

extension DownloadManager {
  /// ONE mapping from (local copy, reachability) to what is drawn, so every card agrees.
  func badgeState(for itemId: String, offline: Bool) -> DownloadBadgeState {
    if playableDownloadedItem(itemId: itemId) != nil { return .downloaded }
    return offline ? .unavailableOffline : .none
  }
}

extension AppState {
  /// The server cannot be reached right now (explicitly offline, or a failed reach).
  var isServerUnavailable: Bool { isOffline || serverUnreachable }
}

#if !os(tvOS)
/// The small "downloaded" mark. Decorative; the state is spoken through the card's value.
struct DownloadedGlyph: View {
  var size: CGFloat = 18

  var body: some View {
    Image(systemName: "arrow.down.circle.fill")
      .font(.system(size: size * 0.85, weight: .semibold))
      .symbolRenderingMode(.palette)
      .foregroundStyle(.black, Color.dsSuccess)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// Inline form for list rows that lay the mark out in their own HStack.
struct DownloadedRowGlyph: View {
  let itemID: String

  var body: some View {
    // Reachability is irrelevant to "is it downloaded", so the offline flag is fixed.
    if DownloadManager.shared.badgeState(for: itemID, offline: false) == .downloaded {
      DownloadedGlyph(size: 20)
    }
  }
}

private struct DownloadStatusModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  let itemID: String
  let showsBadge: Bool

  func body(content: Content) -> some View {
    let state = DownloadManager.shared.badgeState(for: itemID, offline: appState.isServerUnavailable)
    content
      // Dimmed, not hidden: the title page still opens and explains itself (FR-133).
      .opacity(state == .unavailableOffline ? 0.45 : 1)
      .overlay(alignment: .topLeading) {
        // Skipped on thumbnails too small to carry it (search-result strips).
        if showsBadge && state == .downloaded {
          GeometryReader { geo in
            if geo.size.width >= 80 {
              DownloadedGlyph().padding(6)
            }
          }
        }
      }
      .accessibilityValue(Text(Self.spoken(state)))
  }

  private static func spoken(_ state: DownloadBadgeState) -> String {
    switch state {
    case .none: return ""
    case .downloaded: return "Downloaded"
    case .unavailableOffline: return "Not available offline"
    }
  }
}

extension View {
  /// Marks a card or row for its title's local copy. `showsBadge: false` for rows that draw
  /// their own `DownloadedGlyph` inline.
  func downloadStatus(itemID: String, showsBadge: Bool = true) -> some View {
    modifier(DownloadStatusModifier(itemID: itemID, showsBadge: showsBadge))
  }
}
#endif
