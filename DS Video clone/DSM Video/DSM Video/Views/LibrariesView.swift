import SwiftUI

struct LibrariesView: View {
  @Environment(AppState.self) private var appState
  @State private var libraries: [Library] = []
  @State private var isLoading: Bool = false
  @State private var error: String?

  /// Pass `true` when this view is embedded as the detail column of a
  /// `NavigationSplitView`. The split view itself acts as the navigation
  /// container, so wrapping in a second `NavigationStack` would produce
  /// double nav bars and broken back-navigation on iPad/macOS.
  var isEmbedded: Bool = false

  var body: some View {
    let content = Group {
      if isLoading && libraries.isEmpty {
        ProgressView()
      } else if let error {
        ContentUnavailableView("Couldn't load libraries", systemImage: "exclamationmark.triangle", description: Text(error))
      } else if libraries.isEmpty {
        ContentUnavailableView("No Libraries", systemImage: "square.grid.2x2", description: Text("No video libraries found on your Synology NAS."))
      } else {
        List(libraries) { lib in
          NavigationLink {
            if lib.kind == "tv" {
              TVShowsView(library: lib)
            } else {
              ItemsGridView(library: lib)
            }
          } label: {
            Label(lib.title, systemImage: libraryIcon(lib.kind))
          }
        }
      }
    }
    .navigationTitle("Libraries")
    .task { await load() }
    .refreshable { await load() }

    if isEmbedded {
      content
    } else {
      NavigationStack { content }
    }
  }

  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      libraries = DemoData.libraries
      return
    }
    error = nil
    isLoading = true
    defer { isLoading = false }

    do {
      let response = try await appState.api.libraries()
      libraries = response.libraries
    } catch {
      let errorMsg = (error as? WebAPIError)?.userMessage ?? (error as? APIError)?.userMessage ?? "Unknown error."
      self.error = errorMsg
    }
  }

  private func libraryIcon(_ kind: String) -> String {
    switch kind {
    case "tv": return "tv"
    case "movies", "movie": return "film"
    case "home", "homevideo": return "house"
    default: return "play.rectangle"
    }
  }
}

struct LibraryHomeView: View {
  @Environment(AppState.self) private var appState
  @State private var allItems: [ItemSummary] = []
  @State private var libraries: [Library] = []
  @State private var isLoading: Bool = false
  @State private var error: String?

  // MARK: - Rail Filters

  private var continueWatchingItems: [ItemSummary] {
    let sorted = allItems
      .filter { item in
        guard let p = item.progress, p.durationSeconds > 0 else { return false }
        let frac = Double(p.positionSeconds) / Double(p.durationSeconds)
        return frac >= 0.05 && frac < 0.95
      }
      .sorted { a, b in
        parseDate(a.progress?.updatedAt ?? a.addedAt) > parseDate(b.progress?.updatedAt ?? b.addedAt)
      }
    return deduplicated(sorted)
  }

  private var justAddedItems: [ItemSummary] {
    let sorted = allItems.sorted { parseDate($0.addedAt) > parseDate($1.addedAt) }
    return deduplicated(sorted)
  }

  private var recentlyWatchedItems: [ItemSummary] {
    let sorted = allItems
      .filter { item in
        guard let p = item.progress, p.durationSeconds > 0 else { return false }
        let frac = Double(p.positionSeconds) / Double(p.durationSeconds)
        return frac >= 0.95
      }
      .sorted { a, b in
        parseDate(a.progress?.updatedAt ?? a.addedAt) > parseDate(b.progress?.updatedAt ?? b.addedAt)
      }
    return deduplicated(sorted)
  }

  private func parseDate(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso) ?? Date.distantPast
  }

  /// Removes duplicate entries for the same title, keeping the first (highest-priority) occurrence.
  /// This ensures a TV show with many episodes only appears once per rail.
  private func deduplicated(_ items: [ItemSummary]) -> [ItemSummary] {
    var seen = Set<String>()
    return items.filter { item in
      let key = item.title.lowercased() + "|\(item.type)"
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
  }

  private var firstMovieLibrary: Library? {
    libraries.first(where: { $0.kind == "movie" || $0.kind == "movies" }) ?? libraries.first
  }

  private var allRailsEmpty: Bool {
    continueWatchingItems.isEmpty && justAddedItems.isEmpty && recentlyWatchedItems.isEmpty
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      Group {
        if isLoading && allItems.isEmpty {
          ProgressView()
        } else if let error {
          VStack(spacing: 16) {
            ContentUnavailableView(
              "Couldn't load content",
              systemImage: "exclamationmark.triangle",
              description: Text(error)
            )
            Button("Retry") { Task { await load() } }
              .buttonStyle(.bordered)
          }
        } else if allRailsEmpty && !isLoading {
          ContentUnavailableView(
            "Nothing here yet",
            systemImage: "play.rectangle",
            description: Text("Add videos to your NAS to get started.")
          )
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 28) {
              if !continueWatchingItems.isEmpty {
                HomeRail(
                  title: "Continue Watching",
                  items: continueWatchingItems,
                  seeAllLibrary: firstMovieLibrary
                )
              }
              if !justAddedItems.isEmpty {
                HomeRail(
                  title: "Just Added",
                  items: justAddedItems,
                  seeAllLibrary: firstMovieLibrary
                )
              }
              if !recentlyWatchedItems.isEmpty {
                HomeRail(
                  title: "Recently Watched",
                  items: recentlyWatchedItems,
                  seeAllLibrary: firstMovieLibrary
                )
              }
            }
            .padding(.vertical, 16)
          }
        }
      }
      .navigationTitle("Home")
      .task { await load() }
      .refreshable { await load() }
      .background(Color.black.ignoresSafeArea())
    }
  }

  // MARK: - Load

  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      libraries = DemoData.libraries
      allItems = DemoData.movieItems + DemoData.tvItems
      return
    }
    error = nil
    isLoading = true
    defer { isLoading = false }

    do {
      let loadedLibs = try await appState.api.libraries().libraries
      libraries = loadedLibs

      // Fetch all items from all libraries and merge into one flat array
      var merged: [ItemSummary] = []
      try await withThrowingTaskGroup(of: [ItemSummary].self) { group in
        for lib in loadedLibs {
          group.addTask {
            var libItems: [ItemSummary] = []
            var offset = 0
            let pageSize = 200
            while true {
              let response = try await appState.api.items(
                libraryId: lib.id, limit: pageSize, offset: offset
              )
              libItems.append(contentsOf: response.items)
              if response.items.isEmpty || response.items.count < pageSize || libItems.count >= response.total || offset >= 5000 { break }
              offset += pageSize
            }
            return libItems
          }
        }
        for try await libItems in group {
          merged.append(contentsOf: libItems)
        }
      }
      allItems = merged
    } catch {
      let errorMsg = (error as? APIError)?.userMessage ?? "Unknown error."
      if allItems.isEmpty {
        self.error = errorMsg
      }
    }
  }
}

// MARK: - HomeRail

private struct HomeRail: View {
  let title: String
  let items: [ItemSummary]
  let seeAllLibrary: Library?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Header row
      HStack {
        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
        Spacer()
        if let lib = seeAllLibrary {
          NavigationLink("See All") {
            ItemsGridView(library: lib)
          }
          .font(.subheadline)
          .foregroundStyle(DSReelBrandColor.background)
        }
      }
      .padding(.horizontal, 16)

      // Horizontal scroll of poster cards
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 10) {
          ForEach(items) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              ItemPosterCell(item: item)
                .frame(width: 120)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }
}

