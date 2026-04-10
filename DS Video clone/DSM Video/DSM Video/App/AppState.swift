import CryptoKit
import Foundation
import Network
import Observation
import Security
import SwiftUI
import os.log

@MainActor
@Observable
final class AppState {

  /// Non-routable placeholder used when the stored URL is empty or malformed at init time.
  /// login() validates the real URL before any request fires, so this is never actually reached.
  private static let fallbackURL = URL(string: "http://0.0.0.0")!
  private enum Keys {
    static let baseURL = "dsReel.baseURL"
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

  var isDemoMode: Bool = false

  var isOffline: Bool = false
  var serverUnreachable: Bool = false

  private var networkMonitor: NWPathMonitor?
  private var heartbeatTimer: Timer?

  var sessionToken: String? {
    didSet {
      if rememberMe {
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
    guard let url = normalizedBaseURL(baseURL, forceHTTPS: useHTTPS, defaultPort: defaultPort) else {
      // Invalid URL — leave api as-is; login() will catch this before any request is made.
      return
    }
    api = APIClient(
      baseURL: url,
      token: sessionToken
    )
  }

  init() {
    let d = UserDefaults.standard
    let storedBaseURL = d.string(forKey: Keys.baseURL) ?? "http://localhost:8090"
    // useHTTPS defaults to false for local NAS compatibility (most home NAS setups use HTTP).
    // TODO(security/TASK-392): Consider defaulting to true once self-signed cert UX is resolved,
    // or surface a clear "Connection is not encrypted" warning in the UI when HTTP is active.
    let storedUseHTTPS = d.object(forKey: Keys.useHTTPS) as? Bool ?? false
    let storedRememberMe = d.object(forKey: Keys.rememberMe) as? Bool ?? true
    let storedDefaultPort = d.object(forKey: Keys.defaultPort) as? Int ?? 8090

    baseURL = storedBaseURL
    username = d.string(forKey: Keys.username) ?? ""
    rememberMe = storedRememberMe
    useHTTPS = storedUseHTTPS
    defaultPort = storedDefaultPort

    // Load saved credentials from Keychain if remember me is enabled
    var storedToken: String? = nil
    if storedRememberMe {
      savedPassword = Self.loadFromKeychain(account: Keys.keychainAccount) ?? ""
      storedToken = Self.loadFromKeychain(account: Keys.keychainAccountToken)
    }
    sessionToken = storedToken

    // Initialize stored api client once with all resolved values.
    // normalizedBaseURL returns nil for invalid URLs (empty, malformed). In that case we
    // use a non-routable placeholder; login() validates the URL before any request fires.
    let resolvedInitURL = normalizedBaseURL(storedBaseURL, forceHTTPS: storedUseHTTPS, defaultPort: storedDefaultPort)
      ?? Self.fallbackURL
    api = APIClient(
      baseURL: resolvedInitURL,
      token: storedToken
    )
    startNetworkMonitoring()
    startHeartbeatTimer()
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

  private func sha256(_ string: String) -> String {
    let data = Data(string.utf8)
    let hash = SHA256.hash(data: data)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
  }

  func login() async {
    loginError = nil
    isLoggingIn = true
    defer { isLoggingIn = false }

    // Demo mode — App Review credentials. No network required.
    // Pre-computed SHA-256 hashes so plaintext credentials are not stored in the binary.
    // Note: SHA-256 is not a password KDF. This is acceptable here because the demo account
    // has no real data — it uses a synthetic local session with no server tokens. The hashes
    // in source code are intentionally public-safe. A future hardening option would be PBKDF2
    // with a stored salt, but the risk/reward for a synthetic demo account is low.
    let demoUserHash = "fd3585e838137398830f6e33b448a8616344ca4352539a7da3b3e5cecd0957c4"
    let demoPassHash = "293211d16112d308c2b21026d33e94326940be9f79a8bcd6f681c6f528c60058"
    if sha256(username.trimmingCharacters(in: .whitespaces)) == demoUserHash &&
       sha256(savedPassword) == demoPassHash {
      isDemoMode = true
      sessionToken = "demo"
      return
    }

    do {
      // If the server field is a bare QuickConnect ID (no dots, no scheme),
      // resolve it to candidate NAS URLs and try each until one works.
      // LAN IPs are tried first to avoid NAT hairpinning and self-signed cert issues.
      let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if let qcID = QuickConnectResolver.extractBareID(from: raw) {
        let resolved = try await QuickConnectResolver.resolve(id: qcID)
        guard !resolved.isEmpty else {
          loginError = "Couldn't find \"\(qcID)\". Check the QuickConnect ID and try again."
          return
        }
        // QuickConnect returns NAS IPs with Synology DSM ports (5000/5001).
        // DSVideoServer runs on defaultPort (8090). Extract unique hosts in
        // discovery order (LAN first, WAN last) and try each with our port.
        let scheme = useHTTPS ? "https" : "http"
        var seen = Set<String>()
        var portedCandidates: [(urlStr: String, url: URL)] = []
        for candidateURL in resolved {
          guard let cURL = URL(string: candidateURL), let host = cURL.host else { continue }
          guard seen.insert(host).inserted else { continue }
          let urlStr = "\(scheme)://\(host):\(defaultPort)"
          guard let url = URL(string: urlStr) else { continue }
          portedCandidates.append((urlStr, url))
        }
        var lastError: Error?
        for (urlStr, url) in portedCandidates {
          do {
            let tempClient = APIClient(baseURL: url, token: nil)
            let resp = try await tempClient.login(username: username, password: savedPassword)
            // Success — set token BEFORE baseURL so the first updateAPI() call has
            // the correct token and no brief nil-token APIClient is created.
            sessionToken = resp.token
            if rememberMe {
              // Persist the resolved IP so future launches reconnect directly.
              baseURL = urlStr
              Self.saveToKeychain(savedPassword, account: Keys.keychainAccount)
            } else {
              // Don't persist the resolved IP — keep the original QuickConnect ID
              // in baseURL so it re-resolves on the next login (TASK-404).
              Self.deleteFromKeychain(account: Keys.keychainAccount)
              Self.deleteFromKeychain(account: Keys.keychainAccountToken)
              // Update the api client directly to use the resolved URL for this session
              // without persisting it to UserDefaults.
              api = APIClient(baseURL: url, token: resp.token)
              username = ""; savedPassword = ""
            }
            return
          } catch {
            lastError = error
          }
        }
        loginError = (lastError as? APIError)?.userMessage ?? "Login failed. Check that DSVideoServer is running on your NAS."
        return
      }

      // Validate server address before attempting login
      guard normalizedBaseURL(baseURL, forceHTTPS: useHTTPS, defaultPort: defaultPort) != nil else {
        loginError = "Invalid server address. Please check the URL."
        return
      }

      // Direct IP / hostname login
      let resp = try await api.login(username: username, password: savedPassword)

      // Store session token (didSet persists to Keychain when rememberMe is on)
      sessionToken = resp.token

      if rememberMe {
        Self.saveToKeychain(savedPassword, account: Keys.keychainAccount)
      } else {
        Self.deleteFromKeychain(account: Keys.keychainAccount)
        Self.deleteFromKeychain(account: Keys.keychainAccountToken)
        username = ""
        savedPassword = ""
      }
    } catch {
      loginError = (error as? APIError)?.userMessage ?? "Login failed."
    }
  }

  func logout() {
    Self.deleteFromKeychain(account: Keys.keychainAccountToken)
    Self.deleteFromKeychain(account: Keys.keychainAccount)
    savedPassword = ""
    sessionToken = nil
    pairingCode = nil
    isDemoMode = false
    loginError = nil
    stopHeartbeatTimer()  // TASK-428: prevent timer from firing after logout
    clearHomeState()
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
        isDemoMode = false
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
  func clearNetworkError() {
    serverUnreachable = false
    isOffline = false
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
        // When network comes back, trigger a background refresh
        if wasOffline && !self.isOffline {
          NotificationCenter.default.post(name: .networkDidReconnect, object: nil)
        }
      }
    }
    monitor.start(queue: DispatchQueue(label: "com.dsm.networkMonitor"))
  }

  func generatePairingCode() async {
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

    guard let serverURL = normalizedBaseURL(baseURL, forceHTTPS: useHTTPS, defaultPort: defaultPort) else {
      loginError = "Invalid server address. Please check the URL."
      return
    }

    do {
      let resp = try await APIClient(baseURL: serverURL, token: nil)
        .exchangePairingCode(code: code)
      sessionToken = resp.token
    } catch {
      loginError = (error as? APIError)?.userMessage ?? "Invalid pairing code."
    }
  }

  // MARK: - Home Data

  private let homeLog = Logger(subsystem: "com.dsm.dsvideo", category: "HomeState")

  // Persistent across tab switches — populated once, never cleared unless logout/forceRefresh
  var homeLibraries: [Library] = []
  var homeContinueWatching: [ItemSummary] = []
  var homeJustAdded: [ItemSummary] = []
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
      await Task { @MainActor [weak self] in
        guard let self else { return }
        self.homeContinueWatching = cont
        self.homeJustAdded = added
        self.homeRecentlyWatched = watched
        self.homeLog.info("recomputeHomeRails: done in \(elapsed)s — cont=\(cont.count) added=\(added.count) watched=\(watched.count)")
      }.value
    }
  }

  nonisolated static func computeHomeRails(_ allItems: [ItemSummary])
    -> (continueWatching: [ItemSummary], justAdded: [ItemSummary], recentlyWatched: [ItemSummary])
  {
    let formatterFrac: ISO8601DateFormatter = {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return f
    }()
    let formatter: ISO8601DateFormatter = {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime]
      return f
    }()
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
    homeLog.info("homeLoad[\(callID)]: called — isLoading=\(self.homeIsLoading) isCacheDecoding=\(self.homeIsCacheDecoding)")
    guard !homeIsLoading, !homeIsCacheDecoding else {
      homeLog.warning("homeLoad[\(callID)]: already loading, bailing")
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
      Task { await self.runHeartbeat() }
      return
    }

    // Cold start — load SQLite first (fast), then sync from network
    homeIsCacheDecoding = true
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
      // Sync in background — may update rails once complete
      homeLog.info("homeLoad[\(callID)]: starting background delta sync")
      homeBackgroundFetchTask = Task { await self.runDeltaSync(background: true) }
    } else {
      homeLog.info("homeLoad[\(callID)]: PATH=cold-start — no local data, full sync required")
      homeIsCacheDecoding = false
      homeIsLoading = true
      homeError = nil
      await runDeltaSync(background: false)
      homeIsLoading = false
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
  }

  // MARK: - Delta Sync

  /// Full delta sync: check heartbeat, fetch changed items, refresh progress.
  /// This is the single network path — replaces homeFetchFromNetwork + doHomeFetch.
  private func runDeltaSync(background: Bool) async {
    if background {
      guard !homeIsBackgroundRefreshing else { return }
      homeIsBackgroundRefreshing = true
    }

    // Don't attempt sync without a session token — it will always 401.
    // The login flow will trigger homeLoad() after setting a token.
    guard sessionToken != nil else {
      homeLog.info("runDeltaSync: no token — skipping sync")
      if background { homeIsBackgroundRefreshing = false }
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

        // Fetch and apply deletions
        if let deleted = try? await apiSnapshot.syncDeleted(since: cursors.itemSeq), !deleted.deletedIds.isEmpty {
          homeLog.info("runDeltaSync: \(deleted.deletedIds.count) deleted items")
          await LocalStore.shared.deleteItems(deleted.deletedIds)
        }

        await LocalStore.shared.setItemSeq(status.itemSeq)
        homeLog.info("runDeltaSync: item sync complete — \(pageCount) page(s)")
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

    } catch {
      homeLog.error("runDeltaSync: FAILED — \(error.localizedDescription)")
      // If the token changed since we captured apiSnapshot (e.g. a new login completed
      // while this stale sync was still in flight), discard the error silently.
      // Acting on a 401 from a superseded token would kick the user back to login
      // even though they just successfully authenticated.
      guard apiSnapshot.token == sessionToken else {
        homeLog.info("runDeltaSync: token superseded — discarding stale error")
        if background { homeIsBackgroundRefreshing = false }
        return
      }
      handleConnectionFailure(error)
      if homeAllRailsEmpty && homeLibraries.isEmpty {
        homeError = (error as? APIError)?.userMessage ?? "Could not connect to server."
      }
    }
    if background { homeIsBackgroundRefreshing = false }
  }

  // MARK: - Heartbeat

  /// Lightweight check — fires every 30s in foreground. Only syncs if sequences changed.
  func runHeartbeat() async {
    guard !isDemoMode, !homeIsLoading, !homeIsBackgroundRefreshing else { return }
    let apiSnapshot = api
    do {
      let beat = try await apiSnapshot.syncHeartbeat()
      let cursors = await LocalStore.shared.getSyncCursors()
      let itemsChanged = beat.itemSeq > cursors.itemSeq
      let progressChanged = beat.progressSeq > cursors.progressSeq
      if itemsChanged || progressChanged {
        homeLog.info("heartbeat: change detected (items=\(itemsChanged) progress=\(progressChanged)) — syncing")
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
    await LocalStore.shared.upsertSingleProgress(
      itemId: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    let apiSnapshot = api
    Task.detached(priority: .utility) {
      try? await apiSnapshot.setProgress(id: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    }
  }

  // homeRefreshProgress kept for backwards compat with any view that calls it
  func homeRefreshProgress() async {
    await runHeartbeat()
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

