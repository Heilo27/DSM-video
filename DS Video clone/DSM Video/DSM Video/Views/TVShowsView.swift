import SwiftUI

struct TVShowsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let library: Library

  @State private var shows: [TVShow] = []
  @State private var isLoading = false
  @State private var error: String?

  #if os(tvOS)
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 28)] }
  #else
  private var columns: [GridItem] {
    let minimum: CGFloat = horizontalSizeClass == .regular ? 180 : 140
    return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
  }
  #endif

  var body: some View {
    ScrollView {
      if isLoading && shows.isEmpty {
        ProgressView()
          #if os(tvOS)
          .padding(.top, 60)
          #else
          .padding(.top, 24)
          #endif
      } else if let error {
        ContentUnavailableView(
          "Couldn't load shows",
          systemImage: "exclamationmark.triangle",
          description: Text(error)
        )
        #if os(tvOS)
        .padding(.top, 60)
        #else
        .padding(.top, 24)
        #endif
      } else if shows.isEmpty {
        ContentUnavailableView(
          "No TV Shows",
          systemImage: "tv",
          description: Text("No TV shows found in this library.")
        )
        #if os(tvOS)
        .padding(.top, 80)
        #else
        .padding(.top, 60)
        #endif
      } else {
        #if os(tvOS)
        LazyVGrid(columns: columns, spacing: 44) {
          ForEach(shows) { show in
            NavigationLink {
              TVShowDetailView(show: show, library: library)
            } label: {
              TVShowPosterCell(show: show)
            }
            .buttonStyle(.card)
            .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens show details")
          }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 48)
        #else
        LazyVGrid(columns: columns, spacing: 12) {
          ForEach(shows) { show in
            NavigationLink {
              TVShowDetailView(show: show, library: library)
            } label: {
              TVShowPosterCell(show: show)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens show details")
          }
        }
        .padding(horizontalSizeClass == .regular ? 20 : 12)
        #endif
      }
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(library.title)
    .task { await load() }
    #if !os(tvOS)
    .refreshable { await load() }
    #endif
  }

  private func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let response = try await appState.api.tvShows(libraryId: library.id)
      shows = response.shows
      error = nil
    } catch {
      let msg = (error as? APIError)?.userMessage ?? "Unknown error."
      if shows.isEmpty { self.error = msg }
    }
  }
}

// MARK: - Poster Cell

private struct TVShowPosterCell: View {
  @Environment(AppState.self) private var appState
  let show: TVShow

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height = width * (3.0 / 2.0)  // 2:3 portrait

      ZStack(alignment: .bottom) {
        // Poster image
        if let id = show.posterImageId {
          AuthenticatedImage(
            url: appState.api.imageURL(id: id, width: 400),
            token: appState.sessionToken
          )
          .scaledToFill()
          .frame(width: width, height: height)
          .clipped()
        } else {
          Color(white: 0.08)
            .frame(width: width, height: height)
            .overlay(
              Image(systemName: "tv.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.25))
                .accessibilityLabel("No poster available")
            )
        }

        // Bottom gradient
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.45),
            .init(color: .black.opacity(0.88), location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(width: width, height: height)

        // Title + season label
        VStack(alignment: .leading, spacing: 4) {
          Text(show.title)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

          Text(seasonLabel(show))
            .font(.system(size: 15))
            .foregroundStyle(Color.dsTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
  }

  private func seasonLabel(_ show: TVShow) -> String {
    if show.seasonCount == 1 {
      return "\(show.episodeCount) episode\(show.episodeCount == 1 ? "" : "s")"
    }
    return "\(show.seasonCount) season\(show.seasonCount == 1 ? "" : "s")"
  }
}
