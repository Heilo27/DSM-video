import Foundation

/// Static demo content shown to App Review when logging in with demo credentials.
/// Credentials: username "appledemo" / password "dsvideo2024" (any server address, case-insensitive).
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
                progress: ItemProgress(positionSeconds: 3348, durationSeconds: 7440, updatedAt: "2024-03-01T20:00:00Z"),
                showName: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-2", type: "movie", title: "Crimson Protocol",
                year: 2022, durationSeconds: 6600,
                addedAt: "2024-01-20T14:30:00Z", rating: 7.6,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, showName: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-3", type: "movie", title: "Starfall",
                year: 2023, durationSeconds: 8100,
                addedAt: "2024-03-05T18:00:00Z", rating: 8.8,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, showName: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-4", type: "movie", title: "The Quiet Storm",
                year: 2021, durationSeconds: 6900,
                addedAt: "2023-11-14T11:00:00Z", rating: 7.1,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, showName: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-5", type: "movie", title: "Last Light",
                year: 2020, durationSeconds: 7200,
                addedAt: "2023-09-28T08:00:00Z", rating: 6.9,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, showName: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-6", type: "movie", title: "Northern Passage",
                year: 2022, durationSeconds: 7560,
                addedAt: "2024-01-02T16:00:00Z", rating: 7.4,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, showName: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-7", type: "movie", title: "Echo Valley",
                year: 2023, durationSeconds: 6300,
                addedAt: "2024-02-28T12:00:00Z", rating: 7.9,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, showName: nil, seasonNumber: nil, episodeNumber: nil),
    ItemSummary(id: "dm-8", type: "movie", title: "Freefall",
                year: 2021, durationSeconds: 5940,
                addedAt: "2023-07-18T09:30:00Z", rating: 6.5,
                posterImageId: nil, backdropImageId: nil,
                progress: nil, showName: nil, seasonNumber: nil, episodeNumber: nil),
  ]

  // MARK: - TV Shows

  static let tvShows: [TVShow] = [
    TVShow(id: "ds-1", title: "The Signal", year: 2022,
           seasonCount: 1, episodeCount: 3, posterImageId: nil, lastWatchedAt: nil, addedAt: nil),
    TVShow(id: "ds-2", title: "Meridian Cross", year: 2023,
           seasonCount: 2, episodeCount: 10, posterImageId: nil, lastWatchedAt: nil, addedAt: nil),
  ]

  static let tvSeasons: [String: [TVSeason]] = [
    "ds-1": [TVSeason(seasonNumber: 1, episodeCount: 3)],
    "ds-2": [
      TVSeason(seasonNumber: 1, episodeCount: 6),
      TVSeason(seasonNumber: 2, episodeCount: 4),
    ],
  ]

  static func seasons(for showId: String) -> [TVSeason] {
    tvSeasons[showId] ?? []
  }

  // Per-show episode map — keyed by showId, then by season number
  private static let tvEpisodeMap: [String: [Int: [ItemSummary]]] = [
    "ds-1": [
      1: [
        ItemSummary(id: "dt-1", type: "episode", title: "Pilot",
                    year: 2022, durationSeconds: 2700,
                    addedAt: "2023-05-01T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "The Signal", seasonNumber: 1, episodeNumber: 1),
        ItemSummary(id: "dt-2", type: "episode", title: "First Contact",
                    year: 2022, durationSeconds: 2520,
                    addedAt: "2023-05-01T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "The Signal", seasonNumber: 1, episodeNumber: 2),
        ItemSummary(id: "dt-3", type: "episode", title: "The Long Road",
                    year: 2022, durationSeconds: 2640,
                    addedAt: "2023-05-01T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "The Signal", seasonNumber: 1, episodeNumber: 3),
      ],
    ],
    "ds-2": [
      1: [
        ItemSummary(id: "dx-1", type: "episode", title: "The Crossing",
                    year: 2023, durationSeconds: 3120,
                    addedAt: "2024-01-10T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: ItemProgress(positionSeconds: 1404, durationSeconds: 3120,
                                           updatedAt: "2024-03-10T19:30:00Z"),
                    showName: "Meridian Cross", seasonNumber: 1, episodeNumber: 1),
        ItemSummary(id: "dx-2", type: "episode", title: "Into the Valley",
                    year: 2023, durationSeconds: 2880,
                    addedAt: "2024-01-10T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: ItemProgress(positionSeconds: 2880, durationSeconds: 2880,
                                           updatedAt: "2024-03-12T20:00:00Z"),
                    showName: "Meridian Cross", seasonNumber: 1, episodeNumber: 2),
        ItemSummary(id: "dx-3", type: "episode", title: "Fault Lines",
                    year: 2023, durationSeconds: 2760,
                    addedAt: "2024-01-10T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "Meridian Cross", seasonNumber: 1, episodeNumber: 3),
        ItemSummary(id: "dx-4", type: "episode", title: "The Northern Route",
                    year: 2023, durationSeconds: 3000,
                    addedAt: "2024-01-10T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "Meridian Cross", seasonNumber: 1, episodeNumber: 4),
        ItemSummary(id: "dx-5", type: "episode", title: "Meridian",
                    year: 2023, durationSeconds: 2940,
                    addedAt: "2024-01-10T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "Meridian Cross", seasonNumber: 1, episodeNumber: 5),
        ItemSummary(id: "dx-6", type: "episode", title: "Season Finale",
                    year: 2023, durationSeconds: 3300,
                    addedAt: "2024-01-10T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "Meridian Cross", seasonNumber: 1, episodeNumber: 6),
      ],
      2: [
        ItemSummary(id: "dx-7", type: "episode", title: "New Coordinates",
                    year: 2024, durationSeconds: 3060,
                    addedAt: "2024-09-15T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "Meridian Cross", seasonNumber: 2, episodeNumber: 1),
        ItemSummary(id: "dx-8", type: "episode", title: "Shifting Ground",
                    year: 2024, durationSeconds: 2820,
                    addedAt: "2024-09-15T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "Meridian Cross", seasonNumber: 2, episodeNumber: 2),
        ItemSummary(id: "dx-9", type: "episode", title: "The Return",
                    year: 2024, durationSeconds: 2940,
                    addedAt: "2024-09-15T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "Meridian Cross", seasonNumber: 2, episodeNumber: 3),
        ItemSummary(id: "dx-10", type: "episode", title: "Crossroads",
                    year: 2024, durationSeconds: 3480,
                    addedAt: "2024-09-15T10:00:00Z", rating: nil,
                    posterImageId: nil, backdropImageId: nil,
                    progress: nil, showName: "Meridian Cross", seasonNumber: 2, episodeNumber: 4),
      ],
    ],
  ]

  static func episodes(for showId: String, season: Int) -> [ItemSummary] {
    tvEpisodeMap[showId]?[season] ?? []
  }

  // MARK: - TV Episode Items (flattened — used for search results and library listing)

  static let tvItems: [ItemSummary] = {
    tvEpisodeMap.values.flatMap { $0.values.flatMap { $0 } }
      .sorted { a, b in
        if a.showName != b.showName { return (a.showName ?? "") < (b.showName ?? "") }
        if a.seasonNumber != b.seasonNumber { return (a.seasonNumber ?? 0) < (b.seasonNumber ?? 0) }
        return (a.episodeNumber ?? 0) < (b.episodeNumber ?? 0)
      }
  }()

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
      contentRating: "PG-13", rating: 7.8,
      summary: "An expedition team ventures beyond the known world to chart unmapped territory — and discovers something that challenges everything they thought they understood about human history.",
      genres: ["Adventure", "Drama"],
      cast: [
        ItemDetail.Person(id: nil, name: "Sarah Chen", role: "Director", imageId: nil),
        ItemDetail.Person(id: nil, name: "Elena Marsh", role: "Lead", imageId: nil),
      ],
      images: noImages
    ),
    "dm-2": ItemDetail(
      id: "dm-2", type: "movie",
      title: "Crimson Protocol", originalTitle: nil,
      year: 2022, durationSeconds: 6600,
      contentRating: "R", rating: nil,
      summary: "A classified government operation goes sideways when the only person who can stop it is the operative they burned three years ago.",
      genres: ["Thriller", "Action"],
      cast: [],
      images: noImages
    ),
    "dm-3": ItemDetail(
      id: "dm-3", type: "movie",
      title: "Starfall", originalTitle: nil,
      year: 2023, durationSeconds: 8100,
      contentRating: "PG", rating: nil,
      summary: "When an observatory detects an impossible signal from deep space, a lone astronomer races against time — and doubt — to understand what's coming before it arrives.",
      genres: ["Sci-Fi", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dm-4": ItemDetail(
      id: "dm-4", type: "movie",
      title: "The Quiet Storm", originalTitle: nil,
      year: 2021, durationSeconds: 6900,
      contentRating: "PG-13", rating: nil,
      summary: "A retired fisherman on a remote island discovers a stranger washed ashore — and a secret that ties their pasts together in ways neither expected.",
      genres: ["Drama"],
      cast: [],
      images: noImages
    ),
    "dm-5": ItemDetail(
      id: "dm-5", type: "movie",
      title: "Last Light", originalTitle: nil,
      year: 2020, durationSeconds: 7200,
      contentRating: "PG-13", rating: nil,
      summary: "In the final hours before a city-wide blackout, five strangers must find a way to keep the power on — or face the consequences of what lives in the dark.",
      genres: ["Thriller", "Drama"],
      cast: [],
      images: noImages
    ),
    "dm-6": ItemDetail(
      id: "dm-6", type: "movie",
      title: "Northern Passage", originalTitle: nil,
      year: 2022, durationSeconds: 7560,
      contentRating: "PG", rating: nil,
      summary: "Two siblings attempt to cross the frozen northern wilderness to reach their estranged father before winter closes the route for another year.",
      genres: ["Adventure", "Family"],
      cast: [],
      images: noImages
    ),
    "dm-7": ItemDetail(
      id: "dm-7", type: "movie",
      title: "Echo Valley", originalTitle: nil,
      year: 2023, durationSeconds: 6300,
      contentRating: "R", rating: nil,
      summary: "A sound engineer at a remote recording studio begins to hear voices in the tapes that shouldn't be there — voices that know things no one could possibly know.",
      genres: ["Horror", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dm-8": ItemDetail(
      id: "dm-8", type: "movie",
      title: "Freefall", originalTitle: nil,
      year: 2021, durationSeconds: 5940,
      contentRating: "PG-13", rating: nil,
      summary: "A BASE jumper with a troubled past takes one last contract jump over a remote mountain range — and lands somewhere no map has ever charted.",
      genres: ["Action", "Adventure"],
      cast: [],
      images: noImages
    ),
    "ds-1": ItemDetail(
      id: "ds-1", type: "tv",
      title: "The Signal", originalTitle: nil,
      year: 2022, durationSeconds: nil,
      contentRating: "TV-MA", rating: 8.2,
      summary: "An intelligence analyst uncovers an anomaly in classified data that her agency insists doesn't exist — and sets in motion a chain of events that will change everything she thought she knew.",
      genres: ["Drama", "Thriller"],
      cast: [
        ItemDetail.Person(id: nil, name: "Marcus Webb", role: "Director", imageId: nil),
        ItemDetail.Person(id: nil, name: "Sara Voss", role: "Lead", imageId: nil),
      ],
      images: noImages
    ),
    "dt-1": ItemDetail(
      id: "dt-1", type: "episode",
      title: "Pilot", originalTitle: nil,
      year: 2022, durationSeconds: 2700,
      contentRating: "TV-MA", rating: nil,
      summary: "Series premiere. An intelligence analyst discovers an anomaly in the data that her agency insists doesn't exist.",
      genres: ["Drama", "Thriller"],
      cast: [],
      images: noImages
    ),
    "dt-2": ItemDetail(
      id: "dt-2", type: "episode",
      title: "First Contact", originalTitle: nil,
      year: 2022, durationSeconds: 2520,
      contentRating: "TV-MA", rating: nil,
      summary: "Following the events of the pilot, she makes contact with the only other person who has seen what she's seen.",
      genres: ["Drama", "Thriller"],
      cast: [],
      images: noImages
    ),
    "dt-3": ItemDetail(
      id: "dt-3", type: "episode",
      title: "The Long Road", originalTitle: nil,
      year: 2022, durationSeconds: 2640,
      contentRating: "TV-MA", rating: nil,
      summary: "With surveillance closing in, the two must decide how far they're willing to go to expose the truth.",
      genres: ["Drama", "Thriller"],
      cast: [],
      images: noImages
    ),
    "ds-2": ItemDetail(
      id: "ds-2", type: "tv",
      title: "Meridian Cross", originalTitle: nil,
      year: 2023, durationSeconds: nil,
      contentRating: "TV-14", rating: 7.4,
      summary: "A cartographer stationed at a remote survey outpost begins charting territory that her superiors insist doesn't exist — and discovers a community that has been living off the grid for generations.",
      genres: ["Drama", "Mystery"],
      cast: [
        ItemDetail.Person(id: nil, name: "Priya Okafor", role: "Director", imageId: nil),
        ItemDetail.Person(id: nil, name: "Nadia Solano", role: "Lead", imageId: nil),
        ItemDetail.Person(id: nil, name: "Theo Blackwell", role: "Supporting", imageId: nil),
      ],
      images: noImages
    ),
    "dx-1": ItemDetail(
      id: "dx-1", type: "episode",
      title: "The Crossing", originalTitle: nil,
      year: 2023, durationSeconds: 3120,
      contentRating: "TV-14", rating: nil,
      summary: "Cartographer Nadia Solano arrives at the Meridian survey post and immediately finds a discrepancy in the official maps no one will explain.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-2": ItemDetail(
      id: "dx-2", type: "episode",
      title: "Into the Valley", originalTitle: nil,
      year: 2023, durationSeconds: 2880,
      contentRating: "TV-14", rating: nil,
      summary: "Nadia ventures beyond the post's official boundary and finds evidence that the terrain has been deliberately mischarted.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-3": ItemDetail(
      id: "dx-3", type: "episode",
      title: "Fault Lines", originalTitle: nil,
      year: 2023, durationSeconds: 2760,
      contentRating: "TV-14", rating: nil,
      summary: "A fissure in the valley floor leads Nadia to a hidden passage — and the first contact with the community beyond.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-4": ItemDetail(
      id: "dx-4", type: "episode",
      title: "The Northern Route", originalTitle: nil,
      year: 2023, durationSeconds: 3000,
      contentRating: "TV-14", rating: nil,
      summary: "Theo proposes an alternate route that would bypass official checkpoints. Nadia must decide how much she trusts him.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-5": ItemDetail(
      id: "dx-5", type: "episode",
      title: "Meridian", originalTitle: nil,
      year: 2023, durationSeconds: 2940,
      contentRating: "TV-14", rating: nil,
      summary: "The true boundary of the unmapped territory is revealed. What lies at the meridian changes everything.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-6": ItemDetail(
      id: "dx-6", type: "episode",
      title: "Season Finale", originalTitle: nil,
      year: 2023, durationSeconds: 3300,
      contentRating: "TV-14", rating: nil,
      summary: "Nadia's report reaches her superiors — but someone has already altered it. Season one ends with a choice she can't take back.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-7": ItemDetail(
      id: "dx-7", type: "episode",
      title: "New Coordinates", originalTitle: nil,
      year: 2024, durationSeconds: 3060,
      contentRating: "TV-14", rating: nil,
      summary: "Six months later, Nadia returns under a different assignment — and finds the community has grown.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-8": ItemDetail(
      id: "dx-8", type: "episode",
      title: "Shifting Ground", originalTitle: nil,
      year: 2024, durationSeconds: 2820,
      contentRating: "TV-14", rating: nil,
      summary: "The agency's intentions for the territory become clear. Nadia and Theo must decide whose side they're on.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-9": ItemDetail(
      id: "dx-9", type: "episode",
      title: "The Return", originalTitle: nil,
      year: 2024, durationSeconds: 2940,
      contentRating: "TV-14", rating: nil,
      summary: "Nadia attempts to return to the community with a warning — but the path she used no longer exists.",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
    "dx-10": ItemDetail(
      id: "dx-10", type: "episode",
      title: "Crossroads", originalTitle: nil,
      year: 2024, durationSeconds: 3480,
      contentRating: "TV-14", rating: nil,
      summary: "The final confrontation at the meridian. The map will be redrawn — but by whose hand?",
      genres: ["Drama", "Mystery"],
      cast: [],
      images: noImages
    ),
  ]

  // MARK: - Demo Poster Asset Names

  /// Maps demo item IDs to asset catalog image names for placeholder posters.
  static let posterAssetNames: [String: String] = [
    "dm-1": "demo_poster_grand_horizon",
    "dm-2": "demo_poster_crimson_protocol",
    "dm-3": "demo_poster_starfall",
    "dm-4": "demo_poster_quiet_storm",
    "dm-5": "demo_poster_last_light",
    "dm-6": "demo_poster_northern_passage",
    "dm-7": "demo_poster_echo_valley",
    "dm-8": "demo_poster_freefall",
    "ds-1": "demo_poster_the_signal",
    "dt-1": "demo_poster_the_signal",
    "dt-2": "demo_poster_the_signal",
    "dt-3": "demo_poster_the_signal",
    "ds-2": "demo_poster_northern_passage",
    "dx-1": "demo_poster_northern_passage",
    "dx-2": "demo_poster_northern_passage",
    "dx-3": "demo_poster_northern_passage",
    "dx-4": "demo_poster_northern_passage",
    "dx-5": "demo_poster_northern_passage",
    "dx-6": "demo_poster_northern_passage",
    "dx-7": "demo_poster_northern_passage",
    "dx-8": "demo_poster_northern_passage",
    "dx-9": "demo_poster_northern_passage",
    "dx-10": "demo_poster_northern_passage",
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
