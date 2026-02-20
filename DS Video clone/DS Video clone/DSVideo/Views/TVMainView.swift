import SwiftUI

#if os(tvOS)

struct TVMainView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    Group {
      if appState.sessionToken == nil {
        TVPairingView()
      } else {
        TVHomeView()
      }
    }
  }
}

private struct TVHomeView: View {
  @Environment(AppState.self) private var appState
  @State private var libraries: [Library] = []
  @State private var continueWatching: [ItemSummary] = []
  @State private var justAdded: [ItemSummary] = []
  @State private var isLoading: Bool = false

  var body: some View {
    NavigationStack {
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 40) {
          if !continueWatching.isEmpty {
            TVRail(title: "Continue Watching", items: continueWatching)
          }
          if !justAdded.isEmpty {
            TVRail(title: "Just Added", items: justAdded)
          }
          if libraries.isEmpty && !isLoading {
            ContentUnavailableView("No Libraries", systemImage: "film.stack", description: Text("No video libraries were found."))
              .foregroundStyle(.white)
          }
          ForEach(libraries) { lib in
            TVLibraryRail(library: lib)
          }
        }
        .padding(.vertical, 40)
      }
      .background(Color.black.ignoresSafeArea())
    }
    .task { await load() }
  }

  private func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      libraries = try await appState.api.libraries().libraries

      // Load continue watching (items with progress)
      if let firstLib = libraries.first {
        let items = try await appState.api.items(libraryId: firstLib.id, limit: 20, offset: 0).items
        continueWatching = items.filter { $0.progress != nil }
        justAdded = Array(items.prefix(10))
      }
    } catch {
      // Error handling - could show error state in future
    }
  }
}

private struct TVRail: View {
  let title: String
  let items: [ItemSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(title)
        .font(.title2)
        .foregroundStyle(.white)
        .padding(.horizontal, 40)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 20) {
          ForEach(items) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              TVPosterCard(item: item)
            }
            .buttonStyle(.card)
          }
        }
        .padding(.horizontal, 40)
      }
    }
  }
}

private struct TVLibraryRail: View {
  @Environment(AppState.self) private var appState
  let library: Library

  @State private var items: [ItemSummary] = []
  @State private var isLoading: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      NavigationLink {
        ItemsGridView(library: library)
      } label: {
        HStack {
          Text(library.title)
            .font(.title2)
            .foregroundStyle(.white)
          Image(systemName: "chevron.right")
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Navigate to library")
        }
        .padding(.horizontal, 40)
      }
      .buttonStyle(.plain)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 20) {
          ForEach(items.prefix(20)) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              TVPosterCard(item: item)
            }
            .buttonStyle(.card)
          }
        }
        .padding(.horizontal, 40)
      }
    }
    .task { await load() }
  }

  private func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      items = try await appState.api.items(libraryId: library.id, limit: 50, offset: 0).items
    } catch {
      // ignore
    }
  }
}

private struct TVPosterCard: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .bottomLeading) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.white.opacity(0.08))
          .frame(width: 300, height: 450)

        if let posterID = item.posterImageId {
          AuthenticatedImage(url: appState.api.imageURL(id: posterID, width: 600), token: appState.sessionToken)
            .scaledToFill()
            .frame(width: 300, height: 450)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
          Image(systemName: "play.circle.fill")
            .font(.system(size: 60))
            .foregroundStyle(.white.opacity(0.65))
            .accessibilityLabel("Play video")
        }

        if let progress = item.progress, progress.durationSeconds > 0 {
          let frac = Double(progress.positionSeconds) / Double(progress.durationSeconds)
          VStack(spacing: 0) {
            Spacer()
            ProgressView(value: frac)
              .tint(DSReelBrandColor.background)
              .frame(height: 4)
          }
          .frame(maxWidth: .infinity)
        }
      }

      Text(item.title)
        .font(.headline)
        .foregroundStyle(.white)
        .lineLimit(2)
        .frame(width: 300, alignment: .leading)

      if let year = item.year {
        Text(String(year))
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.7))
      }
    }
    .focusable()
  }
}

#Preview {
  TVMainView()
    .environment(AppState())
}

#endif

