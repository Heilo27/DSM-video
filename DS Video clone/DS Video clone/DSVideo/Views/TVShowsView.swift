import SwiftUI

struct TVShowsView: View {
  @Environment(AppState.self) private var appState
  let library: Library

  @State private var shows: [TVShow] = []
  @State private var isLoading = false
  @State private var error: String?

  #if os(tvOS)
  private let columns = [GridItem(.adaptive(minimum: 280), spacing: 24)]
  #else
  private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
  #endif

  var body: some View {
    ScrollView {
      if isLoading && shows.isEmpty {
        ProgressView().padding(.top, 24)
      } else if let error {
        ContentUnavailableView("Couldn't load shows", systemImage: "exclamationmark.triangle", description: Text(error))
          .padding(.top, 24)
      } else if shows.isEmpty {
        ContentUnavailableView("No TV Shows", systemImage: "tv", description: Text("No TV shows found in this library."))
          .padding(.top, 60)
      } else {
        #if os(tvOS)
        let gridSpacing: CGFloat = 24
        let gridPadding: CGFloat = 48
        #else
        let gridSpacing: CGFloat = 12
        let gridPadding: CGFloat = 12
        #endif
        LazyVGrid(columns: columns, spacing: gridSpacing) {
          ForEach(shows) { show in
            NavigationLink {
              TVShowDetailView(show: show, library: library)
            } label: {
              TVShowPosterCell(show: show)
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel("\(show.title)\(show.year.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens show details")
          }
        }
        .padding(gridPadding)
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

private struct TVShowPosterCell: View {
  @Environment(AppState.self) private var appState
  let show: TVShow

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height = width * (3.0 / 2.0)

      ZStack(alignment: .bottom) {
        // Poster image
        if show.posterImageId != nil {
          AuthenticatedImage(
            url: appState.api.imageURL(id: show.posterImageId!, width: 400),
            token: appState.sessionToken
          )
          .scaledToFill()
          .frame(width: width, height: height)
          .clipped()
        } else {
          Color(white: 0.06)
            .frame(width: width, height: height)
            .overlay(
              Image(systemName: "tv.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.25))
                .accessibilityLabel("No poster available")
            )
        }

        // Gradient overlay
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.45),
            .init(color: .black.opacity(0.85), location: 1.0)
          ],
          startPoint: .top, endPoint: .bottom
        )

        // Title + season count
        VStack(alignment: .leading, spacing: 2) {
          Text(show.title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

          Text(seasonLabel(show))
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
