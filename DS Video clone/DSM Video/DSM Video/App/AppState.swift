import Foundation
import Network
import Observation
import Security
import SwiftUI
import os.log
#if canImport(UIKit)
import UIKit
#endif

// TASK-363: nonisolated(unsafe) so computeHomeRails (nonisolated) can access these without
// MainActor isolation. Safe: both are immutable after init and ISO8601DateFormatter is
// read-only once configured.
private nonisolated(unsafe) let homeRailsFormatterFrac: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()
private nonisolated(unsafe) let homeRailsFormatter: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime]
  return f
}()

@MainActor
@Observable
final class AppState {
  @ObservationIgnored
  @AppStorage("dsReel.qualityCap") var qualityCap: String = "auto"

  /// Non-routable placeholder used when the stored URL is empty or malformed at init time.
  /// Uses HTTPS so ATS doesn't block it; requests fail silently since 0.0.0.0 is unreachable.
  static let fallbackURL = URL(string: "https://0.0.0.0")!
  private enum Keys {
    static let baseURL = "dsReel.baseURL"
    static let lanAddress = "dsReel.lanAddress"
    static let wanAddress = "dsReel.wanAddress"
    static let username = "dsReel.username"
    static let rememberMe = "dsReel.rememberMe"
    static let useHTTPS = "dsReel.useHTTPS"
    static let defaultPort = "dsReel.defaultPort"
    static let keychainService = "com.heiloprojects.dsreel"
    static let keychainAccount = "savedPassword"
    static let keychainAccountToken = "sessionToken"
  }

  var baseURL: String {
    didSet {
      UserDefaults.standard.set(baseURL, forKey: Keys.baseURL)
      updateAPI()
    }
  }

  /// Local network address (e.g. 192.168.1.100). Optional — set alongside wanAddress
  /// for automatic LAN/WAN switching. When set, login() tries this first with a 2s timeout.
  var lanAddress: String {
    didSet { UserDefaults.standard.set(lanAddress, forKey: Keys.lanAddress) }
  }

  /// Remote address (e.g. mynas.duckdns.org or a Tailscale IP). Optional.
  var wanAddress: String {
    didSet { UserDefaults.standard.set(wanAddress, forKey: Keys.wanAddress) }
  }
  var username: String {
    didSet { UserDefaults.standard.set(username, forKey: Keys.username) }
  }
  var rememberMe: Bool {
    didSet { UserDefaults.standard.set(rememberMe, forKey: Keys.rememberMe) }
  }
  var useHTTPS: Bool {
    didSet {
      UserDefaults.standard.set(useHTTPS, forKey: Keys.useHTTPS)
      updateAPI()
    }
  }
  var defaultPort: Int {
    didSet {
      UserDefaults.standard.set(defaultPort, forKey: Keys.defaultPort)
      updateAPI()
    }
  }

  var isDemoMode: Bool { sessionToken == "demo" }

  /// True when the user has previously connected — saved address and password exist.
  /// Used to skip the setup wizard and go straight to the credentials screen.
  var isReturningUser: Bool {
    let addr = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !addr.isEmpty && addr != "http://localhost:5000" && !savedPassword.isEmpty
  }

  var isOffline: Bool = false
  var serverUnreachable: Bool = false
  // FIX-16: Guard flag so concurrent reconnect() calls don't race.
  var isReconnecting: Bool = false

  private var networkMonitor: NWPathMonitor?
  private var heartbeatTimer: Timer?
  private var reconnectRetryTask: Task<Void, Never>?

  var sessionToken: String? {
    didSet {
      if rememberMe {
        guard !isDemoMode else {
          updateAPI()
          return
        }
        if let token = sessionToken {
          Self.saveToKeychain(token, account: Keys.keychainAccountToken)
        } else {
          Self.deleteFromKeychain(account: Keys.keychainAccountToken)
        }
      }
      updateAPI()
    }
  }
  var isLoggingIn: Bool = false
  var loginError: String?

  var pairingCode: String?
  var pairingCodeExpiresInSeconds: Int = 600
  var isGeneratingPairingCode: Bool = false
  var pairingError: String?

  var savedPassword: String = ""

  // Use custom REST API client (our backend)
  private(set) var api: APIClient

  private func updateAPI() {
    // If baseURL is a bare QuickConnect ID, we can't build a usable URL without
    // resolving it first — leave api as-is. login() will resolve and set api correctly.
    if QuickConnectResolver.extractBareID(from: baseURL) != nil { return }
    guard let url = normalizedBaseURL(baseURL, forceHTTPS: useHTTPS, defaultPort: defaultPort) else {
      return
    }
    api = APIClient(
      baseURL: url,
      token: sessionToken
    )
  }

  init() {
    let d = UserDefaults.standard
    let storedBaseURL = d.string(forKey: Keys.baseURL) ?? "http://localhost:5000"
    // useHTTPS defaults to false — port 5000 is plain HTTP; login() auto-detects
    // and persists the correct scheme from whichever candidate wins.
    let storedUseHTTPS = d.object(forKey: Keys.useHTTPS) as? Bool ?? false
    let storedRememberMe = d.object(forKey: Keys.rememberMe) as? Bool ?? true
    let storedDefaultPort = d.object(forKey: Keys.defaultPort) as? Int ?? 5000

    baseURL = storedBaseURL
    lanAddress = d.string(forKey: Keys.lanAddress) ?? ""
    wanAddress = d.string(forKey: Keys.wanAddress) ?? ""
    username = d.string(forKey: Keys.username) ?? ""
    rememberMe = storedRememberMe
    useHTTPS = storedUseHTTPS
    defaultPort = storedDefaultPort

    // Always load password from Keychain — rememberMe controls session token only.
    // This ensures soft-logout (auto-reconnect recovery) pre-fills the login form.
    savedPassword = Self.loadFromKeychain(account: Keys.keychainAccount) ?? ""
    var storedToken: String? = nil
    if storedRememberMe {
      storedToken = Self.loadFromKeychain(account: Keys.keychainAccountToken)
    }
    sessionToken = storedToken

    // Initialize stored api client once with all resolved values.
    // If baseURL is a bare QuickConnect ID, skip building a URL — login() resolves it.
    // normalizedBaseURL returns nil for invalid URLs (empty, malformed). In that case we
    // use a non-routable placeholder; login() validates the URL before any request fires.
    let isQCID = QuickConnectResolver.extractBareID(from: storedBaseURL) != nil
    let resolvedInitURL = isQCID ? Self.fallbackURL
      : (normalizedBaseURL(storedBaseURL, forceHTTPS: storedUseHTTPS, defaultPort: storedDefaultPort) ?? Self.fallbackURL)
    api = APIClient(
      baseURL: resolvedInitURL,
      token: storedToken
    )
    startNetworkMonitoring()
    startHeartbeatTimer()
    // SEC-02: proactively check JWT expiry so users aren't surprised by mid-session logout.
    if storedToken != nil {
      Task { @MainActor [weak self] in await self?.checkTokenExpiryOnLaunch() }
    }
  }

  // MARK: - JWT Expiry (SEC-02)

  /// Decodes the `exp` claim from a JWT without validating the signature.
  /// Returns nil if the token is malformed or has no exp claim.
  private static func jwtExpiry(token: String) -> Date? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var payload = String(parts[1])
    // Base64url → base64 padding
    let remainder = payload.count % 4
    if remainder != 0 { payload += String(repeating: "=", count: 4 - remainder) }
    payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = json["exp"] as? TimeInterval else { return nil }
    return Date(timeIntervalSince1970: exp)
  }

  /// Called on app launch when a stored token exists. If the token is already expired,
  /// clears state and forces re-login. If expiry is within 24 hours, attempts a proactive refresh.
  @MainActor
  private func checkTokenExpiryOnLaunch() async {
    guard let token = sessionToken, !isDemoMode else { return }
    guard let expiry = Self.jwtExpiry(token: token) else { return }
    let now = Date()
    if expiry <= now {
      // Already expired — force re-login immediately.
      Self.deleteFromKeychain(account: Keys.keychainAccountToken)
      sessionToken = nil
      loginError = "Your session expired. Please sign in again."
      return
    }
    let twentyFourHours: TimeInterval = 24 * 60 * 60
    if expiry.timeIntervalSince(now) < twentyFourHours {
      // Expiring soon — schedule a silent refresh after the home screen has loaded
      // to avoid racing with homeLoad()'s own QC resolution and api mutation.
      if !savedPassword.isEmpty {
        Task { @MainActor [weak self] in
          // Brief yield so init's Task and homeLoad() settle first.
          try? await Task.sleep(nanoseconds: 2_000_000_000)
          await self?.login()
        }
      }
    }
  }

  // MARK: - Keychain

  private static func saveToKeychain(_ value: String, account: String) {
    let data = Data(value.utf8)
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Keys.keychainService,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(deleteQuery as CFDictionary)
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Keys.keychainService,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    SecItemAdd(addQuery as CFDictionary, nil)
  }

  private static func loadFromKeychain(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Keys.keychainService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteFromKeychain(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Keys.keychainService,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }

  func setPassword(_ value: String) {
    savedPassword = value
  }

  // MARK: - Candidate Resolution

  /// Builds an ordered list of candidate URLs to try for login/reconnect.
  ///
  /// Priority order:
  ///   1. LAN address (2s timeout) — fastest when on home network
  ///   2. WAN address (8s timeout) — used when LAN unreachable or not set
  ///   3. QuickConnect candidates (LAN→WAN→relay) — when baseURL is a QC ID
  ///   4. baseURL directly — legacy / single-address fallback
  ///
  /// Returns `QuickConnectResolver.Candidate` so callers get the tunnel-cookie
  /// flag for free — LAN/WAN direct candidates always have requiresTunnelCookie=false.
  func buildCandidates() async throws -> [QuickConnectResolver.Candidate] {
    let lan = lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let wan = wanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

    var candidates: [QuickConnectResolver.Candidate] = []

    func addDirect(_ address: String) {
      guard !address.isEmpty else { return }
      if let qcID = QuickConnectResolver.extractBareID(from: address) {
        // QC IDs handled separately below
        _ = qcID
        return
      }
      guard let url = normalizedBaseURL(address, forceHTTPS: useHTTPS, defaultPort: defaultPort) else { return }
      candidates.append(.init(url: url, requiresTunnelCookie: false))
    }

    // LAN first — short timeout callers know to use 2s for these
    addDirect(lan)
    // WAN second
    addDirect(wan)

    // If baseURL is a QC ID, append its full cascade after direct addresses
    if let qcID = QuickConnectResolver.extractBareID(from: raw) {
      let qcCandidates = (try? await QuickConnectResolver.resolveCandidates(id: qcID)) ?? []
      // Avoid duplicating any LAN IP that QC also resolved
      let existing = Set(candidates.map(\.url.absoluteString))
      for c in qcCandidates where !existing.contains(c.url.absoluteString) {
        candidates.append(c)
      }
    } else if lan.isEmpty && wan.isEmpty {
      // No dual addresses — fall back to baseURL directly
      addDirect(raw)
    }

    return candidates
  }

  func login() async {
    loginError = nil
    isLoggingIn = true
    defer { isLoggingIn = false }

    // Demo mode — App Review credentials. No network required.
    if username.trimmingCharacters(in: .whitespaces).lowercased() == "appledemo" &&
       savedPassword.trimmingCharacters(in: .whitespaces).lowercased() == "dsvideo2024" {
      // Clear any real NAS data that may have loaded before demo login
      homeLibraries = DemoData.libraries
      let demoItems = DemoData.movieItems + DemoData.tvItems
      recomputeHomeRails(from: demoItems)
      sessionToken = "demo"
      startHeartbeatTimer()
      return
    }

    do {
      let candidates = try await buildCandidates()
      guard !candidates.isEmpty else {
        loginError = "Invalid server address. Please check the URL."
        return
      }

      let lanCount = { () -> Int in
        let lan = lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return lan.isEmpty ? 0 : 1
      }()

      var lastError: Error?
      for (index, candidate) in candidates.enumerated() {
        do {
          var tempClient = APIClient(baseURL: candidate.url, token: nil)
          tempClient.usesTunnelCookie = candidate.requiresTunnelCookie
          // LAN candidates (first lanCount entries) get 2s — fail-fast so WAN isn't delayed
          // when the user is away from home. Relay gets 15s. WAN direct gets 8s.
          let timeout: TimeInterval
          if candidate.requiresTunnelCookie {
            timeout = 15
          } else if index < lanCount {
            timeout = 2
          } else {
            timeout = 8
          }
          homeLog.info("login: trying \(candidate.url) tunnel=\(candidate.requiresTunnelCookie) timeout=\(timeout)s")
          let resp = try await tempClient.login(username: username, password: savedPassword, timeoutInterval: timeout)
          sessionToken = resp.token
          clearNetworkError()
          api = APIClient(baseURL: candidate.url, token: resp.token, usesTunnelCookie: candidate.requiresTunnelCookie)
          // Update baseURL to the winning candidate so reconnect() has a real URL to probe.
          // Skip relay candidates — relay URLs are ephemeral edge addresses.
          if !candidate.requiresTunnelCookie {
            baseURL = candidate.url.absoluteString
            self.useHTTPS = candidate.url.scheme == "https"
            if let port = candidate.url.port { self.defaultPort = port }
          }
          if !savedPassword.isEmpty {
            Self.saveToKeychain(savedPassword, account: Keys.keychainAccount)
          }
          startHeartbeatTimer()
          return
        } catch {
          homeLog.warning("login: \(candidate.url) failed — \(error.localizedDescription)")
          lastError = error
        }
      }
      let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if let qcID = QuickConnectResolver.extractBareID(from: raw) {
        loginError = "Couldn't find \"\(qcID)\". Check the QuickConnect ID and try again."
      } else {
        loginError = (lastError as? APIError)?.userMessage ?? "Login failed. Check that DSVideoServer is running on your NAS."
      }
    } catch {
      loginError = (error as? APIError)?.userMessage ?? "Login failed."
    }
  }

  func logout() {
    Self.deleteFromKeychain(account: Keys.keychainAccountToken)
    Self.deleteFromKeychain(account: Keys.keychainAccount)
    savedPassword = ""
    username = ""  // SEC-03: clear username so it doesn't persist cross-user on shared devices
    sessionToken = nil
    pairingCode = nil
    loginError = nil
    watchlistItems = []
    reconnectRetryTask?.cancel()
    reconnectRetryTask = nil
    stopHeartbeatTimer()  // TASK-428: prevent timer from firing after logout
    clearHomeState()
  }

  /// Clears the session token (shows login screen) but keeps username and password
  /// so the user can reconnect with a single tap of the Connect button.
  /// Used for automatic session recovery when cold-start connection fails.
  func softLogout(reason: String) {
    Self.deleteFromKeychain(account: Keys.keychainAccountToken)
    sessionToken = nil
    pairingCode = nil
    loginError = reason
    watchlistItems = []
    reconnectRetryTask?.cancel()
    reconnectRetryTask = nil
    stopHeartbeatTimer()
    clearHomeState()
    // Keep savedPassword and username intact so Connect works immediately.
  }

  /// Called when a network operation fails. Distinguishes:
  ///   - Auth failure (401/403) → clear session, force re-login
  ///   - No internet → set isOffline (NWPathMonitor manages recovery)
  ///   - Server unreachable → set serverUnreachable
  ///   - Transient errors → no state change
  /// Does NOT auto-logout on network errors — the user should stay logged in
  /// and resume automatically when connectivity returns.
  func handleConnectionFailure(_ error: Error) {
    if let apiErr = error as? APIError {
      switch apiErr {
      case .http(401), .http(403):
        // Token expired or rejected — must re-authenticate
        Self.deleteFromKeychain(account: Keys.keychainAccountToken)
        sessionToken = nil
        watchlistItems = []  // prevent stale watchlist briefly visible on the login screen
        loginError = "Your session expired. Please sign in again."
      case .network:
        serverUnreachable = true
      default:
        break  // transient, don't change state
      }
    } else if let urlErr = error as? URLError {
      switch urlErr.code {
      case .notConnectedToInternet, .networkConnectionLost:
        isOffline = true
      case .cannotConnectToHost, .cannotFindHost, .timedOut,
           .dnsLookupFailed, .secureConnectionFailed:
        serverUnreachable = true
      default:
        break
      }
    }
  }

  /// Call after a successful API operation to clear network error state.
  /// Both flags cleared here; NWPathMonitor also clears isOffline independently on path recovery.
  /// NOTE: reconnectRetryTask lifecycle is managed only by startBackgroundReconnectRetry() and
  /// logout() — not here. Cancelling from clearNetworkError() would self-cancel the retry task
  /// before homeLoad() runs on the success path (Issue 7).
  func clearNetworkError() {
    serverUnreachable = false
    isOffline = false
  }

  /// Re-resolves QC candidates and updates api to the first reachable one.
  /// For direct IP/hostname servers, probes the current api to verify connectivity.
  /// Returns true if a working connection was found.
  func reconnect() async -> Bool {
    // FIX-16: Prevent concurrent reconnect calls from racing.
    guard !isReconnecting else { return false }
    isReconnecting = true
    defer { isReconnecting = false }

    guard sessionToken != nil else { return false }
    guard let candidates = try? await buildCandidates(), !candidates.isEmpty else { return false }

    let lanCount = { () -> Int in
      let lan = lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
      return lan.isEmpty ? 0 : 1
    }()

    for (index, candidate) in candidates.enumerated() {
      let probe = APIClient(baseURL: candidate.url, token: sessionToken, usesTunnelCookie: candidate.requiresTunnelCookie)
      let versionTimeout: TimeInterval
      if candidate.requiresTunnelCookie { versionTimeout = 15 }
      else if index < lanCount { versionTimeout = 2 }
      else { versionTimeout = 4 }
      let statusTimeout: TimeInterval = candidate.requiresTunnelCookie ? 20 : 10

      guard (try? await probe.serverVersion(timeout: versionTimeout)) != nil else {
        homeLog.info("reconnect: \(candidate.url) unreachable — skipping")
        continue
      }
      do {
        _ = try await probe.syncStatus(timeout: statusTimeout)
        homeLog.info("reconnect: \(candidate.url) fully verified — using")
        api = probe
        if !candidate.requiresTunnelCookie { baseURL = candidate.url.absoluteString }
        clearNetworkError()
        return true
      } catch let err as APIError {
        if case .http(401) = err {
          homeLog.warning("reconnect: token rejected by \(candidate.url) — triggering session expiry")
          handleConnectionFailure(err)
          return false
        }
        homeLog.info("reconnect: \(candidate.url) returned API error but is reachable — using")
        api = probe
        if !candidate.requiresTunnelCookie { baseURL = candidate.url.absoluteString }
        clearNetworkError()
        return true
      } catch {
        homeLog.warning("reconnect: \(candidate.url) /version ok but syncStatus failed — skipping")
        continue
      }
    }
    return false
  }

  /// Retries QC resolution in the background every ~8s for up to 5 minutes.
  /// On success: clears serverUnreachable and triggers a fresh homeLoad.
  /// Called when homeLoad() can't reach the server on cold start.
  private func startBackgroundReconnectRetry() {
    reconnectRetryTask?.cancel()
    reconnectRetryTask = Task { @MainActor in
      // Exponential backoff: 5, 10, 20, 30, 30, 30... seconds (capped at 30).
      // 20 attempts ≈ 10 min max. QC resolution can take up to ~24s per attempt
      // so a flat 8s delay caused attempts to pile up behind isReconnecting.
      let maxAttempts = 20
      var delay: Double = 5
      for attempt in 1...maxAttempts {
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        guard sessionToken != nil else { return }  // logged out — stop retrying
        homeLog.info("backgroundReconnect: attempt \(attempt)/\(maxAttempts) (delay was \(delay)s)")
        let ok = await reconnect()
        if ok {
          homeLog.info("backgroundReconnect: succeeded on attempt \(attempt) — url=\(self.api.baseURL)")
          // Nil the task handle BEFORE reconnect()'s clearNetworkError() path fires,
          // so the cancel() it used to call doesn't abort this task mid-flight.
          reconnectRetryTask = nil
          serverUnreachable = false
          startHeartbeatTimer()
          await homeLoad()
          return
        }
        delay = min(delay * 2, 30)
      }
      homeLog.warning("backgroundReconnect: all \(maxAttempts) attempts exhausted — soft-logging out for clean reconnect")
      serverUnreachable = false
      softLogout(reason: "Connection could not be restored. Sign in again to reconnect.")
    }
  }

  private func startHeartbeatTimer() {
    guard heartbeatTimer == nil else { return }  // guard against double-start
    heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.sessionToken != nil else { return }  // guard: no-op before login
        await self.runHeartbeat()
      }
    }
  }

  private func stopHeartbeatTimer() {
    heartbeatTimer?.invalidate()
    heartbeatTimer = nil
  }

  private func startNetworkMonitoring() {
    let monitor = NWPathMonitor()
    networkMonitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let wasOffline = self.isOffline
        self.isOffline = path.status != .satisfied
        if wasOffline && !self.isOffline {
          NotificationCenter.default.post(name: .networkDidReconnect, object: nil)
        }
        // When already logged in with dual addresses, silently re-probe on any
        // network change so the app switches between LAN and WAN automatically.
        let hasLAN = !self.lanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWAN = !self.wanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasLAN && hasWAN && self.sessionToken != nil && path.status == .satisfied {
          Task { @MainActor [weak self] in
            guard let self, !self.isReconnecting else { return }
            homeLog.info("networkMonitor: path changed with dual addresses — re-probing")
            _ = await self.reconnect()
          }
        }
      }
    }
    monitor.start(queue: DispatchQueue(label: "com.dsm.networkMonitor"))
  }

  func generatePairingCode() async {
    guard !isDemoMode else { return }
    pairingError = nil
    isGeneratingPairingCode = true
    defer { isGeneratingPairingCode = false }

    guard sessionToken != nil else {
      pairingError = "Must be logged in to generate pairing code."
      return
    }

    do {
      let resp = try await api.generatePairingCode()
      pairingCode = resp.code
      pairingCodeExpiresInSeconds = resp.expiresInSeconds
    } catch {
      pairingError = (error as? APIError)?.userMessage ?? "Failed to generate pairing code."
    }
  }

  func exchangePairingCode(_ code: String) async {
    loginError = nil
    isLoggingIn = true
    defer { isLoggingIn = false }

    let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

    // If baseURL is a QuickConnect ID, resolve candidates and try each with a
    // short timeout — same strategy as login() so external networks work.
    if let qcID = QuickConnectResolver.extractBareID(from: raw) {
      guard let candidates = try? await QuickConnectResolver.resolveCandidates(id: qcID), !candidates.isEmpty else {
        loginError = "Couldn't reach \"\(qcID)\". Check your connection and try again."
        return
      }
      var lastError: Error?
      for candidate in candidates {
        do {
          var client = APIClient(baseURL: candidate.url, token: nil)
          client.usesTunnelCookie = candidate.requiresTunnelCookie
          let resp = try await client.exchangePairingCode(code: code, timeoutInterval: 7)
          sessionToken = resp.token
          api = APIClient(baseURL: candidate.url, token: resp.token, usesTunnelCookie: candidate.requiresTunnelCookie)
          startHeartbeatTimer()
          return
        } catch {
          lastError = error
        }
      }
      loginError = (lastError as? APIError)?.userMessage ?? "Invalid pairing code."
      return
    }

    guard let serverURL = normalizedBaseURL(baseURL, forceHTTPS: useHTTPS, defaultPort: defaultPort) else {
      loginError = "Invalid server address. Please check the URL."
      return
    }

    do {
      let resp = try await APIClient(baseURL: serverURL, token: nil)
        .exchangePairingCode(code: code)
      sessionToken = resp.token
      startHeartbeatTimer()
    } catch {
      loginError = (error as? APIError)?.userMessage ?? "Invalid pairing code."
    }
  }

  // MARK: - Home Data

  private let homeLog = Logger(subsystem: "com.dsm.dsvideo", category: "HomeState")

  // Persistent across tab switches — populated once, never cleared unless logout/forceRefresh
  var homeLibraries: [Library] = []
  /// Bumped on homeForceRefresh so TVLibraryRail's .task(id:) re-triggers a fresh fetch.
  var libraryRailsVersion: UUID = UUID()
  var homeContinueWatching: [ItemSummary] = []
  var homeJustAdded: [ItemSummary] = [] {
    didSet { writeTopShelfSnapshot() }
  }
  var homeRecentlyWatched: [ItemSummary] = []

  // Loading state flags
  var homeIsLoading: Bool = false
  var homeIsCacheDecoding: Bool = false
  var homeIsBackgroundRefreshing: Bool = false
  var homeError: String?

  // Background fetch task handle — cancelled on forceRefresh/logout
  private var homeBackgroundFetchTask: Task<Void, Never>?

  func clearHomeState() {
    homeBackgroundFetchTask?.cancel()
    homeBackgroundFetchTask = nil
    homeLibraries = []
    homeContinueWatching = []
    homeJustAdded = []
    homeRecentlyWatched = []
    homeIsLoading = false
    homeIsCacheDecoding = false
    homeIsBackgroundRefreshing = false
    homeError = nil
  }

  var homeAllRailsEmpty: Bool {
    homeContinueWatching.isEmpty && homeJustAdded.isEmpty && homeRecentlyWatched.isEmpty
  }

  var homeFirstMovieLibrary: Library? {
    homeLibraries.first(where: { $0.kind == "movie" || $0.kind == "movies" }) ?? homeLibraries.first
  }

  var homeFirstTVLibrary: Library? {
    homeLibraries.first(where: { $0.kind == "tv" })
  }

  // MARK: - Rail Computation

  private func recomputeHomeRails(from items: [ItemSummary]) {
    homeLog.debug("recomputeHomeRails: triggered — \(items.count) items")
    let t = Date()
    Task.detached(priority: .userInitiated) { [weak self] in
      let (cont, added, watched) = Self.computeHomeRails(items)
      let elapsed = String(format: "%.3f", Date().timeIntervalSince(t))
      // Guard after the off-actor compute: if self was deallocated (e.g. logout)
      // during the heavy lift, silently drop the result (TASK-434).
      guard let self else { return }
      await MainActor.run {
        self.homeContinueWatching = cont
        self.homeJustAdded = added
        self.homeRecentlyWatched = watched
        self.homeLog.info("recomputeHomeRails: done in \(elapsed)s — cont=\(cont.count) added=\(added.count) watched=\(watched.count)")
      }
    }
  }


  nonisolated static func computeHomeRails(_ allItems: [ItemSummary])
    -> (continueWatching: [ItemSummary], justAdded: [ItemSummary], recentlyWatched: [ItemSummary])
  {
    let formatterFrac = homeRailsFormatterFrac
    let formatter = homeRailsFormatter
    func parseDate(_ iso: String) -> Date {
      formatterFrac.date(from: iso) ?? formatter.date(from: iso) ?? .distantPast
    }
    func deduplicated(_ items: [ItemSummary]) -> [ItemSummary] {
      var seen = Set<String>()
      return items.filter { seen.insert($0.title.lowercased() + "|\($0.type)").inserted }
    }
    func deduplicatedByShow(_ items: [ItemSummary]) -> [ItemSummary] {
      var seen = Set<String>()
      return items.filter { item in
        let key: String
        if let showName = item.showName, !showName.isEmpty {
          key = "tv|\(showName.lowercased())"
        } else if item.type == "episode" || item.seasonNumber != nil || item.episodeNumber != nil {
          let base = item.title
            .replacingOccurrences(of: #"\s+[Ss]\d+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+[Ee]\d+.*$"#, with: "", options: .regularExpression)
            .lowercased()
          key = "tv|\(base)"
        } else {
          key = item.title.lowercased() + "|\(item.type)"
        }
        return seen.insert(key).inserted
      }
    }

    let continueWatching = Array(deduplicated(
      allItems
        .filter { item in
          guard let p = item.progress, p.durationSeconds > 0, p.positionSeconds > 0 else { return false }
          let frac = Double(p.positionSeconds) / Double(p.durationSeconds)
          return frac >= 0.05 && frac < 0.95
        }
        .sorted { parseDate($0.progress?.updatedAt ?? $0.addedAt) > parseDate($1.progress?.updatedAt ?? $1.addedAt) }
    ).prefix(10))

    let recentlyWatched = deduplicated(
      allItems
        .filter { item in
          guard let p = item.progress, p.durationSeconds > 0 else { return false }
          return Double(p.positionSeconds) / Double(p.durationSeconds) >= 0.95
        }
        .sorted { parseDate($0.progress?.updatedAt ?? $0.addedAt) > parseDate($1.progress?.updatedAt ?? $1.addedAt) }
    )

    let watchedIDs = Set((continueWatching + recentlyWatched).map(\.id))
    let justAdded = Array(deduplicatedByShow(
      allItems
        .filter { !watchedIDs.contains($0.id) }
        .sorted { parseDate($0.addedAt) > parseDate($1.addedAt) }
    ).prefix(10))

    return (continueWatching, justAdded, recentlyWatched)
  }

  // MARK: - Home Load

  func homeLoad() async {
    let callID = Int.random(in: 1000...9999)
    homeLog.info("homeLoad[\(callID)]: called — isLoading=\(self.homeIsLoading) isCacheDecoding=\(self.homeIsCacheDecoding) isBackgroundRefreshing=\(self.homeIsBackgroundRefreshing)")
    guard !homeIsLoading, !homeIsCacheDecoding, !homeIsBackgroundRefreshing else {
      homeLog.warning("homeLoad[\(callID)]: already loading/syncing, bailing")
      return
    }

    if isDemoMode {
      homeLibraries = DemoData.libraries
      let demoItems = DemoData.movieItems + DemoData.tvItems
      recomputeHomeRails(from: demoItems)
      return
    }

    // Already have in-memory rail data — run heartbeat to check for changes
    if !homeAllRailsEmpty || !homeLibraries.isEmpty {
      homeLog.info("homeLoad[\(callID)]: PATH=in-memory — rails populated, running heartbeat")
      homeError = nil  // clear any stale error banner alongside populated content
      Task { await self.runHeartbeat() }
      return
    }

    // Cold start — load SQLite first (fast), then sync from network
    homeIsCacheDecoding = true
    defer { homeIsCacheDecoding = false }
    // Ensure setup has completed before any store access (TASK-420).
    await LocalStore.shared.ensureReady()
    let hasLocal = await Task.detached(priority: .userInitiated) {
      await LocalStore.shared.hasItems()
    }.value

    if hasLocal {
      homeLog.info("homeLoad[\(callID)]: PATH=cold-start — local DB has data, loading rails")
      let rails = await Task.detached(priority: .userInitiated) {
        await LocalStore.shared.queryRails()
      }.value
      homeContinueWatching = rails.continueWatching
      homeJustAdded = rails.justAdded
      homeRecentlyWatched = rails.recentlyWatched
      homeIsCacheDecoding = false
      // Skip background network sync when offline — cached content is already shown
      // and network calls will fail anyway (TASK-291).
      guard !isOffline && !serverUnreachable else {
        homeLog.info("homeLoad[\(callID)]: offline — showing cached content, skipping network sync")
        return
      }
      // QuickConnect users: api.baseURL is fallbackURL until resolved. Resolve now so
      // the background sync and all subsequent API calls use a real server address.
      if api.baseURL == AppState.fallbackURL {
        homeLog.info("homeLoad[\(callID)]: QC ID unresolved — resolving before background sync")
        let resolved = await reconnect()
        if !resolved {
          homeLog.warning("homeLoad[\(callID)]: QC resolution failed — showing cached content, starting background retry")
          startBackgroundReconnectRetry()
          return
        }
        homeLog.info("homeLoad[\(callID)]: QC resolved to \(self.api.baseURL)")
      }
      // Sync in background — may update rails once complete
      homeLog.info("homeLoad[\(callID)]: starting background delta sync")
      homeBackgroundFetchTask?.cancel()
      homeBackgroundFetchTask = Task { await self.runDeltaSyncWithBackgroundTask() }
    } else {
      homeLog.info("homeLoad[\(callID)]: PATH=cold-start — no local data, full sync required")
      homeIsCacheDecoding = false
      homeError = nil  // clear stale error before each retry attempt
      // When offline with no local data, skip the network attempt and surface an
      // appropriate error — avoids a loud failure on every network call (TASK-291).
      guard !isOffline && !serverUnreachable else {
        homeLog.info("homeLoad[\(callID)]: offline and no local data — skipping sync")
        homeError = isOffline ? "No internet connection." : "Can't reach your server."
        return
      }
      // Resolve QC ID before the foreground sync too.
      if api.baseURL == AppState.fallbackURL {
        homeLog.info("homeLoad[\(callID)]: QC ID unresolved — resolving before full sync")
        let resolved = await reconnect()
        if !resolved {
          homeError = "Can't reach your server. Check that DSVideoServer is running."
          return
        }
      }
      homeIsLoading = true
      homeError = nil
      await runDeltaSync(background: false)
      homeIsLoading = false
      // If sync completed but produced no items and no error, the library is either
      // genuinely empty or the server rejected our state silently. Surface a hint.
      if homeAllRailsEmpty && homeLibraries.isEmpty && homeError == nil {
        homeError = "No content found. If your library has videos, try signing out and back in."
      }
    }
  }

  func homeForceRefresh() async {
    guard !isDemoMode else { return }
    homeLog.info("homeForceRefresh: clearing local store, running full sync")
    homeBackgroundFetchTask?.cancel()
    homeBackgroundFetchTask = nil
    homeIsBackgroundRefreshing = false
    await Task.detached(priority: .utility) { await LocalStore.shared.clearAll() }.value
    homeIsLoading = true
    homeError = nil
    await runDeltaSync(background: false)
    homeIsLoading = false
    // Bump version so TVLibraryRail views re-fetch their content via .task(id:).
    libraryRailsVersion = UUID()
  }

  /// TASK-738: lightweight refresh when the app returns to the foreground, so
  /// Continue Watching reflects playback that happened on another device while we
  /// were backgrounded. Runs a background delta sync (heartbeat + changed items
  /// only — not a full reload) and skips when offline or already busy.
  func foregroundRefresh() async {
    guard !isDemoMode, !isOffline, !serverUnreachable else { return }
    guard !homeIsLoading, !homeIsCacheDecoding, !homeIsBackgroundRefreshing else { return }
    await runDeltaSyncWithBackgroundTask()
  }

  // MARK: - Delta Sync

  /// FIX-10: Wraps a background delta sync in a UIApplication background task so iOS
  /// grants up to 30s of extra runtime. Without this, iOS may suspend the process
  /// mid-sync ~30s after backgrounding, leaving the database in an inconsistent state.
  @MainActor
  private func runDeltaSyncWithBackgroundTask() async {
    #if canImport(UIKit)
    final class Box: @unchecked Sendable { var value = UIBackgroundTaskIdentifier.invalid }
    let bgTask = Box()
    bgTask.value = UIApplication.shared.beginBackgroundTask(withName: "DeltaSync") {
      UIApplication.shared.endBackgroundTask(bgTask.value)
    }
    defer {
      if bgTask.value != .invalid {
        UIApplication.shared.endBackgroundTask(bgTask.value)
        bgTask.value = .invalid
      }
    }
    await runDeltaSync(background: true)
    #else
    await runDeltaSync(background: true)
    #endif
  }

  /// Full delta sync: check heartbeat, fetch changed items, refresh progress.
  /// This is the single network path — replaces homeFetchFromNetwork + doHomeFetch.
  private func runDeltaSync(background: Bool) async {
    if background {
      guard !homeIsBackgroundRefreshing else { return }
      homeIsBackgroundRefreshing = true
    }
    defer { if background { homeIsBackgroundRefreshing = false } }

    // Don't attempt sync without a session token or a real server URL.
    // The login flow will trigger homeLoad() after resolving and setting both.
    guard sessionToken != nil, api.baseURL != AppState.fallbackURL else {
      homeLog.info("runDeltaSync: no token or unresolved server — skipping sync")
      return
    }

    let apiSnapshot = api
    homeLog.info("runDeltaSync: background=\(background)")

    do {
      // Step 1: Get server seq numbers and our local cursors
      let status = try await apiSnapshot.syncStatus()
      let cursors = await LocalStore.shared.getSyncCursors()
      homeLog.info("runDeltaSync: server itemSeq=\(status.itemSeq) local=\(cursors.itemSeq) | server progressSeq=\(status.progressSeq) local=\(cursors.progressSeq)")

      // Step 2: Fetch libraries (always fast, small payload)
      let libs = try await apiSnapshot.libraries().libraries
      homeLibraries = libs

      // Step 3: Fetch item deltas if server has new items
      let localCount = await LocalStore.shared.totalItemCount()
      if status.itemSeq > cursors.itemSeq || localCount == 0 {
        homeLog.info("runDeltaSync: fetching item deltas since seq=\(cursors.itemSeq)")
        var since = cursors.itemSeq
        var afterRowid: Int? = nil
        var pageCount = 0
        repeat {
          let page = try await apiSnapshot.syncItems(since: since, limit: 500, afterRowid: afterRowid)
          if !page.items.isEmpty {
            await LocalStore.shared.upsertItems(page.items)
            since = page.nextSeq
            afterRowid = page.hasMore ? page.nextAfterRowid : nil
            pageCount += 1
            // After first page on cold start, show rails immediately
            if !background && pageCount == 1 {
              let rails = await LocalStore.shared.queryRails()
              homeContinueWatching = rails.continueWatching
              homeJustAdded = rails.justAdded
              homeRecentlyWatched = rails.recentlyWatched
            }
            if !page.hasMore { break }
          } else {
            break
          }
        } while true

        // Fetch and apply deletions. Only advance the item cursor if the deletion
        // request succeeds — a failure means deleted IDs are unknown and must be
        // retried on the next sync cycle (TASK-437).
        var deletionSucceeded = true
        do {
          let deleted = try await apiSnapshot.syncDeleted(since: cursors.itemSeq)
          if !deleted.deletedIds.isEmpty {
            homeLog.info("runDeltaSync: \(deleted.deletedIds.count) deleted items")
            await LocalStore.shared.deleteItems(deleted.deletedIds)
          }
        } catch {
          homeLog.warning("runDeltaSync: syncDeleted failed — will retry on next sync: \(error.localizedDescription)")
          deletionSucceeded = false
        }

        if deletionSucceeded {
          await LocalStore.shared.setItemSeq(status.itemSeq)
          homeLog.info("runDeltaSync: item sync complete — \(pageCount) page(s)")
        } else {
          homeLog.info("runDeltaSync: item sync complete (cursor NOT advanced — deletion pending) — \(pageCount) page(s)")
        }
      }

      // Step 4: Fetch progress if server has updates, or if we have no local progress
      // (cursors.progressSeq == 0 means first sync — always fetch even if server seq is also 0,
      //  because rows may exist from before seq tracking was implemented).
      if status.progressSeq > cursors.progressSeq || cursors.progressSeq == 0 {
        homeLog.info("runDeltaSync: fetching fresh progress (server=\(status.progressSeq) local=\(cursors.progressSeq))")
        let progressMap = try await apiSnapshot.progressAll().progress
        if !progressMap.isEmpty {
          await LocalStore.shared.upsertProgress(progressMap)
        }
        // Only advance cursor if server reports a real seq, otherwise stay at 0
        // so we re-check on next launch until the server starts tracking
        if status.progressSeq > 0 {
          await LocalStore.shared.setProgressSeq(status.progressSeq)
        }
      }

      // Step 5: Recompute rails from local store and update UI
      let rails = await LocalStore.shared.queryRails()
      homeContinueWatching = rails.continueWatching
      homeJustAdded = rails.justAdded
      homeRecentlyWatched = rails.recentlyWatched
      clearNetworkError()
      homeLog.info("runDeltaSync: done — CW=\(rails.continueWatching.count) JA=\(rails.justAdded.count) RW=\(rails.recentlyWatched.count)")
      // Step 6: Refresh watchlist so it stays current with server state
      await loadWatchlist()

    } catch {
      homeLog.error("runDeltaSync: FAILED — \(error.localizedDescription)")
      // If the token changed since we captured apiSnapshot (e.g. a new login completed
      // while this stale sync was still in flight), discard the error silently.
      // Acting on a 401 from a superseded token would kick the user back to login
      // even though they just successfully authenticated.
      guard apiSnapshot.token == sessionToken else {
        homeLog.info("runDeltaSync: token superseded — discarding stale error")
        return
      }
      handleConnectionFailure(error)
      if homeAllRailsEmpty && homeLibraries.isEmpty {
        homeError = (error as? APIError)?.userMessage ?? "Could not connect to server."
      }
    }
  }

  // MARK: - Heartbeat

  /// Lightweight check — fires every 30s in foreground. Only syncs if sequences changed.
  func runHeartbeat() async {
    guard !isDemoMode, !homeIsLoading, !homeIsBackgroundRefreshing,
          api.baseURL != AppState.fallbackURL else { return }
    let apiSnapshot = api
    do {
      let beat = try await apiSnapshot.syncHeartbeat()
      let cursors = await LocalStore.shared.getSyncCursors()
      let itemsChanged = beat.itemSeq > cursors.itemSeq
      let progressChanged = beat.progressSeq > cursors.progressSeq
      if itemsChanged || progressChanged {
        homeLog.info("heartbeat: change detected (items=\(itemsChanged) progress=\(progressChanged)) — syncing")
        homeBackgroundFetchTask?.cancel()
        homeBackgroundFetchTask = Task { await self.runDeltaSync(background: true) }
      }
    } catch {
      // Heartbeat failures are silent — server may be temporarily unreachable
      homeLog.debug("heartbeat: failed — \(error.localizedDescription)")
    }
  }

  // MARK: - Progress from Local (instant, no network)

  /// Called when player dismisses — recomputes rails from local SQLite immediately.
  func refreshProgressFromLocal() async {
    guard !isDemoMode else { return }
    let rails = await LocalStore.shared.queryRails()
    homeContinueWatching = rails.continueWatching
    homeJustAdded = rails.justAdded
    homeRecentlyWatched = rails.recentlyWatched
  }

  /// Optimistic progress write: update local store immediately, then fire network write.
  func recordProgress(itemId: String, positionSeconds: Int, durationSeconds: Int) async {
    guard !isDemoMode else { return }
    await LocalStore.shared.upsertSingleProgress(
      itemId: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    let apiSnapshot = api
    let logSnapshot = homeLog
    Task.detached(priority: .utility) {
      // TASK-695: the LocalStore write above is the durability guarantee, so a network
      // sync failure isn't data loss — but it shouldn't be invisible. Log it (the
      // delta-sync cursor reconciles the server on the next sync pass).
      do {
        try await apiSnapshot.setProgress(id: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
      } catch {
        logSnapshot.warning("recordProgress: server sync failed for \(itemId) — \(error.localizedDescription); local store holds it until next sync")
      }
    }
  }

  // homeRefreshProgress kept for backwards compat with any view that calls it
  func homeRefreshProgress() async {
    await runHeartbeat()
  }

  // MARK: - Watchlist

  var watchlistItems: [ItemSummary] = []

  func loadWatchlist() async {
    guard !isDemoMode, sessionToken != nil else { return }
    do {
      let resp = try await api.watchlist()
      watchlistItems = resp.items
    } catch {
      // Non-fatal — watchlist is supplementary
    }
  }

  func toggleWatchlist(item: ItemSummary) async {
    guard !isDemoMode else { return }
    let alreadyIn = watchlistItems.contains(where: { $0.id == item.id })
    if alreadyIn {
      watchlistItems.removeAll(where: { $0.id == item.id })
      try? await api.removeFromWatchlist(id: item.id)
    } else {
      watchlistItems.insert(item, at: 0)
      try? await api.addToWatchlist(id: item.id)
    }
  }

  // MARK: - Deep Link

  /// Set when the app is opened via a dsvideo://item/{id} URL from the Top Shelf.
  var pendingDeepLinkItemID: String? = nil

  // MARK: - Top Shelf Snapshot

  /// Writes the Just Added rail (up to 10 items) to the shared App Group container
  /// so the Top Shelf extension can display them when the app is focused.
  func writeTopShelfSnapshot() {
    guard !homeJustAdded.isEmpty else { return }
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.HeiloProjects.DSReel"
    ) else { return }

    let items: [TopShelfItem] = homeJustAdded.prefix(10).compactMap { item in
      // Prefer backdrop for landscape Top Shelf cards, fall back to poster
      let imageID = item.backdropImageId ?? item.posterImageId
      var imageURLString: String? = nil
      if let imageID {
        var urlString = api.imageURL(id: imageID, width: 760)?.absoluteString
        if let token = sessionToken, let base = urlString {
          urlString = base + (base.contains("?") ? "&" : "?") + "token=\(token)"
        }
        imageURLString = urlString
      }
      return TopShelfItem(
        id: item.id,
        title: item.title,
        year: item.year,
        imageURL: imageURLString,
        deepLinkURL: "dsvideo://item/\(item.id)"
      )
    }

    let fileURL = container.appendingPathComponent("topshelf.json")
    guard let data = try? JSONEncoder().encode(items) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}

extension Notification.Name {
  static let networkDidReconnect = Notification.Name("dsm.networkDidReconnect")
}

func normalizedBaseURL(_ input: String, forceHTTPS: Bool, defaultPort: Int = 8090) -> URL? {
  var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !s.isEmpty else { return nil }
  if !s.contains("://") {
    s = (forceHTTPS ? "https://" : "http://") + s
  }
  if forceHTTPS {
    s = s.replacingOccurrences(of: "http://", with: "https://")
  }

  guard var url = URL(string: s), url.host != nil else { return nil }

  // Add default port if none specified.
  // Skip quickconnect.to — it's a relay host, not a DSVideoServer endpoint.
  let host = url.host ?? ""
  if url.port == nil && !host.hasSuffix("quickconnect.to") {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.port = defaultPort
    if let newURL = components?.url { url = newURL }
  }

  return url
}

