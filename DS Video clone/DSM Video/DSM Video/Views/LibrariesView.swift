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
  @State private var defaultLibrary: Library?
  @State private var isLoading: Bool = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Group {
        if isLoading && defaultLibrary == nil {
          ProgressView()
        } else if let error {
          ContentUnavailableView("Couldn't load library", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let defaultLibrary {
          ItemsGridView(library: defaultLibrary)
            .navigationTitle(defaultLibrary.title)
        } else {
          ContentUnavailableView("No libraries", systemImage: "square.grid.2x2", description: Text("No libraries available."))
        }
      }
      .task {
        await load()
      }
      .refreshable { await load() }
    }
  }

  private func load() async {
    guard !isLoading else { return }
    if appState.isDemoMode {
      defaultLibrary = DemoData.libraries.first
      return
    }
    isLoading = true
    error = nil
    defer { isLoading = false }

    do {
      let libs = try await appState.api.libraries().libraries
      defaultLibrary = libs.first
    } catch {
      let errorMsg = (error as? WebAPIError)?.userMessage ?? (error as? APIError)?.userMessage ?? "Unknown error."
      self.error = errorMsg
    }
  }
}

