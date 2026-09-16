import AppIntents
import Foundation

// Siri / App Intents surface.
//
// WHAT SIRI CAN AND CANNOT DO HERE — read this before extending.
//
// On tvOS the Siri button's bare "play Blade Runner" goes to Apple's TV app and its
// Universal Search partners. That is a content-catalog partnership, not an API: no amount
// of code makes a third-party app a candidate for an unscoped query. What a third-party app
// gets is APP-SCOPED phrasing — "play Blade Runner in DSM Video", "find Blade Runner in
// DSM Video" — which routes here. The app name is part of the utterance, not optional.
//
// Two intents, because Siri distributes two different user goals:
//   PlayItemIntent   ("play X")  — resolves to ONE item and opens it.
//   FindItemIntent   ("find X")  — a search surface; shows results.
// Both open the app, because there is nothing useful to show without it.
//
// NEITHER STARTS PLAYBACK. Both land on the item's DETAIL page, which is what was asked
// for: Ryan's request is "open it to that video's detail page". PlayVideoIntent's name is
// Apple's, describing the user's phrasing, not a promise that we hit play. Resuming
// mid-item from a voice command with no visible position is a good way to lose someone's
// place, and the detail screen already has Play as its default-focused button.

/// The item a media intent resolved to, handed to the UI through the existing deep-link path.
///
/// Reuses `AppState.pendingDeepLinkItemID` rather than adding a parallel channel. That
/// property already survives the cold-launch race the Top Shelf hit — TVMainView reads it
/// from BOTH `.onChange` and `.task`, because an intent or a Top Shelf tile can set it
/// before the view exists, and an `.onChange` alone silently drops that. A second mechanism
/// would have to re-learn the same lesson.
@MainActor
enum MediaIntentRouter {
  /// Resolve a spoken term to one item id, newest-relevance first.
  ///
  /// Returns nil when nothing matches, so the caller can tell Siri plainly rather than
  /// opening the app to an arbitrary screen.
  static func resolveItemID(for term: String) async -> (id: String, title: String)? {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    guard let state = AppStateHolder.shared else { return nil }

    // Demo mode has no server, and the search screen already resolves it locally — match
    // that, or every intent fails on a demo build and the failure looks like a Siri bug.
    if state.isDemoMode {
      let pool = DemoData.movieItems + DemoData.tvItems
      let hits = pool.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
      return bestMatch(for: trimmed, in: hits).map { ($0.id, $0.title) }
    }

    // The SERVER does the matching. It holds the library; the client holds a mirror that
    // may be mid-sync, and a rail that renders confidently stale content is the exact
    // failure this project already paid for once (see the Just Added rewrite). There is no
    // local search API to fall back to, so a network failure returns nil and the caller
    // tells the user plainly rather than opening something arbitrary.
    guard state.sessionToken != nil else { return nil }
    guard let remote = try? await state.api.search(query: trimmed, limit: 10) else { return nil }
    return bestMatch(for: trimmed, in: remote.items).map { ($0.id, $0.title) }
  }

  /// Pick the best of several matches.
  ///
  /// Speech recognition returns a phrase, not an id, and the server's search is a substring
  /// match that happily returns "Blade Runner 2049" for "Blade Runner". Prefer an exact
  /// case-insensitive title hit before falling back to the server's own ordering, so saying
  /// a film's exact name opens that film rather than its sequel.
  static func bestMatch(for term: String, in items: [ItemSummary]) -> ItemSummary? {
    guard !items.isEmpty else { return nil }
    let needle = term.lowercased()
    if let exact = items.first(where: { $0.title.lowercased() == needle }) {
      return exact
    }
    if let prefixed = items.first(where: { $0.title.lowercased().hasPrefix(needle) }) {
      return prefixed
    }
    return items.first
  }

  /// Route to the item's detail page via the established deep-link property.
  static func open(itemID: String) {
    AppStateHolder.shared?.pendingDeepLinkItemID = itemID
  }

  /// Route to the search screen with a pre-filled term.
  static func openSearch(term: String) {
    AppStateHolder.shared?.pendingSearchTerm = term
  }
}

// MARK: - "Play X in DSM Video"

@available(tvOS 17.2, iOS 17.2, *)
struct PlayItemIntent: AppIntent, PlayVideoIntent {
  static let title: LocalizedStringResource = "Play a Video"
  static let description = IntentDescription(
    "Finds a movie or show in your library and opens it.",
    categoryName: "Playback"
  )

  /// Both, because the library is both. Omitting one makes Siri decline those queries.
  static let supportedCategories: [VideoCategory] = [.movies, .tv]

  /// The spoken title. `PlayVideoIntent` requires this exact property name.
  @Parameter(title: "Title")
  var term: String

  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let match = await MediaIntentRouter.resolveItemID(for: term) else {
      // Fall back to the search screen rather than failing silently. A miss is usually a
      // near-miss — speech heard "Blade Runner" as "Blade Runner 20" — and showing the
      // search results beats dumping the user on Home with no explanation.
      MediaIntentRouter.openSearch(term: term)
      throw MediaIntentError.noMatch(term)
    }
    MediaIntentRouter.open(itemID: match.id)
    return .result()
  }
}

// MARK: - "Find X in DSM Video"

@available(tvOS 17.2, iOS 17.2, *)
struct FindItemIntent: AppIntent, ShowInAppSearchResultsIntent {
  static let title: LocalizedStringResource = "Search the Library"
  static let description = IntentDescription(
    "Searches your library for movies and shows.",
    categoryName: "Search"
  )

  /// The kinds of thing this app can be asked to search. Both, because the library is both;
  /// omitting one makes Siri decline those queries outright.
  static let searchScopes: [StringSearchScope] = [.movies, .tv]

  @Parameter(title: "Search Term")
  var criteria: StringSearchCriteria

  @MainActor
  func perform() async throws -> some IntentResult {
    MediaIntentRouter.openSearch(term: criteria.term)
    return .result()
  }
}

// MARK: - Errors

enum MediaIntentError: Error, CustomLocalizedStringResourceConvertible {
  case noMatch(String)

  /// Siri SPEAKS this, so it is a sentence, not a log line. It also says what happened next
  /// (the search screen is open), because a voice error that does not say what to do leaves
  /// the user staring at a TV.
  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .noMatch(let term):
      return "I couldn't find \(term) in your library. I've opened a search so you can look."
    }
  }
}

// MARK: - Why there is no AppShortcutsProvider here
//
// The obvious next step is an AppShortcutsProvider declaring phrases like
// "Play \(\.$term) in \(.applicationName)". It does not compile, and the reason is worth
// recording so nobody re-adds it:
//
//   error: 'AppEntity' and 'AppEnum' are the only allowed types for 'term'
//
// A shortcut phrase slot must be a type Siri can enumerate and disambiguate against — an
// AppEntity or AppEnum with known values. A free-text String cannot be a slot, because
// there is no candidate set to match speech against.
//
// That is fine, because these two do not need it. PlayVideoIntent and
// ShowInAppSearchResultsIntent are SYSTEM intents: Siri already owns the phrasings for
// "play X in <app>" and "find X in <app>", and routes them to whichever installed app
// conforms. Declaring our own phrases would duplicate that, not extend it.
//
// The route to arbitrary-title phrases WITHOUT the system intents would be an AppEntity
// backed by an EntityQuery over the library, which Siri indexes. That is a much larger
// change — it publishes titles to the system index — and it is not needed for the asked-for
// behaviour. Measure before building it.
