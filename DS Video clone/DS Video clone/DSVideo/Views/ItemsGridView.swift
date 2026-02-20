import SwiftUI

struct ItemsGridView: View {
  @Environment(AppState.self) private var appState
  let library: Library

  @State private var items: [ItemSummary] = []
  @State private var isLoading: Bool = false
  @State private var error: String?

  #if os(tvOS)
  private let columns = [GridItem(.adaptive(minimum: 280), spacing: 24)]
  #else
  private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
  #endif

  var body: some View {
    ScrollView {
      if isLoading && items.isEmpty {
        ProgressView()
          .padding(.top, 24)
      } else if let error {
        ContentUnavailableView("Couldn't load items", systemImage: "exclamationmark.triangle", description: Text(error))
          .padding(.top, 24)
      } else {
        #if os(tvOS)
        let gridSpacing: CGFloat = 24
        let gridPadding: CGFloat = 48
        #else
        let gridSpacing: CGFloat = 12
        let gridPadding: CGFloat = 12
        #endif
        LazyVGrid(columns: columns, spacing: gridSpacing) {
          ForEach(items) { item in
            NavigationLink {
              ItemDetailView(itemID: item.id, fallbackTitle: item.title)
            } label: {
              ItemPosterCell(item: item)
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(itemAccessibilityLabel(item))
            .accessibilityHint("Opens video details")
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

  private func itemAccessibilityLabel(_ item: ItemSummary) -> String {
    var label = item.title
    if let year = item.year {
      label += ", \(year)"
    }
    if let progress = item.progress, progress.durationSeconds > 0 {
      let percent = Int((Double(progress.positionSeconds) / Double(progress.durationSeconds)) * 100)
      label += ", \(percent) percent watched"
    }
    return label
  }

  private func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      // Fetch all items by paginating through the API (server limits to 200 per request)
      var allItems: [ItemSummary] = []
      var offset = 0
      let pageSize = 200

      while true {
        let response = try await appState.api.items(libraryId: library.id, limit: pageSize, offset: offset)
        allItems.append(contentsOf: response.items)

        if response.items.count < pageSize || allItems.count >= response.total {
          break
        }
        offset += pageSize
      }

      items = allItems
      error = nil
    } catch {
      let errorMsg = (error as? WebAPIError)?.userMessage ?? (error as? APIError)?.userMessage ?? "Unknown error."
      if items.isEmpty {
        self.error = errorMsg
      }
    }
  }
}

struct ItemPosterCell: View {
  @Environment(AppState.self) private var appState
  let item: ItemSummary

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height = width * (3.0 / 2.0)

      ZStack(alignment: .bottom) {
        posterImage(width: width, height: height)
        gradientOverlay
        cellFooter
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

      if let progress = item.progress, progress.durationSeconds > 0 {
        let frac = Double(progress.positionSeconds) / Double(progress.durationSeconds)
        ProgressView(value: frac)
          .tint(DSReelBrandColor.background)
          .frame(width: width)
          .scaleEffect(y: 0.6, anchor: .top)
          .offset(y: height)
      }
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
  }

  @ViewBuilder
  private func posterImage(width: CGFloat, height: CGFloat) -> some View {
    if item.posterImageId != nil {
      AuthenticatedImage(
        url: appState.api.imageURL(id: item.posterImageId ?? item.id, width: 400),
        token: appState.sessionToken
      )
      .scaledToFill()
      .frame(width: width, height: height)
      .clipped()
    } else {
      Rectangle()
        .fill(Color(white: 0.06))
        .frame(width: width, height: height)
        .overlay(
          Image(systemName: "film.fill")
            .font(.system(size: 36))
            .foregroundStyle(.white.opacity(0.25))
            .accessibilityLabel("No poster available")
        )
    }
  }

  @ViewBuilder
  private var gradientOverlay: some View {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0.45),
        .init(color: .black.opacity(0.85), location: 1.0)
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  @ViewBuilder
  private var cellFooter: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(item.title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

      if let year = item.year {
        Text(String(year))
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.65))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
  }
}
