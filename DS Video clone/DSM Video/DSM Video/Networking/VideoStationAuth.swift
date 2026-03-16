import Foundation
import OSLog

/// Client for Synology Video Station WebAPI
/// Video Station uses Synology's WebAPI format: /webapi/entry.cgi?api=SYNO.API.*
struct VideoStationWebAPIClient {
    static let logger = Logger(subsystem: "com.heiloprojects.dsreel", category: "VideoStationAPI")
    let baseURL: URL
    var sessionID: String?
    var synoToken: String?
    var deviceID: String?  // Device ID (did) from login - needed for Cookie header

    init(baseURL: URL, sessionID: String? = nil, synoToken: String? = nil, deviceID: String? = nil) {
        self.baseURL = baseURL
        self.sessionID = sessionID
        self.synoToken = synoToken
        self.deviceID = deviceID
    }

    /// Create a new client with updated session
    func withSession(sid: String?, token: String?, deviceID: String? = nil) -> VideoStationWebAPIClient {
        VideoStationWebAPIClient(baseURL: baseURL, sessionID: sid, synoToken: token, deviceID: deviceID)
    }

    // MARK: - Authentication

    /// Login using DSM credentials
    /// GET /webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=login&account=<USERNAME>&passwd=<PASSWORD>
    func login(account: String, passwd: String) async throws -> WebAPILoginResponse {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/webapi/entry.cgi"), resolvingAgainstBaseURL: false) else {
            throw WebAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "6"),
            URLQueryItem(name: "method", value: "login"),
            URLQueryItem(name: "account", value: account),
            URLQueryItem(name: "passwd", value: passwd),
        ]

        guard let url = components.url else {
            throw WebAPIError.invalidURL
        }

        let safeURL = "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
        Self.logger.info("Login request to: \(safeURL, privacy: .public)")

        // Login doesn't need session ID, so create a temporary request
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Set longer timeout for login (30 seconds)
        request.timeoutInterval = 30.0

        let (data, httpResponse): (Data, URLResponse)
        do {
            (data, httpResponse) = try await URLSession.shared.data(for: request)
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
            Self.logger.error("Login request timed out after 30 seconds")
            throw WebAPIError.network
        } catch {
            Self.logger.error("Login network error: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                Self.logger.debug("  Error domain: \(nsError.domain), code: \(nsError.code)")
            }
            throw WebAPIError.network
        }

        guard let httpResponse = httpResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebAPIError.http(httpResponse.statusCode)
        }

        // Log raw response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            Self.logger.debug("Login response: \(responseString.prefix(500))")
        }

        let response: WebAPIResponse<WebAPILoginData> = try JSONDecoder().decode(WebAPIResponse<WebAPILoginData>.self, from: data)

        Self.logger.debug("Login response decoded - success: \(response.success)")

        guard response.success, let loginData = response.data else {
            let errorCode = response.error?.code ?? -1
            let errorMsg = response.error?.errors?.joined(separator: ", ") ?? "Unknown error"
            Self.logger.error("Login failed: code=\(errorCode), errors=\(errorMsg)")
            throw WebAPIError.loginFailed
        }

        Self.logger.info("Login successful - sid: \(loginData.sid.prefix(20))..., synotoken: \(loginData.synotoken?.prefix(20) ?? "nil")..., did: \(loginData.did?.prefix(20) ?? "nil")...")

        return WebAPILoginResponse(
            sid: loginData.sid,
            synotoken: loginData.synotoken,
            did: loginData.did
        )
    }

    // MARK: - Core Request

    func request<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        var finalURL = url

        // Add session ID if available (avoid duplication if already in URL)
        if let sessionID = sessionID {
            guard var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false) else {
                throw WebAPIError.invalidURL
            }
            var queryItems = components.queryItems ?? []

            // Check if _sid already exists
            if !queryItems.contains(where: { $0.name == "_sid" }) {
                queryItems.append(URLQueryItem(name: "_sid", value: sessionID))
                components.queryItems = queryItems
                if let newURL = components.url {
                    finalURL = newURL
                }
            }
        }

        // Add SynoToken if available (Video Station may require this for CSRF protection)
        if let synoToken = synoToken {
            guard var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false) else {
                throw WebAPIError.invalidURL
            }
            var queryItems = components.queryItems ?? []

            // Check if SynoToken already exists
            if !queryItems.contains(where: { $0.name == "SynoToken" }) {
                queryItems.append(URLQueryItem(name: "SynoToken", value: synoToken))
                components.queryItems = queryItems
                if let newURL = components.url {
                    finalURL = newURL
                }
            }
        }

        request.url = finalURL

        Self.logger.debug("Request URL: \(finalURL.absoluteString)")

        let (data, httpResponse) = try await URLSession.shared.data(for: request)

        guard let httpResponse = httpResponse as? HTTPURLResponse else {
            throw WebAPIError.network
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebAPIError.http(httpResponse.statusCode)
        }

        // Log raw response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            Self.logger.debug("Raw response: \(responseString.prefix(500))")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Try to decode error response
            if let errorResponse = try? JSONDecoder().decode(WebAPIErrorResponse.self, from: data) {
                Self.logger.error("API error response: code=\(errorResponse.error.code), errors=\(errorResponse.error.errors ?? [])")
                throw WebAPIError.server(errorResponse.error.code, errorResponse.error.errors)
            }

            // Log the actual response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                Self.logger.warning("Failed to decode response. URL: \(finalURL)")
                Self.logger.warning("Response: \(responseString.prefix(500))")
            }

            throw WebAPIError.decode(error)
        }
    }
}
