import Foundation

/// Static demo content shown to App Review when logging in with demo credentials.
/// Credentials: username "appledemo" / password "DSVideo2024" (any server address).
enum DemoData {

  // MARK: - Libraries

  static let libraries: [Library] = [
    Library(id: "demo-movies", title: "Movies", kind: "movie"),
    Library(id: "demo-tv",     title: "TV Shows", kind: "tv"),
  ]

  // MARK: - Movie Items

  static let movieItems: [ItemSummary] = [
    ItemSummary(id: "dm-1", type: "movie", title: "The Grand Horizon",
                year: 2023, durationSeconds: 7440,
                addedAt: "2024-02-10T09:00:00Z", rating: 8.2,
                posterImageId: nil, backdropImageId: nil,
                progress: ItemProgress(positionSeconds: 1820, durationSeconds: 7440, updatedAt: "2024-03-01T20:00:00Z"),
                seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-2", type: "movie", title: "Crimson Tide",
                year: 2022, durationSeconds: 6600,
                addedAt: "2024-01-20T14:30:00Z", rating: 7.6,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-3", type: "movie", title: "Starfall",
                year: 2023, durationSeconds: 8100,
                addedAt: "2024-03-05T18:00:00Z", rating: 8.8,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-4", type: "movie", title: "The Quiet Storm",
                year: 2021, durationSeconds: 6900,
                addedAt: "2023-11-14T11:00:00Z", rating: 7.1,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-5", type: "movie", title: "Last Light",
                year: 2020, durationSeconds: 7200,
                addedAt: "2023-09-28T08:00:00Z", rating: 6.9,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-6", type: "movie", title: "Northern Passage",
                year: 2022, durationSeconds: 7560,
                addedAt: "2024-01-02T16:00:00Z", rating: 7.4,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-7", type: "movie", title: "Echo Valley",
                year: 2023, durationSeconds: 6300,
                addedAt: "2024-02-28T12:00:00Z", rating: 7.9,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-8", type: "movie", title: "Freefall",
                year: 2021, durationSeconds: 5940,
                addedAt: "2023-07-18T09:30:00Z", rating: 6.5,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: nil, episodeNumber: nil),
  ]

  // MARK: - TV Episode Items (flattened, as returned by the episodes API)

  static let tvItems: [ItemSummary] = [
    ItemSummary(id: "dt-1", type: "episode", title: "Pilot",
                year: 2022, durationSeconds: 2700,
                addedAt: "2023-05-01T10:00:00Z", rating: nil,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: 1, episodeNumber: 1),
    ItemSummary(id: "dt-2", type: "episode", title: "First Contact",
                year: 2022, durationSeconds: 2520,
                addedAt: "2023-05-01T10:00:00Z", rating: nil,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: 1, episodeNumber: 2),
    ItemSummary(id: "dt-3", type: "episode", title: "The Long Road",
                year: 2022, durationSeconds: 2640,
                addedAt: "2023-05-01T10:00:00Z", rating: nil,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, seasonNumber: 1, episodeNumber: 3),
  ]

  // MARK: - Item Details

  private static let noImages = ItemDetail.Images(
    poster:   ItemDetail.Images.Ref(id: nil, mapperId: nil),
    backdrop: ItemDetail.Images.Ref(id: nil, mapperId: nil)
  )

  static let details: [String: ItemDetail] = [
    "dm-1": ItemDetail(
      id: "dm-1", type: "movie",
      title: "The Grand Horizon", originalTitle: nil,
      year: 2023, durationSeconds: 7440,
      contentRating: "PG-13",
      summary: "An expedition team ventures beyond the known world to chart unmapped territory — and discovers something that challenges everything they thought they understood about human history.",
      genres: ["Adventure", "Drama"],
      cast: [
        ItemDetail.Person(id: nil, name: "James Calloway", role: "Director", imageId: nil),
        ItemDetail.Person(id: nil, name: "Elena Marsh", role: "Lead", imageId: nil),
      ],
      images: noImages
    ),
    "dm-2": ItemDetail(
      id: "dm-2", type: "movie",
      title: "Crimson Tide", originalTitle: nil,
      year: 2022, durationSeconds: 6600,
      contentRating: "R",
      summary: "A classified government operation goes sideways when the only person who can stop it is the operative they burned three years ago.",
      genres: ["Thriller", "Action"],
      cast: [],
      images: noImages
    ),
    "dm-3": ItemDetail(
      id: "dm-3", type: "movie",
      title: "Starfall", originalTitle: nil,
      year: 2023, durationSeconds: 8100,
      contentRating: "PG",
      summary: "When an observatory detects an impossible signal from deep space, a lone astronomer races against time — and doubt — to understand what's coming before it arrives.",
      genres: ["Sci-Fi", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dm-4": ItemDetail(
      id: "dm-4", type: "movie",
      title: "The Quiet Storm", originalTitle: nil,
      year: 2021, durationSeconds: 6900,
      contentRating: "PG-13",
      summary: "A retired fisherman on a remote island discovers a stranger washed ashore — and a secret that ties their pasts together in ways neither expected.",
      genres: ["Drama"],
      cast: [],
      images: noImages
    ),
    "dm-5": ItemDetail(
      id: "dm-5", type: "movie",
      title: "Last Light", originalTitle: nil,
      year: 2020, durationSeconds: 7200,
      contentRating: "PG-13",
      summary: "In the final hours before a city-wide blackout, five strangers must find a way to keep the power on — or face the consequences of what lives in the dark.",
      genres: ["Thriller", "Drama"],
      cast: [],
      images: noImages
    ),
    "dm-6": ItemDetail(
      id: "dm-6", type: "movie",
      title: "Northern Passage", originalTitle: nil,
      year: 2022, durationSeconds: 7560,
      contentRating: "PG",
      summary: "Two siblings attempt to cross the frozen northern wilderness to reach their estranged father before winter closes the route for another year.",
      genres: ["Adventure", "Family"],
      cast: [],
      images: noImages
    ),
    "dm-7": ItemDetail(
      id: "dm-7", type: "movie",
      title: "Echo Valley", originalTitle: nil,
      year: 2023, durationSeconds: 6300,
      contentRating: "R",
      summary: "A sound engineer at a remote recording studio begins to hear voices in the tapes that shouldn't be there — voices that know things no one could possibly know.",
      genres: ["Horror", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dm-8": ItemDetail(
      id: "dm-8", type: "movie",
      title: "Freefall", originalTitle: nil,
      year: 2021, durationSeconds: 5940,
      contentRating: "PG-13",
      summary: "A BASE jumper with a troubled past takes one last contract jump over a remote mountain range — and lands somewhere no map has ever charted.",
      genres: ["Action", "Adventure"],
      cast: [],
      images: noImages
    ),
    "dt-1": ItemDetail(
      id: "dt-1", type: "episode",
      title: "Pilot", originalTitle: nil,
      year: 2022, durationSeconds: 2700,
      contentRating: "TV-MA",
      summary: "Series premiere. An intelligence analyst discovers an anomaly in the data that her agency insists doesn't exist.",
      genres: ["Drama", "Thriller"],
      cast: [],
      images: noImages
    ),
    "dt-2": ItemDetail(
      id: "dt-2", type: "episode",
      title: "First Contact", originalTitle: nil,
      year: 2022, durationSeconds: 2520,
      contentRating: "TV-MA",
      summary: "Following the events of the pilot, she makes contact with the only other person who has seen what she's seen.",
      genres: ["Drama", "Thriller"],
      cast: [],
      images: noImages
    ),
    "dt-3": ItemDetail(
      id: "dt-3", type: "episode",
      title: "The Long Road", originalTitle: nil,
      year: 2022, durationSeconds: 2640,
      contentRating: "TV-MA",
      summary: "With surveillance closing in, the two must decide how far they're willing to go to expose the truth.",
      genres: ["Drama", "Thriller"],
      cast: [],
      images: noImages
    ),
  ]

  // MARK: - Lookup Helpers

  static func items(for library: Library) -> [ItemSummary] {
    switch library.kind {
    case "tv": return tvItems
    default:   return movieItems
    }
  }

  static func detail(for id: String) -> ItemDetail? {
    details[id]
  }
}
