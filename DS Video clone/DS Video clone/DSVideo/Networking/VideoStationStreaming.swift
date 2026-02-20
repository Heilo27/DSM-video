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
        var openComponents = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false)!
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
        formBodyParts.append("api=SYNO.VideoStation2.Streaming")
        formBodyParts.append("file=\(fileJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileJSON)")
        formBodyParts.append("method=open")
        formBodyParts.append("raw=\(rawJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawJSON)")
        formBodyParts.append("version=1")

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

    /// Try opening stream with file JSON including library_id (fallback for error 101)
    private func tryOpenStreamWithFileJSONAndLibrary(id: String, idInt: Int) async throws -> PlaybackInfo {
        let openURL = baseURL.appendingPathComponent("/webapi/VideoStation/vtestreaming.cgi")

        var openRequest = URLRequest(url: openURL)
        openRequest.httpMethod = "POST"
        openRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Try file parameter as JSON with library_id (this matches the 116-byte body size)
        let fileJSON = "{\"id\":\(idInt),\"library_id\":0}"
        let formBody = "file=\(fileJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileJSON)"

        openRequest.httpBody = formBody.data(using: .utf8)

        // Set cookie - official app uses Cookie header with id=<session_id>
        if let sessionID = sessionID {
            openRequest.setValue("id=\(sessionID)", forHTTPHeaderField: "Cookie")
        }

        Self.logger.debug("Retry 2: POST to vtestreaming.cgi with file JSON + library_id")
        Self.logger.debug("  Body: \(formBody)")

        let (openData, openResponse) = try await URLSession.shared.data(for: openRequest)

        guard let httpResponse = openResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorString = String(data: openData, encoding: .utf8) {
                Self.logger.error("Retry 2 failed: \(errorString)")
            }
            throw WebAPIError.http(httpResponse.statusCode)
        }

        let responseString = String(data: openData, encoding: .utf8) ?? ""
        Self.logger.debug("Retry 2 response: \(responseString)")

        // Check for error
        if let errorResponse = try? JSONDecoder().decode(WebAPIErrorResponse.self, from: openData) {
            throw WebAPIError.server(errorResponse.error.code, errorResponse.error.errors)
        }

        // Extract stream_id
        var streamId: String?
        if let jsonData = try? JSONDecoder().decode([String: String].self, from: openData),
           let id = jsonData["stream_id"] ?? jsonData["id"] {
            streamId = id
        } else if let jsonData = try? JSONDecoder().decode(WebAPIResponse<VideoStationStreamOpenData>.self, from: openData),
                  jsonData.success,
                  let data = jsonData.data,
                  let id = data.stream_id {
            streamId = id
        } else {
            let trimmed = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count > 10 && !trimmed.contains("error") {
                streamId = trimmed
            }
        }

        guard let streamId = streamId else {
            throw WebAPIError.server(-1, ["Failed to get stream_id from retry 2"])
        }

        Self.logger.info("Got stream_id from retry 2: \(streamId)")
        return try await getStreamURL(streamId: streamId)
    }

    /// Try old entry.cgi endpoint as last resort (fallback for error 101)
    private func tryOpenStreamOldEndpoint(id: String, idInt: Int) async throws -> PlaybackInfo {
        // Fallback to old endpoint: /webapi/entry.cgi with VideoStation2.Streaming
        var openComponents = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false)!
        openComponents.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.VideoStation2.Streaming"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "open"),
            URLQueryItem(name: "file", value: "{\"id\":\(idInt),\"library_id\":0}"),
        ]

        if let sessionID = sessionID {
            openComponents.queryItems?.append(URLQueryItem(name: "_sid", value: sessionID))
        }

        guard let openURL = openComponents.url else {
            throw WebAPIError.invalidURL
        }

        Self.logger.debug("Retry 3: Using old entry.cgi endpoint")
        Self.logger.debug("  URL: \(openURL.absoluteString)")

        var openRequest = URLRequest(url: openURL)
        openRequest.httpMethod = "GET"

        if let sessionID = sessionID {
            openRequest.setValue("id=\(sessionID)", forHTTPHeaderField: "Cookie")
        }

        let (openData, openResponse) = try await URLSession.shared.data(for: openRequest)

        guard let httpResponse = openResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebAPIError.http(httpResponse.statusCode)
        }

        let responseString = String(data: openData, encoding: .utf8) ?? ""
        Self.logger.debug("Retry 3 response: \(responseString)")

        // Try to decode response
        if let jsonData = try? JSONDecoder().decode(WebAPIResponse<VideoStationStreamOpenData>.self, from: openData),
           jsonData.success,
           let data = jsonData.data,
           let streamId = data.stream_id {
            Self.logger.info("Got stream_id from old endpoint: \(streamId)")
            return try await getStreamURL(streamId: streamId)
        }

        throw WebAPIError.server(-1, ["Failed to get stream_id from old endpoint"])
    }

    /// Try opening stream with just id parameter (no JSON, no file parameter)
    private func tryOpenStreamWithIdParameter(id: String, idInt: Int) async throws -> PlaybackInfo {
        let openURL = baseURL.appendingPathComponent("/webapi/VideoStation/vtestreaming.cgi")

        var openRequest = URLRequest(url: openURL)
        openRequest.httpMethod = "POST"
        openRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Try just id parameter, no file, no JSON
        let formBody = "id=\(idInt)"

        openRequest.httpBody = formBody.data(using: .utf8)

        // Set cookie
        if let sessionID = sessionID {
            openRequest.setValue("id=\(sessionID)", forHTTPHeaderField: "Cookie")
        }

        Self.logger.debug("Retry 3: POST with just id=\(idInt) (no file parameter)")
        Self.logger.debug("  Body: \(formBody) (\(formBody.data(using: .utf8)?.count ?? 0) bytes)")

        let (openData, openResponse) = try await URLSession.shared.data(for: openRequest)

        guard let httpResponse = openResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorString = String(data: openData, encoding: .utf8) {
                Self.logger.error("Retry 3 failed: \(errorString)")
            }
            throw WebAPIError.http(httpResponse.statusCode)
        }

        let responseString = String(data: openData, encoding: .utf8) ?? ""
        Self.logger.debug("Retry 3 response: \(responseString)")

        // Check for error
        if let errorResponse = try? JSONDecoder().decode(WebAPIErrorResponse.self, from: openData) {
            throw WebAPIError.server(errorResponse.error.code, errorResponse.error.errors)
        }

        // Extract stream_id
        var streamId: String?
        if let jsonData = try? JSONDecoder().decode([String: String].self, from: openData),
           let id = jsonData["stream_id"] ?? jsonData["id"] {
            streamId = id
        } else if let jsonData = try? JSONDecoder().decode(WebAPIResponse<VideoStationStreamOpenData>.self, from: openData),
                  jsonData.success,
                  let data = jsonData.data,
                  let id = data.stream_id {
            streamId = id
        } else {
            let trimmed = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count > 10 && !trimmed.contains("error") {
                streamId = trimmed
            }
        }

        guard let streamId = streamId else {
            throw WebAPIError.server(-1, ["Failed to get stream_id from retry 3"])
        }

        Self.logger.info("Got stream_id from retry 3: \(streamId)")
        return try await getStreamURL(streamId: streamId)
    }

    /// Try opening stream with API params + file JSON (URL-encoded)
    private func tryOpenStreamWithAPIParams(id: String, idInt: Int) async throws -> PlaybackInfo {
        let openURL = baseURL.appendingPathComponent("/webapi/VideoStation/vtestreaming.cgi")

        var openRequest = URLRequest(url: openURL)
        openRequest.httpMethod = "POST"
        openRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Try API params + file JSON (URL-encoded)
        let fileJSON = "{\"id\":\(idInt),\"library_id\":0}"
        var formBody = "api=SYNO.VideoStation.Streaming&version=1&method=open"
        if let encodedJSON = fileJSON.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) {
            formBody += "&file=\(encodedJSON)"
        } else {
            formBody += "&file=\(fileJSON)"
        }

        openRequest.httpBody = formBody.data(using: .utf8)

        // Set cookie
        if let sessionID = sessionID {
            openRequest.setValue("id=\(sessionID)", forHTTPHeaderField: "Cookie")
        }

        let bodySize = formBody.data(using: .utf8)?.count ?? 0
        Self.logger.debug("Retry 3: POST with API params + file JSON (URL-encoded)")
        Self.logger.debug("  Body size: \(bodySize) bytes")

        let (openData, openResponse) = try await URLSession.shared.data(for: openRequest)

        guard let httpResponse = openResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorString = String(data: openData, encoding: .utf8) {
                Self.logger.error("Retry 3 failed: \(errorString)")
            }
            throw WebAPIError.http(httpResponse.statusCode)
        }

        let responseString = String(data: openData, encoding: .utf8) ?? ""
        Self.logger.debug("Retry 3 response: \(responseString)")

        // Check for error
        if let errorResponse = try? JSONDecoder().decode(WebAPIErrorResponse.self, from: openData) {
            throw WebAPIError.server(errorResponse.error.code, errorResponse.error.errors)
        }

        // Extract stream_id
        var streamId: String?
        if let jsonData = try? JSONDecoder().decode([String: String].self, from: openData),
           let id = jsonData["stream_id"] ?? jsonData["id"] {
            streamId = id
        } else if let jsonData = try? JSONDecoder().decode(WebAPIResponse<VideoStationStreamOpenData>.self, from: openData),
                  jsonData.success,
                  let data = jsonData.data,
                  let id = data.stream_id {
            streamId = id
        } else {
            let trimmed = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count > 10 && !trimmed.contains("error") {
                streamId = trimmed
            }
        }

        guard let streamId = streamId else {
            throw WebAPIError.server(-1, ["Failed to get stream_id from retry 3"])
        }

        Self.logger.info("Got stream_id from retry 3: \(streamId)")
        return try await getStreamURL(streamId: streamId)
    }

    /// Try opening stream with API params + file JSON + _sid in body (might match 116 bytes)
    private func tryOpenStreamWithAPIParamsAndSid(id: String, idInt: Int) async throws -> PlaybackInfo {
        let openURL = baseURL.appendingPathComponent("/webapi/VideoStation/vtestreaming.cgi")

        var openRequest = URLRequest(url: openURL)
        openRequest.httpMethod = "POST"
        openRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Try API params + file JSON + _sid in body (this might be the 116-byte format)
        let fileJSON = "{\"id\":\(idInt),\"library_id\":0}"
        var formBody = "api=SYNO.VideoStation.Streaming&version=1&method=open"
        if let encodedJSON = fileJSON.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) {
            formBody += "&file=\(encodedJSON)"
        } else {
            formBody += "&file=\(fileJSON)"
        }

        // Add _sid to body (might be needed for 116-byte format)
        if let sessionID = sessionID {
            formBody += "&_sid=\(sessionID)"
        }

        openRequest.httpBody = formBody.data(using: .utf8)

        // Also set cookie
        if let sessionID = sessionID {
            openRequest.setValue("id=\(sessionID)", forHTTPHeaderField: "Cookie")
        }

        let bodySize = formBody.data(using: .utf8)?.count ?? 0
        Self.logger.debug("Retry 4: POST with API params + file JSON + _sid")
        Self.logger.debug("  Body size: \(bodySize) bytes (target: 116)")

        let (openData, openResponse) = try await URLSession.shared.data(for: openRequest)

        guard let httpResponse = openResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorString = String(data: openData, encoding: .utf8) {
                Self.logger.error("Retry 4 failed: \(errorString)")
            }
            throw WebAPIError.http(httpResponse.statusCode)
        }

        let responseString = String(data: openData, encoding: .utf8) ?? ""
        Self.logger.debug("Retry 4 response: \(responseString)")

        // Check for error
        if let errorResponse = try? JSONDecoder().decode(WebAPIErrorResponse.self, from: openData) {
            throw WebAPIError.server(errorResponse.error.code, errorResponse.error.errors)
        }

        // Extract stream_id
        var streamId: String?
        if let jsonData = try? JSONDecoder().decode([String: String].self, from: openData),
           let id = jsonData["stream_id"] ?? jsonData["id"] {
            streamId = id
        } else if let jsonData = try? JSONDecoder().decode(WebAPIResponse<VideoStationStreamOpenData>.self, from: openData),
                  jsonData.success,
                  let data = jsonData.data,
                  let id = data.stream_id {
            streamId = id
        } else {
            let trimmed = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count > 10 && !trimmed.contains("error") {
                streamId = trimmed
            }
        }

        guard let streamId = streamId else {
            throw WebAPIError.server(-1, ["Failed to get stream_id from retry 4"])
        }

        Self.logger.info("Got stream_id from retry 4: \(streamId)")
        return try await getStreamURL(streamId: streamId)
    }

    /// Try opening stream with file parameter as JSON (fallback for error 101)
    private func tryOpenStreamWithFileJSON(id: String, idInt: Int) async throws -> PlaybackInfo {
        let openURL = baseURL.appendingPathComponent("/webapi/VideoStation/vtestreaming.cgi")

        var openRequest = URLRequest(url: openURL)
        openRequest.httpMethod = "POST"
        openRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Try file parameter as JSON string (without library_id)
        let fileJSON = "{\"id\":\(idInt)}"
        let formBody = "file=\(fileJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileJSON)"

        openRequest.httpBody = formBody.data(using: .utf8)

        // Set cookie - official app uses Cookie header with id=<session_id>
        if let sessionID = sessionID {
            openRequest.setValue("id=\(sessionID)", forHTTPHeaderField: "Cookie")
        }

        Self.logger.debug("Retry: POST to vtestreaming.cgi with file JSON")
        Self.logger.debug("  Body: \(formBody)")

        let (openData, openResponse) = try await URLSession.shared.data(for: openRequest)

        guard let httpResponse = openResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorString = String(data: openData, encoding: .utf8) {
                Self.logger.error("Retry failed: \(errorString)")
            }
            throw WebAPIError.http(httpResponse.statusCode)
        }

        let responseString = String(data: openData, encoding: .utf8) ?? ""
        Self.logger.debug("Retry response: \(responseString)")

        // Check for error
        if let errorResponse = try? JSONDecoder().decode(WebAPIErrorResponse.self, from: openData) {
            throw WebAPIError.server(errorResponse.error.code, errorResponse.error.errors)
        }

        // Extract stream_id
        var streamId: String?
        if let jsonData = try? JSONDecoder().decode([String: String].self, from: openData),
           let id = jsonData["stream_id"] ?? jsonData["id"] {
            streamId = id
        } else if let jsonData = try? JSONDecoder().decode(WebAPIResponse<VideoStationStreamOpenData>.self, from: openData),
                  jsonData.success,
                  let data = jsonData.data,
                  let id = data.stream_id {
            streamId = id
        } else {
            let trimmed = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count > 10 && !trimmed.contains("error") {
                streamId = trimmed
            }
        }

        guard let streamId = streamId else {
            throw WebAPIError.server(-1, ["Failed to get stream_id from retry"])
        }

        Self.logger.info("Got stream_id from retry: \(streamId)")
        return try await getStreamURL(streamId: streamId)
    }

    /// Helper: Get streaming URL using stream_id (official app format)
    private func getStreamURL(streamId: String) async throws -> PlaybackInfo {
        // Official app uses: GET /webapi/VideoStation/vtestreaming.cgi/DTV.mov
        // with query: api=SYNO.VideoStation.Streaming&version=1&method=stream&id=<stream_id>&format=raw&_sid=<session_id>
        var streamComponents = URLComponents(url: baseURL.appendingPathComponent("/webapi/VideoStation/vtestreaming.cgi/DTV.mov"), resolvingAgainstBaseURL: false)!
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
        var components = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false)!
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
        // Try movie first
        do {
            return try await getPlayback(id: id, type: "movie")
        } catch {
            return try await getPlayback(id: id, type: "tvshow")
        }
    }

    /// Adapter: setProgress() - matches APIClient interface
    func setProgress(id: String, positionSeconds: Int, durationSeconds: Int) async throws {
        try await updateProgress(id: id, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    }
}
