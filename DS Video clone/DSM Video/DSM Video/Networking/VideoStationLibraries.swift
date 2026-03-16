import Foundation
import OSLog

// MARK: - Libraries API

extension VideoStationWebAPIClient {

    /// Get Video Station library list
    /// SYNO.VideoStation2.Library - version 1, method=list
    func getLibraries() async throws -> LibrariesResponse {
        // Invalidate the item-library cache so the next items() call re-fetches fresh data.
        await LibraryCache.shared.invalidate()

        guard var components = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
            throw WebAPIError.invalidURL
        }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.VideoStation2.Library"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "list"),
        ]

        // Don't add _sid here - let request() method handle it to avoid duplication
        // But we need to ensure sessionID is available
        guard let sessionID = sessionID else {
            Self.logger.error("No session ID available for library API call")
            throw WebAPIError.server(401, ["Not authenticated"])
        }

        Self.logger.debug("Calling Video Station Library API with session ID: \(sessionID.prefix(20))...")

        components.queryItems = queryItems

        guard let url = components.url else {
            throw WebAPIError.invalidURL
        }

        Self.logger.debug("Library API URL (before adding _sid): \(url.absoluteString)")

        let response: WebAPIResponse<VideoStationLibrariesData> = try await request(url: url)

        Self.logger.debug("Library API response - success: \(response.success)")

        guard response.success, let data = response.data else {
            let errorCode = response.error?.code ?? -1
            let errorMsg = response.error?.errors?.joined(separator: ", ") ?? "Unknown error"
            Self.logger.error("Library API error: code=\(errorCode), errors=\(errorMsg)")
            throw WebAPIError.server(errorCode, response.error?.errors)
        }

        // Convert Video Station format to app format
        guard let vsLibraries = data.libraries, !vsLibraries.isEmpty else {
            Self.logger.warning("No libraries found in response (data.libraries is nil or empty)")
            return LibrariesResponse(libraries: [])
        }

        Self.logger.info("Found \(vsLibraries.count) libraries")
        for (index, vsLib) in vsLibraries.enumerated() {
            Self.logger.debug("  Library \(index): id=\(vsLib.id), name='\(vsLib.name)', type='\(vsLib.type ?? "nil")'")
        }

        // Video Station returns all libraries with id=0, so we use type as unique identifier
        let libraries = vsLibraries.enumerated().map { index, vsLib in
            Library(
                // Use type as ID since all libraries have id=0, or use index as fallback
                id: vsLib.type ?? "library_\(index)",
                title: vsLib.name,
                kind: vsLib.type ?? "unknown"
            )
        }

        return LibrariesResponse(libraries: libraries)
    }

    // MARK: - Adapter

    /// Adapter: libraries() - matches APIClient interface
    func libraries() async throws -> LibrariesResponse {
        try await getLibraries()
    }
}
