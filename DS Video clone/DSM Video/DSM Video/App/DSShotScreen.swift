import SwiftUI
import os.log

// DEBUG-only screen selector for design-evidence screenshots. The whole file is compiled out of
// Release, and the one call site in RootView is inside `#if DEBUG`.
//
// Why it exists: the headless simulators here have no Simulator.app, so nothing can tap its way
// to a screen. `simctl openurl` is not a way round it: it leaves an "Open in DSM Video?" dialog
// over the screen it opens. This lets a launch argument pick the screen instead:
//
//   xcrun simctl launch <udid> <bundle> -UITestDemoMode -UITestResetState \
//       -dsReel.theme cinematic -DSShotScreen movieDetail
//
// Screens: home | movieDetail | showDetail | moviesGrid | showsGrid. Inert without the argument,
// and inert outside demo mode (the content it shows is DemoData). `scripts/capture-screen.sh`
// drives it end to end.
//
// "Ready" means loaded content, not a skeleton. The screen is not shown until the demo data it
// reads exists, and the ready line below is logged only after it has been on screen long enough
// to run its own load. A screen whose data is missing logs a failure instead of a ready line, so
// a capture can never be taken of a placeholder and passed off as the real thing.

#if DEBUG

private let shotLog = Logger(subsystem: "com.dsm.shot", category: "screen")

enum ShotScreen: String {
  case home
  case movieDetail
  case showDetail
  case moviesGrid
  case showsGrid

  /// The screen named by `-DSShotScreen <name>`, or nil when absent. An unknown name is logged
  /// rather than ignored, so a typo reads as a typo and not as a capture of Home.
  static var requested: ShotScreen? {
    let args = ProcessInfo.processInfo.arguments
    guard let flag = args.firstIndex(of: "-DSShotScreen"), args.index(after: flag) < args.endIndex else {
      return nil
    }
    let name = args[args.index(after: flag)]
    guard let screen = ShotScreen(rawValue: name) else {
      shotLog.error("DSShotScreen unknown screen '\(name, privacy: .public)'")
      return nil
    }
    return screen
  }

  // Demo items the screens show. Fixed so a shot is the same shot every time.
  private static let movieID = "dm-1"
  private static let showID = "ds-2"

  /// Whether the demo data this screen reads is there. The demo loads are synchronous, so this
  /// is what "content, not skeleton" means here: no data, no ready line.
  var hasContent: Bool {
    switch self {
    case .home: return !DemoData.movieItems.isEmpty
    case .movieDetail: return DemoData.detail(for: Self.movieID) != nil
    case .showDetail: return !(DemoData.tvSeasons[Self.showID] ?? []).isEmpty && show != nil
    case .moviesGrid: return !DemoData.movieItems.isEmpty
    case .showsGrid: return !DemoData.tvShows.isEmpty
    }
  }

  private var show: TVShow? { DemoData.tvShows.first { $0.id == Self.showID } }

  @ViewBuilder
  var target: some View {
    switch self {
    case .home:
      EmptyView()
    case .movieDetail:
      NavigationStack { ItemDetailView(itemID: Self.movieID, fallbackTitle: "") }
    case .showDetail:
      if let show {
        NavigationStack { TVShowDetailView(show: show, library: DemoData.libraries[1]) }
      }
    case .moviesGrid:
      NavigationStack { ItemsGridView(library: DemoData.libraries[0]) }
    case .showsGrid:
      NavigationStack { TVShowsView(library: DemoData.libraries[1]) }
    }
  }
}

private struct ShotScreenHost: ViewModifier {
  @Environment(AppState.self) private var appState
  @State private var presented = false

  /// How long a screen is on view before it counts as ready: long enough for its own `.task`
  /// load and first layout to land.
  private static let settle: Duration = .milliseconds(1200)
  /// Home is the screen under the launch animation (about 2.4 s), so it waits that out.
  private static let launchAnimation: Duration = .milliseconds(3200)

  func body(content: Content) -> some View {
    content.overlay {
      if presented, let screen = ShotScreen.requested {
        // Opaque, so nothing behind it (home rails, launch overlay) shows through.
        ZStack {
          Color.dsBackground.ignoresSafeArea()
          screen.target.environment(appState)
        }
      }
    }
    .task { await run() }
  }

  private func run() async {
    guard let screen = ShotScreen.requested else { return }
    // Only demo content is guaranteed to be here; a real session is not this hook's business.
    var waited = 0
    while !appState.isDemoMode, waited < 100 {
      try? await Task.sleep(for: .milliseconds(100))
      waited += 1
    }
    guard appState.isDemoMode else {
      shotLog.error("DSShotScreen \(screen.rawValue, privacy: .public) FAILED not in demo mode (add -UITestDemoMode)")
      return
    }
    guard screen.hasContent else {
      shotLog.error("DSShotScreen \(screen.rawValue, privacy: .public) FAILED no demo content")
      return
    }
    if screen == .home {
      try? await Task.sleep(for: Self.launchAnimation)
    } else {
      presented = true
      try? await Task.sleep(for: Self.settle)
    }
    shotLog.notice("DSShotScreen \(screen.rawValue, privacy: .public) READY")
  }
}

extension View {
  /// Applied once, at the root, inside `#if DEBUG`.
  func dsShotScreen() -> some View { modifier(ShotScreenHost()) }
}

#endif
