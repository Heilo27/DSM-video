import Foundation

/// Stable accessibility identifiers for UI testing.
///
/// WHY THIS EXISTS
/// ---------------
/// Before this file the app had ZERO accessibility identifiers across ~23K lines, so the only
/// way a UI test could find a control was by its visible label. That makes every test hostage
/// to copy edits: rewording a button breaks the suite, and — worse — a test that silently
/// stops finding its element reports success having verified nothing. Two P0s shipped in the
/// 1.3.6 cycle (every download writing a 22-byte error body; the player's error screen being
/// inescapable) precisely because no automated test could reach those controls.
///
/// RULES
/// -----
/// 1. Identifiers are API. Never rename one to match new UI copy — tests depend on it.
/// 2. `accessibilityIdentifier` is for TESTS. `accessibilityLabel` is for VOICEOVER. Setting an
///    identifier never replaces a label, and a label is never a substitute for an identifier.
/// 3. Add the identifier in the same commit as the control. A control without one cannot be
///    asserted on, which is how a dead control survives review.
/// 4. Anything a user taps on a money path — playback, downloads, login, a destructive action —
///    MUST have one.
enum A11y {

  // MARK: - Server setup / login

  enum Setup {
    static let addressField = "setup.address"
    static let usernameField = "setup.username"
    static let passwordField = "setup.password"
    static let connectButton = "setup.connect"
    static let errorText = "setup.error"
    static let revealPasswordButton = "setup.revealPassword"
    /// Keyboard-accessory Done. The only way to reach Connect once the keyboard is up
    /// and the form is too short to scroll (TASK-906).
    static let keyboardDoneButton = "setup.keyboardDone"
  }

  // MARK: - Main navigation

  /// The five tabs in MainView's TabView, in order.
  ///
  /// THESE DO NOT REACH THE TAB BUTTONS, AND CANNOT — address a tab by its LABEL instead
  /// (`app.buttons["Home"]`). SwiftUI's system tab bar does not expose
  /// accessibilityIdentifier on the tab button on this OS. Measured on iOS 26: a captured UI
  /// hierarchy shows all five buttons rendered with correct labels and zero identifier
  /// attributes, and three placements were tried — on the Label inside .tabItem (what
  /// MainView still does), on the content view, and via the iOS 18 Tab(_:systemImage:) API —
  /// all giving identifier(tab.home)=false. It is not a placement problem. TASK-909.
  ///
  /// Kept rather than deleted because MainView applies them and they cost nothing; if a
  /// future SDK starts propagating them, the wiring is already in place. Do not write a test
  /// that looks a tab up by these — that is how testTabIdentifierMirrorIsComplete came to
  /// report success for years while addressing nothing.
  ///
  /// (Historical: `shows` was also stale — there is no Shows tab. Search moved into each
  /// library's toolbar and the fifth slot is Watchlist.)
  enum Tab {
    static let home = "tab.home"
    static let libraries = "tab.libraries"
    static let downloads = "tab.downloads"
    static let watchlist = "tab.watchlist"
    static let settings = "tab.settings"
  }

  // MARK: - Item detail

  enum Detail {
    static let playButton = "detail.play"
    static let fromBeginningButton = "detail.fromBeginning"
    static let watchlistButton = "detail.watchlist"
    static let markWatchedButton = "detail.markWatched"
    static let downloadButton = "detail.download"
    static let nextEpisodeButton = "detail.nextEpisode"
    static let downloadError = "detail.downloadError"
    static let title = "detail.title"
  }

  // MARK: - Player

  enum Player {
    static let root = "player.root"
    static let errorOverlay = "player.errorOverlay"
    static let errorRetryButton = "player.error.retry"
    static let errorDismissButton = "player.error.dismiss"
    static let playPauseButton = "player.playPause"
    static let closeButton = "player.close"
    static let scrubber = "player.scrubber"
  }

  // MARK: - Downloads

  enum Downloads {
    static let list = "downloads.list"
    static let emptyState = "downloads.empty"
    /// Row for a completed download. Suffix with the item id.
    static func row(_ itemID: String) -> String { "downloads.row.\(itemID)" }
    /// Failure row carrying a retry affordance. Suffix with the item id.
    static func failedRow(_ itemID: String) -> String { "downloads.failed.\(itemID)" }
    static let retryButton = "downloads.retry"
  }

  // MARK: - Shared

  enum Shared {
    /// The empty-state container. A screen showing this when a fetch FAILED (rather than when
    /// there is genuinely nothing) is the "state that lies" defect — tests assert on which of
    /// these two is presented, so they must be distinguishable.
    static let emptyState = "shared.emptyState"
    static let errorState = "shared.errorState"
    static let retryButton = "shared.retry"
    static let offlineBanner = "shared.offlineBanner"
    static let loadingIndicator = "shared.loading"
  }
}
