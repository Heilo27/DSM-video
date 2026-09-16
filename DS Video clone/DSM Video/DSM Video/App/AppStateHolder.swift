import Foundation

/// Process-wide handle on the live `AppState`, for code that runs OUTSIDE the view tree.
///
/// App Intents are the reason this exists. Siri performs an intent in the app's process but
/// with no SwiftUI environment — there is no `@Environment(AppState.self)` to read, and the
/// scene's `@State private var appState` is not reachable from a struct the system
/// instantiates itself. The intent still needs the signed-in API client and the deep-link
/// property, so something has to bridge them.
///
/// Deliberately a weak reference. `AppState` is owned by the scene for the app's lifetime;
/// a strong reference here would make that ownership ambiguous and keep a dead state alive
/// across a scene teardown. Weak means this is a *handle on whatever is live*, and reads
/// nil when nothing is — which intents already handle, because "not signed in yet" is the
/// same nil and the same user-visible answer.
///
/// Same shape as `ThemeHolder` on purpose: one holder, one owner, set once at scene setup.
@MainActor
final class AppStateHolder {
  private static weak var instance: AppState?

  /// The live state, or nil before the scene has built one.
  static var shared: AppState? { instance }

  /// Called once, by the scene that owns the state.
  static func register(_ state: AppState) {
    instance = state
  }
}
