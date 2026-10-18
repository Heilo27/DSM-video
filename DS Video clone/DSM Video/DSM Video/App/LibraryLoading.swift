import Foundation

// MARK: - How a failed library load is presented (FRD-001 FR-098, TASK-975)

/// What to show when a load fails. One home for the rule, shared by the Libraries list and the
/// library grid so neither can drift back to wiping loaded content.
///
/// - `blocking`: there is nothing trustworthy to show. Full-screen error with Retry.
/// - `notice`: the content on screen is still a correct answer to what the user asked for. It
///   stays; a non-blocking "couldn't refresh" notice with Retry sits above it.
enum LoadFailurePresentation: Equatable, Sendable {
  case blocking(String)
  case notice(String)

  /// - Parameters:
  ///   - hasContent: something is already loaded.
  ///   - contentMatchesRequest: that content answers the request that just failed. A grid left
  ///     over from a different genre filter does NOT: keeping it would present the unfiltered
  ///     list as the filtered result.
  static func decide(hasContent: Bool, contentMatchesRequest: Bool = true,
                     message: String) -> LoadFailurePresentation {
    hasContent && contentMatchesRequest ? .notice(message) : .blocking(message)
  }

  /// Copy for the non-blocking notice (shared by iOS and tvOS).
  static let noticeTitle = "Couldn't refresh"
}

// MARK: - The genre selection a grid is showing

/// The server-side filter a grid's items were fetched with. Compared with the filter the user has
/// selected now to tell whether the grid on screen is still the answer to the current chips.
struct GenreSelection: Equatable, Sendable {
  let genres: Set<String>
  let mode: APIClient.GenreMode

  /// The mode only changes the result with two or more genres (see ItemsGridView's onChange), so a
  /// single genre or none compares equal whatever the mode says.
  init(genres: Set<String>, mode: APIClient.GenreMode) {
    self.genres = genres
    self.mode = genres.count >= 2 ? mode : .any
  }
}

// MARK: - What the Libraries list and the library grid hold, and how a load result changes it

/// The words shown for a failed load (`APIError` carries user-facing copy; anything else does not).
func loadFailureMessage(_ error: any Error) -> String {
  (error as? APIError)?.userMessage ?? "Unknown error."
}

/// The Libraries list: what is loaded and how the last load failed, if it did.
struct LibraryListContent {
  var libraries: [Library] = []
  var failure: LoadFailurePresentation?

  /// Full-screen error: only when there is no list to keep (FR-098).
  var blockingError: String? {
    if case .blocking(let message)? = failure { return message }
    return nil
  }

  /// Non-blocking notice above the kept list.
  var noticeMessage: String? {
    if case .notice(let message)? = failure { return message }
    return nil
  }

  mutating func finish(_ result: Result<[Library], any Error>) {
    switch result {
    case .success(let loaded):
      libraries = loaded
      failure = nil
    case .failure(let error):
      // The loaded list is never cleared by a failed refresh.
      failure = .decide(hasContent: !libraries.isEmpty, message: loadFailureMessage(error))
    }
  }
}

/// A library grid: its items, the library and genre filter they answer, and the last failure.
struct LibraryGridContent {
  var items: [ItemSummary] = []
  private(set) var appliedSelection = GenreSelection(genres: [], mode: .any)
  private(set) var appliedLibraryID: String?
  var failure: LoadFailurePresentation?

  var blockingError: String? {
    if case .blocking(let message)? = failure { return message }
    return nil
  }

  var noticeMessage: String? {
    if case .notice(let message)? = failure { return message }
    return nil
  }

  mutating func finish(libraryID: String, requested: GenreSelection,
                       result: Result<[ItemSummary], any Error>) {
    switch result {
    case .success(let loaded):
      adopt(loaded, libraryID: libraryID, requested: requested)
    case .failure(let error):
      let matches = appliedSelection == requested && appliedLibraryID == libraryID
      failure = .decide(hasContent: !items.isEmpty, contentMatchesRequest: matches,
                        message: loadFailureMessage(error))
      if case .blocking? = failure {
        // What is on screen answers a different library or filter. Showing it as the result of
        // this request would be wrong, so it goes; the error screen says the load failed.
        items = []
      }
    }
  }

  /// Takes `loaded` as the answer to `requested` (a successful load, or the offline catalog).
  mutating func adopt(_ loaded: [ItemSummary], libraryID: String, requested: GenreSelection) {
    items = loaded
    appliedSelection = requested
    appliedLibraryID = libraryID
    failure = nil
  }

  /// The on-device catalog has no genre data: it may only answer an unfiltered request.
  static func cacheMayAnswer(_ requested: GenreSelection) -> Bool { requested.genres.isEmpty }
}

// MARK: - Paging a library (FRD-001 FR-082, TASK-976)

/// Loads every page of a library and returns each id the server sent exactly once.
///
/// Identity is the server's decision (its dedupe rules and unique ids). The client does not add a
/// second rule on top: collapsing by title, year and runtime hid distinct server ids (two files of
/// one film, a copy in another folder), so the grid held fewer tiles than the server total and the
/// hidden ones could not be opened or deleted. The only client rule is "the same id twice is one
/// entry", which also keeps a server that returns overlapping pages from listing a title twice.
enum LibraryPaging {
  /// App-side safety valves so a server whose total never converges cannot page forever
  /// (TASK-790). 50 pages x 200 = 10k items is well past any real library.
  static let pageSize = 200
  static let maxPages = 50

  static func loadAll(
    pageSize: Int = LibraryPaging.pageSize,
    maxPages: Int = LibraryPaging.maxPages,
    fetchPage: (_ limit: Int, _ offset: Int) async throws -> ItemsResponse
  ) async throws -> [ItemSummary] {
    var result: [ItemSummary] = []
    var seenIDs = Set<String>()
    var offset = 0
    for _ in 0..<maxPages {
      let response = try await fetchPage(pageSize, offset)
      var newOnThisPage = 0
      for item in response.items where seenIDs.insert(item.id).inserted {
        result.append(item)
        newOnThisPage += 1
      }
      // A page with no NEW id means the server is repeating itself; stop.
      if newOnThisPage == 0 { break }
      if response.items.count < pageSize || result.count >= response.effectiveTotal { break }
      offset += pageSize
    }
    return result
  }
}
