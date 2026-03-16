import Foundation
import OSLog

// MARK: - Library Cache

actor LibraryCache {
    static let shared = LibraryCache()
    private var cached: LibrariesResponse?

    func get() -> LibrariesResponse? { cached }
    func set(_ libs: LibrariesResponse) { cached = libs }
    func invalidate() { cached = nil }
}

// MARK: - Items API

extension VideoStationWebAPIClient {

    /// Get items in a library
    /// SYNO.VideoStation2.Movie or SYNO.VideoStation2.TVShow depending on library type
    func getItems(libraryId: String, libraryType: String, limit: Int = 50, offset: Int = 0) async throws -> ItemsResponse {
        // Determine API based on library type
        let apiName: String
        switch libraryType.lowercased() {
        case "movie", "movies":
            apiName = "SYNO.VideoStation2.Movie"
        case "tvshow", "tv", "tv shows":
            apiName = "SYNO.VideoStation2.TVShow"
        case "homevideo", "home video":
            apiName = "SYNO.VideoStation2.HomeVideo"
        default:
            apiName = "SYNO.VideoStation2.Movie" // Default to movie
        }

        guard var components = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
            throw WebAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "api", value: apiName),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "library_id", value: libraryId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]

        guard let url = components.url else {
            throw WebAPIError.invalidURL
        }

        let response: WebAPIResponse<VideoStationItemsData> = try await request(url: url)

        guard response.success, let data = response.data else {
            throw WebAPIError.server(response.error?.code ?? -1, response.error?.errors)
        }

        // Convert to app format
        let items = data.items.map { vsItem in
            // From Charles capture: original app uses mapper_id for poster API calls
            // Always prefer mapper_id over poster/backdrop fields for image IDs
            let posterId = vsItem.mapper_id != nil ? String(vsItem.mapper_id!) : vsItem.poster
            let backdropId = vsItem.mapper_id != nil ? String(vsItem.mapper_id!) : vsItem.backdrop

            Self.logger.debug("Item \(vsItem.id): poster=\(posterId ?? "nil"), backdrop=\(backdropId ?? "nil"), mapper_id=\(vsItem.mapper_id?.description ?? "nil")")

            return ItemSummary(
                id: String(vsItem.id),
                type: vsItem.type ?? "movie",
                title: vsItem.title,
                year: vsItem.year,
                durationSeconds: vsItem.duration,
                addedAt: vsItem.added_at ?? "",
                rating: vsItem.rating,
                posterImageId: posterId,
                backdropImageId: backdropId,
                progress: vsItem.watch_status.map { status in
                    ItemProgress(
                        positionSeconds: status.time ?? 0,
                        durationSeconds: status.total_time ?? 0,
                        updatedAt: status.updated_at ?? ""
                    )
                },
                seasonNumber: nil,
                episodeNumber: nil
            )
        }

        return ItemsResponse(total: data.total, items: items)
    }

    /// Get item detail
    /// Video Station getinfo API might need mapper_id instead of id
    func getItemDetail(id: String, type: String) async throws -> ItemDetail {
        // Use appropriate API based on type
        let apiName: String
        switch type.lowercased() {
        case "movie":
            apiName = "SYNO.VideoStation2.Movie"
        case "tvshow", "tv":
            apiName = "SYNO.VideoStation2.TVShow"
        default:
            apiName = "SYNO.VideoStation2.Movie"
        }

        // Try multiple parameter combinations:
        // 1. id with library_id
        // 2. id without library_id
        // 3. mapper_id (if id is numeric, assume it might be mapper_id)

        var response: WebAPIResponse<VideoStationItemDetailArrayData>?

        // Attempt 1: id with library_id
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
            throw WebAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "api", value: apiName),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "getinfo"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "library_id", value: "0"),
        ]

        if let url = components.url {
            Self.logger.debug("Getting item detail for id=\(id), type=\(type) (attempt 1: id with library_id)")
            response = try? await request(url: url)
            if response?.success == true, response?.data?.item != nil {
                Self.logger.info("Got item detail with id + library_id")
            }
        }

        // Attempt 2: id without library_id
        if response?.success != true || response?.data?.item == nil {
            Self.logger.warning("Attempt 1 failed, trying id without library_id...")
            guard var components2 = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
                throw WebAPIError.invalidURL
            }
            components2.queryItems = [
                URLQueryItem(name: "api", value: apiName),
                URLQueryItem(name: "version", value: "1"),
                URLQueryItem(name: "method", value: "getinfo"),
                URLQueryItem(name: "id", value: id),
            ]
            if let url2 = components2.url {
                response = try? await request(url: url2)
                if response?.success == true, response?.data?.item != nil {
                    Self.logger.info("Got item detail with id only")
                }
            }
        }

        // Attempt 3: mapper_id (if id is numeric)
        if response?.success != true || response?.data?.item == nil, let idInt = Int(id) {
            Self.logger.warning("Attempt 2 failed, trying mapper_id=\(idInt)...")
            guard var components3 = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
                throw WebAPIError.invalidURL
            }
            components3.queryItems = [
                URLQueryItem(name: "api", value: apiName),
                URLQueryItem(name: "version", value: "1"),
                URLQueryItem(name: "method", value: "getinfo"),
                URLQueryItem(name: "mapper_id", value: String(idInt)),
                URLQueryItem(name: "library_id", value: "0"),
            ]
            if let url3 = components3.url {
                response = try? await request(url: url3)
                if response?.success == true, response?.data?.item != nil {
                    Self.logger.info("Got item detail with mapper_id")
                }
            }
        }

        guard let finalResponse = response, finalResponse.success, let data = finalResponse.data, let vsItem = data.item else {
            let errorCode = response?.error?.code ?? -1
            let errorMsg = response?.error?.errors?.joined(separator: ", ") ?? "Unknown error"
            Self.logger.error("Item detail error: code=\(errorCode), errors=\(errorMsg)")
            Self.logger.debug("  All attempts failed - item might not exist or API needs different parameters")
            throw WebAPIError.server(errorCode, response?.error?.errors)
        }

        Self.logger.info("Got item detail: \(vsItem.title)")
        Self.logger.debug("  Poster: \(vsItem.poster ?? "nil"), Backdrop: \(vsItem.backdrop ?? "nil")")

        return ItemDetail(
            id: String(vsItem.id),
            type: vsItem.type ?? "movie",
            title: vsItem.title,
            originalTitle: vsItem.original_title,
            year: vsItem.year,
            durationSeconds: vsItem.duration,
            contentRating: vsItem.rating,
            summary: vsItem.summary,
            genres: vsItem.genres ?? [],
            cast: (vsItem.actors ?? []).map { actor in
                ItemDetail.Person(
                    id: nil,
                    name: actor.name,
                    role: actor.role,
                    imageId: nil
                )
            },
            images: ItemDetail.Images(
                poster: ItemDetail.Images.Ref(
                    id: vsItem.poster,
                    mapperId: vsItem.mapper_id != nil ? String(vsItem.mapper_id!) : nil
                ),
                backdrop: ItemDetail.Images.Ref(
                    id: vsItem.backdrop,
                    mapperId: vsItem.mapper_id != nil ? String(vsItem.mapper_id!) : nil
                )
            )
        )
    }

    /// Get image URL (includes session ID in query params for Video Station)
    /// Official app uses: /webapi/VideoStation/poster.cgi?api=SYNO.VideoStation.Poster&method=getimage&version=3&id=<item_id>&type=movie&mtime=<timestamp>
    /// - Parameters:
    ///   - id: Item ID (not mapper_id)
    ///   - width: Optional width parameter
    ///   - type: Item type (movie, tvshow, tvshow_episode, etc.)
    ///   - useCacheBusting: If true, adds mtime parameter for cache busting (like official app does ~45% of the time)
    func imageURL(id: String, width: Int? = nil, type: String = "poster", useCacheBusting: Bool = false) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/webapi/VideoStation/poster.cgi"), resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.VideoStation.Poster"), // Note: NOT VideoStation2!
            URLQueryItem(name: "method", value: "getimage"), // Note: getimage, not get!
            URLQueryItem(name: "version", value: "3"), // Note: version 3, not 1!
            URLQueryItem(name: "id", value: id), // Use item ID, not mapper_id
        ]

        // Type is required: "movie", "tvshow", "tvshow_episode", "homevideo", etc. (string, not numeric)
        // The 'type' parameter here is the item type (movie/tvshow/tvshow_episode), not "poster" or "backdrop"
        // If caller passes "poster" or "backdrop", default to "movie"
        let itemType: String
        if type.lowercased() == "poster" || type.lowercased() == "backdrop" {
            itemType = "movie" // Default to movie if not specified
        } else {
            // Normalize type: "tv" -> "tvshow", "episode" -> "tvshow_episode"
            let normalizedType = type.lowercased()
            if normalizedType == "tv" || normalizedType == "tvshow" {
                itemType = "tvshow"
            } else if normalizedType == "episode" || normalizedType == "tvshow_episode" {
                itemType = "tvshow_episode" // Official app uses this for TV show episodes
            } else {
                itemType = type // Use as-is (movie, homevideo, etc.)
            }
        }
        queryItems.append(URLQueryItem(name: "type", value: itemType))

        // Optional: mtime parameter (cache busting timestamp)
        // Official app includes: mtime=1743110344.543000 (about 45% of calls use it)
        // Format: Unix timestamp with microseconds (6 decimal places)
        if useCacheBusting {
            let mtime = Date().timeIntervalSince1970
            let mtimeString = String(format: "%.6f", mtime)
            queryItems.append(URLQueryItem(name: "mtime", value: mtimeString))
        }

        // Note: Official app does NOT include _sid in poster.cgi URLs
        // Session is handled via cookies or not required for poster images

        components.queryItems = queryItems

        let url = components.url
        Self.logger.debug("Poster URL (official format) for id=\(id), type=\(type): \(url?.absoluteString ?? "nil")")
        return url
    }

    /// Get backdrop image URL
    /// Official app uses: /webapi/entry.cgi?api=SYNO.VideoStation.Backdrop&method=get&version=1&mapper_id=<mapper_id>
    func backdropURL(mapperId: String) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.VideoStation.Backdrop"), // Different API for backdrop!
            URLQueryItem(name: "method", value: "get"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "mapper_id", value: mapperId), // Uses mapper_id for backdrop
        ]

        // Add session ID if available
        if let sessionID = sessionID {
            queryItems.append(URLQueryItem(name: "_sid", value: sessionID))
        }

        components.queryItems = queryItems

        let url = components.url
        Self.logger.debug("Backdrop URL (official format) for mapper_id=\(mapperId): \(url?.absoluteString ?? "nil")")
        return url
    }

    // MARK: - Adapters

    /// Adapter: items() - matches APIClient interface
    func items(libraryId: String, limit: Int = 50, offset: Int = 0) async throws -> ItemsResponse {
        // libraryId is the library's ID (which is the type like "movie", "tvshow")
        // We can use it directly as the library type, or look it up from libraries list.
        // Cache the libraries list to avoid a redundant network call on every paginated request.
        let libs: LibrariesResponse
        if let cached = await LibraryCache.shared.get() {
            libs = cached
        } else {
            libs = try await getLibraries()
            await LibraryCache.shared.set(libs)
        }
        let library = libs.libraries.first(where: { $0.id == libraryId })
        // Prefer library.kind, but fall back to library.id (which should be the type) or libraryId
        let libraryType = library?.kind ?? library?.id ?? libraryId

        Self.logger.debug("Loading items for libraryId=\(libraryId), type=\(libraryType)")
        Self.logger.debug("  Found library: \(library?.title ?? "nil"), kind: \(library?.kind ?? "nil")")

        // Use library type as ID since Video Station doesn't use numeric library IDs
        return try await getItems(libraryId: "0", libraryType: libraryType, limit: limit, offset: offset)
    }

    /// Adapter: itemDetail() - matches APIClient interface
    func itemDetail(id: String) async throws -> ItemDetail {
        // Try movie first, then TV show — but only fall through on server "not found" errors.
        // Network, HTTP, auth, and decode errors are rethrown immediately.
        do {
            return try await getItemDetail(id: id, type: "movie")
        } catch let error as WebAPIError {
            switch error {
            case .server(let code, _) where code == -1 || code == 800 || code == 117:
                // -1: unknown/no item returned; 800/117: typical VS "not found" codes
                // Fall through to TV show attempt
                break
            default:
                throw error
            }
        }
        return try await getItemDetail(id: id, type: "tvshow")
    }
}
