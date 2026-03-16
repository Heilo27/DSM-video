import Foundation
import OSLog

// MARK: - Streaming & Progress API

extension VideoStationWebAPIClient {

    /// Get playback/streaming URL
    /// Official app uses: POST to /webapi/entry.cgi with SYNO.VideoStation2.Streaming to get stream_id,
    /// then GET to /webapi/VideoStation/vtestreaming.cgi/DTV.mov with stream_id
    func getPlayback(id: String, type: String) async throws -> PlaybackInfo {
        guard let idInt = Int(id) else {
            throw WebAPIError.server(-1, ["Invalid item ID"])
        }

        // Official app flow (from HAR analysis):
        // Step 1: POST to /webapi/entry.cgi (NOT vtestreaming.cgi!) with:
        //   - api: SYNO.VideoStation2.Streaming
        //   - file: {"id":<item_id>}  (just id, no library_id!)
        //   - method: open
        //   - raw: {"device":"ios","force_open_vte":false,"audio_track":1,"profile":""}
        //   - version: 1
        // Response is base64-encoded JSON with stream_id

        // Step 1: POST to entry.cgi to open stream
        guard var openComponents = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
            throw WebAPIError.invalidURL
        }
        openComponents.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.VideoStation2.Streaming"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "open"),
        ]

        // Add session ID
        if let sessionID = sessionID {
            openComponents.queryItems?.append(URLQueryItem(name: "_sid", value: sessionID))
        }

        guard let openURL = openComponents.url else {
            throw WebAPIError.invalidURL
        }

        var openRequest = URLRequest(url: openURL)
        openRequest.httpMethod = "POST"
        openRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        openRequest.setValue("Synology-DS_video_3.4.5_iPhone_iOS_26.3 (iPhone; iOS 26.3)", forHTTPHeaderField: "User-Agent")
        openRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        openRequest.setValue("en-US;q=1", forHTTPHeaderField: "Accept-Language")

        // Build form body exactly as official app does
        // Official app uses just {"id":<item_id>} - no library_id, no mapper_id
        let fileJSON = "{\"id\":\(idInt)}"
        let rawJSON = "{\"device\":\"ios\",\"force_open_vte\":false,\"audio_track\":1,\"profile\":\"\"}"

        var formBodyParts: [String] = []
        formBodyParts.append("file=\(fileJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileJSON)")
        formBodyParts.append("raw=\(rawJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawJSON)")

        let formBody = formBodyParts.joined(separator: "&")
        openRequest.httpBody = formBody.data(using: .utf8)

        // Set cookie - official app uses Cookie header with id=<session_id> and did=<device_id>
        var cookieParts: [String] = []
        if let sessionID = sessionID {
            cookieParts.append("id=\(sessionID)")
        }
        if let deviceID = deviceID {
            cookieParts.append("did=\(deviceID)")
        }
        if !cookieParts.isEmpty {
            openRequest.setValue(cookieParts.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }

        Self.logger.debug("Step 1: POST to entry.cgi to open stream for id=\(id)")
        Self.logger.debug("  URL: \(openURL.absoluteString)")
        Self.logger.debug("  Body: \(formBody)")

        let (openData, openResponse) = try await URLSession.shared.data(for: openRequest)

        guard let httpResponse = openResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorString = String(data: openData, encoding: .utf8) {
                Self.logger.error("Open stream failed: \(errorString)")
            }
            throw WebAPIError.http(httpResponse.statusCode)
        }

        // Parse response - official app returns base64-encoded JSON for success, plain JSON for errors
        let responseString = String(data: openData, encoding: .utf8) ?? ""
        Self.logger.debug("Open response (raw): \(responseString.prefix(200))")

        // Try plain JSON first (for error responses)
        var streamId: String?
        if let jsonData = try? JSONDecoder().decode(WebAPIResponse<VideoStationStreamOpenData>.self, from: openData) {
            if jsonData.success, let data = jsonData.data, let id = data.stream_id {
                streamId = id
                Self.logger.info("Got stream_id from plain JSON: \(id)")
            } else {
                // It's an error response
                let errorCode = jsonData.error?.code ?? -1
                let errorMsg = jsonData.error?.errors?.joined(separator: ", ") ?? (errorCode == 1101 ? "File not found. The video may not be accessible for streaming." : "Unknown error")
                Self.logger.error("Open stream failed with error code \(errorCode): \(errorMsg)")
                throw WebAPIError.server(errorCode, jsonData.error?.errors)
            }
        } else {
            // Try base64 decode (for success responses)
            if let base64Data = Data(base64Encoded: responseString.trimmingCharacters(in: .whitespacesAndNewlines)),
               let decodedString = String(data: base64Data, encoding: .utf8),
               let jsonData = try? JSONDecoder().decode(WebAPIResponse<VideoStationStreamOpenData>.self, from: decodedString.data(using: .utf8) ?? Data()) {
                if jsonData.success, let data = jsonData.data, let id = data.stream_id {
                    streamId = id
                    Self.logger.info("Decoded base64 response, got stream_id: \(id)")
                } else {
                    let errorCode = jsonData.error?.code ?? -1
                    let errorMsg = jsonData.error?.errors?.joined(separator: ", ") ?? (errorCode == 1101 ? "File not found. The video may not be accessible for streaming." : "Unknown error")
                    Self.logger.error("Open stream failed with error code \(errorCode): \(errorMsg)")
                    throw WebAPIError.server(errorCode, jsonData.error?.errors)
                }
            } else {
                Self.logger.error("Could not decode response (neither base64 nor JSON): \(responseString.prefix(200))")
                throw WebAPIError.server(-1, ["Failed to decode stream response"])
            }
        }

        guard let streamId = streamId else {
            throw WebAPIError.server(-1, ["Failed to get stream_id"])
        }

        // Step 2: GET to vtestreaming.cgi/DTV.mov with stream_id
        return try await getStreamURL(streamId: streamId)
    }

    /// Helper: Get streaming URL using stream_id (official app format)
    private func getStreamURL(streamId: String) async throws -> PlaybackInfo {
        // Official app uses: GET /webapi/VideoStation/vtestreaming.cgi/DTV.mov
        // with query: api=SYNO.VideoStation.Streaming&version=1&method=stream&id=<stream_id>&format=raw&_sid=<session_id>
        guard var streamComponents = URLComponents(url: baseURL.appendingPathComponent("/webapi/VideoStation/vtestreaming.cgi/DTV.mov"), resolvingAgainstBaseURL: false) else {
            throw WebAPIError.invalidURL
        }
        streamComponents.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.VideoStation.Streaming"), // Note: NOT VideoStation2!
            URLQueryItem(name: "version", value: "1"), // Note: version 1, not 2!
            URLQueryItem(name: "method", value: "stream"),
            URLQueryItem(name: "id", value: streamId), // stream_id goes in 'id' parameter
            URLQueryItem(name: "format", value: "raw"), // Official app uses "raw", not "hls_remux"
        ]

        // Add session ID
        if let sessionID = sessionID {
            streamComponents.queryItems?.append(URLQueryItem(name: "_sid", value: sessionID))
        }

        guard let streamURL = streamComponents.url else {
            throw WebAPIError.invalidURL
        }

        Self.logger.debug("Step 2: Getting stream URL for stream_id=\(streamId)")
        Self.logger.debug("  URL: \(streamURL.absoluteString)")

        // This URL should return the actual video stream (HTTP 206 Partial Content for MP4)
        // Return it directly as the playback URL
        return PlaybackInfo(
            kind: "direct",
            streamUrl: streamURL,
            hlsMasterUrl: nil,
            resumePositionSeconds: 0
        )
    }

    /// Set playback progress
    private func updateProgress(id: String, positionSeconds: Int, durationSeconds: Int) async throws {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
            throw WebAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.VideoStation2.WatchStatus"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "update"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "time", value: String(positionSeconds)),
            URLQueryItem(name: "total_time", value: String(durationSeconds)),
        ]

        guard let url = components.url else {
            throw WebAPIError.invalidURL
        }

        let response: WebAPIResponse<VideoStationUpdateResponse> = try await request(url: url)

        guard response.success else {
            throw WebAPIError.server(response.error?.code ?? -1, response.error?.errors)
        }
    }

    // MARK: - Adapters

    /// Adapter: playback() - matches APIClient interface
    func playback(id: String) async throws -> PlaybackInfo {
        // Try movie first, then TV show — but only fall through on server "not found" errors.
        // Network, HTTP, auth, and decode errors are rethrown immediately.
        do {
            return try await getPlayback(id: id, type: "movie")
        } catch let error as WebAPIError {
            switch error {
            case .server(let code, _) where code == -1 || code == 800 || code == 117 || code == 1101:
                // -1: unknown; 800/117: VS "not found" codes; 1101: "file not found" (streaming)
                // Fall through to TV show attempt
                break
            default:
                throw error
            }
        }
        return try await getPlayback(id: id, type: "tvshow")
    }

    /// Adapter: setProgress() - matches APIClient interface
    func setProgress(id: String, positionSeconds: Int, durationSeconds: Int) async throws {
        try await updateProgress(id: id, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    }
}
