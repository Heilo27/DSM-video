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
    didSet {
      UserDefaults.standard.set(rememberMe, forKey: Keys.rememberMe)
      // TASK-842: turning Remember Me OFF must evict the token that was persisted while it
      // was on. Previously this didSet only wrote the UserDefaults flag, so a user who
      // signed in with Remember Me on (the default), then turned it off and closed the app
      // without an explicit Sign Out, left a live bearer token for the NAS sitting in the
      // Keychain indefinitely. It is not read back at launch — init gates the load on the
      // stored flag — so the symptom is invisible, which is precisely the problem on a
      // shared or handed-down device.
      if !rememberMe {
        Self.deleteFromKeychain(account: Keys.keychainAccountToken)
      }
    }
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
  /// Guards flushPendingProgress against concurrent entry (runDeltaSync awaits it while
  /// clearNetworkError fires it detached). See flushPendingProgress for why @MainActor
  /// alone is not enough.
  var isFlushingProgress: Bool = false

  private var networkMonitor: NWPathMonitor?
  private var heartbeatTimer: Timer?
  private var reconnectRetryTask: Task<Void, Never>?

  var sessionToken: String? {
    didSet {
      guard !isDemoMode else {
        updateAPI()
        return
      }
      // TASK-842: the DELETE is unconditional — it used to sit inside `if rememberMe`, so
      // clearing the token while Remember Me was off left whatever was previously persisted
      // untouched in the Keychain. Only the WRITE is gated on rememberMe.
      if let token = sessionToken {
        if rememberMe {
          Self.saveToKeychain(token, account: Keys.keychainAccountToken)
        }
      } else {
        Self.deleteFromKeychain(account: Keys.keychainAccountToken)
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
    // TASK-817: useHTTPS is really "the last winning network's scheme," not a per-address
    // preference. Apply the same LAN guard as buildCandidates() (TASK-779) so a bare
    // private IP is never forced to https:// — bare-IP TLS has no valid cert and fails.
    let effectiveHTTPS = Self.isPrivateLANAddress(baseURL) ? false : useHTTPS
    guard let url = normalizedBaseURL(baseURL, forceHTTPS: effectiveHTTPS, defaultPort: defaultPort) else {
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
    // TASK-817: guard a bare private IP against a stale https flag (see updateAPI()).
    let initEffectiveHTTPS = Self.isPrivateLANAddress(storedBaseURL) ? false : storedUseHTTPS
    let resolvedInitURL = isQCID ? Self.fallbackURL
      : (normalizedBaseURL(storedBaseURL, forceHTTPS: initEffectiveHTTPS, defaultPort: storedDefaultPort) ?? Self.fallbackURL)
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

    #if DEBUG
    // UI-TEST DEMO HOOK: lets screenshot/UI-test tooling boot straight into demo content
    // without typing into TextFields. ONLY fires when the explicit launch arg / env var is
    // present — it does not change normal launch behavior, and the whole block is compiled
    // out of release builds. Sims run Debug, which is what the QA tooling targets.
    //   Launch argument: -UITestDemoMode   (or)   environment: UITEST_DEMO=1
    if AppState.isUITestDemoLaunch {
      bootstrapDemoMode()
    }
    // QA live-session hook — see qaLiveToken. Adopts a real token + server so homeLoad()
    // runs its true path against a live NAS. No-op unless the launch args are present.
    if let qaToken = AppState.qaLiveToken {
      if let qaServer = AppState.qaLiveServer {
        baseURL = qaServer
      }
      sessionToken = qaToken
      updateAPI()
      homeLog.info("QA live-session hook active — server=\(self.baseURL, privacy: .public)")
    }
    #endif

    // Launch banner. A photographed log needs to be self-describing: which build, which
    // server, whether a token survived. Without this, every report starts with three
    // clarifying questions before diagnosis can begin.
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    #if os(tvOS)
    let platform = "tvOS"
    #else
    let platform = "iOS"
    #endif
    dlog.info(.app, "── launch: \(platform) v\(v) (\(b)) \(ProcessInfo.processInfo.operatingSystemVersionString) ──")
    dlog.info(.app, "server=\(baseURL) https=\(useHTTPS) port=\(defaultPort) user='\(username)'")
    dlog.info(.app, "token=\(DiagnosticLog.redact(sessionToken)) lan='\(lanAddress)' wan='\(wanAddress)'")
  }

  #if DEBUG
  /// True when the process was launched with the demo hook explicitly requested.
  /// Gated to DEBUG builds; the launch-arg/env-var check is the real guard.
  static var isUITestDemoLaunch: Bool {
    ProcessInfo.processInfo.arguments.contains("-UITestDemoMode")
      || ProcessInfo.processInfo.environment["UITEST_DEMO"] == "1"
  }

  /// Synchronously enters demo mode at launch — same content path as the
  /// appledemo / dsvideo2024 credentials, but with no network and no typing.
  /// Setting sessionToken = "demo" makes RootView render MainView immediately.
  private func bootstrapDemoMode() {
    username = "appledemo"
    homeLibraries = DemoData.libraries
    let demoItems = DemoData.movieItems + DemoData.tvItems
    recomputeHomeRails(from: demoItems)
    sessionToken = "demo"
  }

  /// QA hook: boot straight into a REAL signed-in session using a token supplied on the
  /// command line, e.g.
  ///   xcrun simctl launch <udid> <bundle> -QALiveToken <jwt> -QALiveServer http://host:port
  ///
  /// Why this exists: the tvOS simulator on a headless Xcode install has no way to type or
  /// to press a button — no Simulator.app for key events, no idb, no HID facility in simctl
  /// — so the pairing screen is an absolute wall. Demo mode gets past it but calls
  /// recomputeHomeRails() directly, bypassing homeLoad() entirely, so it cannot exercise the
  /// real data path at all. This hook is the only way to observe homeLoad() running against
  /// a live server in the simulator.
  ///
  /// DEBUG-only and inert without the explicit launch argument, exactly like the demo hook
  /// above. The token is supplied per-launch and never persisted here.
  static var qaLiveToken: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "-QALiveToken"), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    return v.isEmpty ? nil : v
  }

  static var qaLiveServer: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "-QALiveServer"), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    return v.isEmpty ? nil : v
  }
  #endif

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
      Task { @MainActor [weak self] in
        // Brief yield so init's Task and homeLoad() settle first.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await self?.refreshSession()
      }
    }
  }

  /// TASK-781: proactive near-expiry token refresh. Exchanges the current token for a fresh
  /// one via `/api/v1/auth/refresh` (no password re-transmission), then rebuilds `api` and
  /// persists the new token. Falls back to a full `login()` if the refresh endpoint is
  /// unavailable/unsupported or fails — so this never regresses the previous behaviour, and
  /// still works when only a token (no saved password) is stored. Wired in place of the old
  /// login()-only path, which re-sent the plaintext password on every near-expiry launch.
  func refreshSession() async {
    guard sessionToken != nil, !isDemoMode else { return }
    do {
      let resp = try await api.refreshToken()
      sessionToken = resp.token
      api = APIClient(baseURL: api.baseURL, token: resp.token, usesTunnelCookie: api.usesTunnelCookie)
      homeLog.info("refreshSession: token refreshed without password")
    } catch {
      // Refresh unavailable or rejected — fall back to a full login only if we can.
      homeLog.warning("refreshSession: refresh failed (\(error.localizedDescription)) — falling back to login")
      if !savedPassword.isEmpty {
        await login()
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
  /// True if `address` is (or resolves textually to) a private / link-local / loopback host
  /// for which HTTPS-to-bare-IP would fail cert validation. Strips scheme/port/path first.
  /// Covers RFC1918 (10/8, 192.168/16, 172.16–31/12), link-local (169.254/16), loopback,
  /// and .local mDNS names. (TASK-779)
  static func isPrivateLANAddress(_ address: String) -> Bool {
    var host = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let r = host.range(of: "://") { host = String(host[r.upperBound...]) }
    if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
    if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
    guard !host.isEmpty else { return false }
    if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") { return true }
    if host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("169.254.") { return true }
    // 172.16.0.0 – 172.31.255.255
    if host.hasPrefix("172.") {
      let parts = host.split(separator: ".")
      if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
    }
    return false
  }

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
      // TASK-779: a persisted useHTTPS (set to the last winning WAN candidate's scheme)
      // must NOT force https:// onto a raw LAN/private IP — the DDNS TLS cert doesn't cover
      // bare IPs, so HTTPS to a LAN IP fails cert validation every time and the fast LAN
      // path is wasted. Mirror QuickConnectResolver's LAN handling: force http for private
      // IPs regardless of the persisted flag.
      let forceHTTPS = Self.isPrivateLANAddress(address) ? false : useHTTPS
      guard let url = normalizedBaseURL(address, forceHTTPS: forceHTTPS, defaultPort: defaultPort) else { return }
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
    // TASK-780: re-entrancy guard. login() writes shared @Observable auth state
    // (sessionToken, api, baseURL, useHTTPS, defaultPort). Two concurrent logins — e.g. the
    // proactive near-expiry refresh scheduled in checkTokenExpiryOnLaunch() racing a user tap
    // on Connect, or exchangePairingCode() — can finish on different candidates and interleave
    // these writes, leaving api pointed at one URL while baseURL/useHTTPS reflect another.
    // reconnect() already guards itself the same way (isReconnecting). Bail if one is in flight.
    guard !isLoggingIn else {
      homeLog.info("login: already in progress — ignoring re-entrant call")
      return
    }
    loginError = nil
    isLoggingIn = true
    defer { isLoggingIn = false }

    // Demo mode — App Review credentials. No network required.
    //
    // DELIBERATELY ships in release builds (TASK-852). App Review needs to evaluate the app
    // without a Synology NAS on their network, and this is the documented demo account. It is
    // NOT #if DEBUG-gated for that reason — unlike bootstrapDemoMode() below, which is a
    // developer convenience and correctly debug-only.
    //
    // Blast radius is bounded by design and must stay that way: this branch short-circuits
    // BEFORE any network call, binds sessionToken to the literal "demo", and isDemoMode
    // (AppState.swift:83) gates every server-touching path — recordProgress, loadWatchlist,
    // runHeartbeat, refreshSession, revalidateConnection. It grants access to bundled
    // DemoData only and can never reach a real NAS or a real credential.
    //
    // If the App Store listing ever stops requiring an in-binary demo account, wrap this in
    // #if DEBUG. Until then the exposure is accepted: the credentials are effectively public
    // (plaintext in the binary, identical for every install) but unlock nothing but sample data.
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

      // Diagnostic: the candidate list IS the explanation for most login failures. A stale
      // saved address shows up here as an address Ryan does not recognise, and the per-
      // candidate results below say exactly how each one failed.
      dlog.info(.auth, "login: user '\(username)', \(candidates.count) candidate(s), \(lanCount) LAN")
      for (i, c) in candidates.enumerated() {
        dlog.info(.auth, "  candidate \(i + 1): \(c.url.host ?? "?"):\(c.url.port.map(String.init) ?? "-") \(c.url.scheme ?? "?")\(c.requiresTunnelCookie ? " (relay)" : "")")
      }

      var lastError: Error?
      // Every candidate's failure, as "host:port — reason". The user-facing error names
      // these; without them "Login failed" is indistinguishable across a stale LAN address,
      // a blocked port, a cert mismatch and a genuine outage.
      var attemptFailures: [String] = []
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
          dlog.info(.auth, "login OK via \(candidate.url.host ?? "?"):\(candidate.url.port.map(String.init) ?? "-") token=\(DiagnosticLog.redact(resp.token))")
          return
        } catch {
          homeLog.warning("login: \(candidate.url) failed — \(error.localizedDescription)")
          // Per-candidate failure reason. This is what distinguishes "wrong password"
          // (server answered 401) from "wrong address" (nothing answered at all) — the
          // exact ambiguity that cost an evening when the app reported both identically.
          let why: String
          if let apiErr = error as? APIError {
            why = apiErr.serverReached ? "server rejected: \(apiErr.userMessage)" : apiErr.userMessage
          } else if let urlErr = error as? URLError {
            why = urlErr.code.diagnosticName
          } else {
            why = error.localizedDescription
          }
          dlog.warn(.auth, "candidate \(index + 1) \(candidate.url.host ?? "?"):\(candidate.url.port.map(String.init) ?? "-") failed — \(why)")
          attemptFailures.append("\(candidate.url.host ?? "?"):\(candidate.url.port.map(String.init) ?? "-") — \(why)")
          lastError = error
        }
      }
      // If a candidate actually reached the server, the server's own error is the
      // truth — surface it. Only fall back to "couldn't find" when the failure was
      // purely a connectivity/resolution miss (no server ever answered). Otherwise a
      // real 401/403 (wrong password, or account lacks app permission) gets hidden
      // behind a misleading "check the QuickConnect ID" message.
      let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      dlog.error(.auth, "login FAILED — all \(candidates.count) candidate(s) exhausted")

      // NAME WHAT WAS TRIED. The old messages ("Login failed. Check that DSVideoServer is
      // running on your NAS.") pointed at the server even when the server was answering
      // perfectly — the app had simply tried a stale address, or a port that speaks a
      // different scheme, and said nothing about which. Diagnosing that took hours.
      //
      // A server that ANSWERED and rejected us is different: its own message is the truth
      // and must not be buried under connection detail.
      if let apiErr = lastError as? APIError, apiErr.serverReached {
        loginError = apiErr.userMessage
      } else if let qcID = QuickConnectResolver.extractBareID(from: raw) {
        let detail = attemptFailures.isEmpty ? "" : "\n\n" + attemptFailures.joined(separator: "\n")
        loginError = "Couldn't reach \"\(qcID)\" on any known address.\(detail)"
      } else if !attemptFailures.isEmpty {
        loginError = attemptFailures.count == 1
          ? "Couldn't reach \(attemptFailures[0])"
          : "Couldn't reach the server. Tried:\n" + attemptFailures.joined(separator: "\n")
      } else {
        loginError = (lastError as? APIError)?.userMessage
          ?? (lastError as? URLError).map { APIError.connection($0.code).userMessage }
          ?? "Login failed — no server address could be built. Check the address."
      }
    } catch {
      // Do NOT collapse an unrecognised error into a generic string here: a transport
      // failure is now APIError.connection and carries the actual reason, and the fallback
      // must not imply the credentials were the problem.
      loginError = (error as? APIError)?.userMessage
        ?? (error as? URLError).map { APIError.connection($0.code).userMessage }
        ?? "Login failed."
    }
  }

  func logout() {
    // Revoke server-side FIRST (fire-and-forget). POST /auth/logout had zero callers, so
    // signing out cleared the device while the bearer token stayed valid on the server until
    // it expired — on a shared or lost device that token kept working after the user believed
    // they were signed out. Captured before the local state is torn down, because the request
    // needs the token we are about to delete. Deliberately not awaited: local sign-out must
    // never hang on the network, and the local clear below is the real guarantee.
    if sessionToken != nil {
      let apiSnapshot = api
      let logSnapshot = homeLog
      Task.detached(priority: .utility) {
        do { try await apiSnapshot.logout() }
        catch { logSnapshot.warning("logout: server-side revoke failed — \(error.localizedDescription)") }
      }
    }
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
    // TASK-807: purge on-device content so a shared device leaves no cross-user residue.
    // Downloads are @MainActor (sync); the SQLite cache is an actor (async).
    DownloadManager.shared.clearAll()
    Task { await LocalStore.shared.clearAll() }
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

  /// TASK-848: classify a playback-fetch failure and, when it is an expired/rejected session,
  /// clear session state through the normal path. Returns true if the cause was auth.
  ///
  /// The player had no 401 handling at all. When the token expires mid-stream the segment
  /// requests start returning 401, AVPlayer reports a non-specific media-services error, and
  /// the overlay says "Playback Failed" with text that never mentions the session. Retry then
  /// re-runs the playback fetch with the SAME dead token, so it can never succeed — the user
  /// can press it indefinitely. Worse, the rest of the app still believed it was authenticated
  /// (sessionToken non-nil), so dismissing the player dumped them to the login screen on the
  /// next unrelated API call with nothing connecting it to the failure they just saw.
  ///
  /// Routing through handleConnectionFailure keeps session teardown identical to every other
  /// auth failure in the app; the Bool lets the player replace Retry with a sign-in affordance
  /// instead of offering a retry that provably cannot work.
  ///
  /// VIEW HOOKUP (owned by another agent): Views/ItemDetailView.swift `start()` — its
  /// `catch` around the `appState.api.playback(...)` call (~line 1517) should call this and,
  /// when it returns true, set an auth-specific error message; Views/GestureVideoPlayer.swift
  /// errorOverlay (~line 399) should then show "Sign in again" in place of "Retry".
  @discardableResult
  func handlePlaybackFailure(_ error: Error) -> Bool {
    let isAuth = (error as? APIError)?.isAuthFailure ?? false
    handleConnectionFailure(error)
    if isAuth {
      homeLog.warning("playback failed due to auth expiry — session cleared, re-authentication required")
    }
    return isAuth
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
      // isAuthFailure, not `.http(401)`: the backend sends a JSON body with every error,
      // so an expired token arrives as .server("invalid_token", status: 401) and the old
      // `.http(401)` pattern never matched. This branch was dead code — a rejected token
      // left the user on an authenticated-looking UI with empty rails and no way back to
      // the login screen.
      case _ where apiErr.isAuthFailure:
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
      // Only .notConnectedToInternet means "this device has no network." Recovery for
      // isOffline comes exclusively from NWPathMonitor, which fires on a PATH CHANGE.
      //
      // .networkConnectionLost must NOT set it: that error means one TCP connection died
      // (server restart, NAT timeout, Wi-Fi hiccup) while the interface stayed satisfied.
      // The path never changed, so the monitor never fired, so isOffline was never
      // cleared — and homeLoad/foregroundRefresh/runDeltaSync all hard-return while it's
      // set. One dropped connection pinned the app on "No internet connection." over
      // stale rails until relaunch. It's a server-reachability failure, so treat it as one.
      case .notConnectedToInternet:
        isOffline = true
      case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut,
           .dnsLookupFailed, .secureConnectionFailed:
        serverUnreachable = true
      default:
        break
      }
    }
  }

  /// Turns a pairing failure into a message that names the ACTUAL cause.
  ///
  /// Every failure mode used to collapse to "Invalid pairing code." — including a
  /// timeout, a DNS failure, and an unreachable NAS. The user then re-entered a code
  /// that was perfectly valid, repeatedly, with no hint the server was the problem.
  static func pairingErrorMessage(_ error: Error?) -> String {
    if let apiErr = error as? APIError {
      if case .connection = apiErr {
        // Never reached the server: the code was never even checked.
        return "Couldn't reach your server. Check that it's on and connected, then try again."
      }
      // The server DID answer and rejected us — its message is the accurate one.
      return apiErr.userMessage
    }
    if error is URLError {
      return "Couldn't reach your server. Check that it's on and connected, then try again."
    }
    return "That code didn't work. Check the code and try again."
  }

  /// Safety net for the offline flag: trust the CURRENT path, not the last edge.
  ///
  /// `isOffline` gates every sync entry point, and its only clearer is NWPathMonitor's
  /// pathUpdateHandler — which fires on a path CHANGE. If the flag is ever set while the
  /// path is already satisfied, no change is coming and the app is stranded until
  /// relaunch. Called on foreground, where a stale flag is most likely and most costly.
  func reconcileOfflineFlag() {
    guard isOffline, let path = networkMonitor?.currentPath, path.status == .satisfied else { return }
    homeLog.info("reconcileOfflineFlag: path is satisfied but isOffline was set — clearing")
    isOffline = false
  }

  /// Call after a successful API operation to clear network error state.
  /// Both flags cleared here; NWPathMonitor also clears isOffline independently on path recovery.
  /// NOTE: reconnectRetryTask lifecycle is managed only by startBackgroundReconnectRetry() and
  /// logout() — not here. Cancelling from clearNetworkError() would self-cancel the retry task
  /// before homeLoad() runs on the success path (Issue 7).
  func clearNetworkError() {
    let wasDown = serverUnreachable || isOffline
    serverUnreachable = false
    isOffline = false
    // Also clear the banner. homeError was only ever nil'd on entry to a FOREGROUND load,
    // so a successful background/heartbeat-driven sync left "Can't reach your server."
    // pinned above fully-populated, correct rails until the user pulled to refresh.
    homeError = nil
    // Connectivity just came back — push anything recorded while we were offline. This is
    // the single choke point every reconnect path funnels through, so hooking it here
    // covers foreground revalidation, QuickConnect re-resolution, and manual retry alike.
    if wasDown {
      Task { await self.flushPendingProgress() }
    }
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
        // isAuthFailure covers 401 AND 403 in both .http and .server shapes. The old
        // `case .http(401)` could never match (the server always sends a JSON body), so
        // this fell through and ADOPTED the candidate on any auth rejection — calling
        // clearNetworkError() and reporting success. A revoked or permission-denied
        // account therefore "reconnected" to a server that would refuse every subsequent
        // request: /api/v1/version is unauthenticated, so probe one passed and probe two's
        // failure was swallowed here. Fail closed on auth, not open.
        if err.isAuthFailure {
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

  /// Fast liveness check on the CURRENT address; runs the full LAN→WAN→relay
  /// cascade only if the address we're on has gone dead. This is the piece that
  /// makes "leave the house" work without a sign-out: on foreground, NWPathMonitor
  /// often never fires for a backgrounded app, and homeLoad()'s in-memory path only
  /// runs a silent heartbeat — neither re-runs the cascade. This does.
  ///
  enum RevalidateResult {
    case stillGood       // current address is live — caller should proceed as normal
    case switched        // moved to a new address; networkDidReconnect already posted
    case failed          // no reachable address found
  }

  /// Returns how the revalidation resolved so the caller knows whether it still needs
  /// to trigger a load itself. On `.switched` this method already posts
  /// networkDidReconnect (which drives homeLoad), so the caller must NOT load again.
  func revalidateConnection() async -> RevalidateResult {
    guard sessionToken != nil, !isDemoMode else { return .failed }
    guard api.baseURL != AppState.fallbackURL else {
      // Never resolved (QC ID) — go straight to the full cascade.
      return await reconnect() ? .switched : .failed
    }
    // Only worth re-probing when we actually have a second address to fall back to.
    let hasLAN = !lanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasWAN = !wanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasLAN || hasWAN else { return .stillGood }

    // Quick 2s probe of the address we think we're on.
    if (try? await api.serverVersion(timeout: 2)) != nil {
      return .stillGood  // current address still live — nothing to do
    }
    homeLog.info("revalidateConnection: current address \(self.api.baseURL) is unreachable — running cascade")
    let before = api.baseURL.absoluteString
    guard await reconnect() else { return .failed }
    if api.baseURL.absoluteString != before {
      homeLog.info("revalidateConnection: switched \(before) → \(self.api.baseURL) — posting networkDidReconnect")
      NotificationCenter.default.post(name: .networkDidReconnect, object: nil)
      return .switched
    }
    // reconnect() re-verified the same address (transient blip recovered) — treat as good.
    return .stillGood
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
      // Name the real cause. Ten minutes of failed reconnects means the SERVER was
      // unreachable — the credentials were never in question. The old wording
      // ("Sign in again to reconnect") sent users to retype a password that was fine.
      softLogout(reason: "Couldn't reach your server for several minutes. Check that it's on, then sign in to reconnect.")
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
          // Run the re-probe inline on this @MainActor task and AWAIT it so the
          // refresh post happens only after reconnect() resolves. The previous
          // nested fire-and-forget Task let the handler return before reconnect
          // finished, so the LAN↔WAN switch landed but nothing refreshed.
          guard !self.isReconnecting else { return }
          homeLog.info("networkMonitor: path changed with dual addresses — re-probing")
          // A LAN→WAN switch stays online→online, so the offline→online post above
          // never fires. Detect the address change via reconnect()'s effect on
          // baseURL/api and post .networkDidReconnect ourselves so the listening
          // views (LibrariesView/MainView) reload libraries and streams.
          let addressBefore = self.api.baseURL.absoluteString
          let switched = await self.reconnect()
          let addressAfter = self.api.baseURL.absoluteString
          if switched && addressBefore != addressAfter {
            homeLog.info("networkMonitor: effective address changed \(addressBefore) → \(addressAfter) — posting networkDidReconnect")
            NotificationCenter.default.post(name: .networkDidReconnect, object: nil)
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
    // TASK-780: share login()'s re-entrancy guard. This path also mutates the shared auth
    // state (sessionToken, api, baseURL) and uses the same isLoggingIn flag, so a concurrent
    // login() and pairing exchange would otherwise interleave their writes. Whichever
    // acquires the flag first proceeds; the other bails.
    guard !isLoggingIn else {
      homeLog.info("exchangePairingCode: auth already in progress — ignoring")
      return
    }
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
          dlog.info(.auth, "pairing OK via QuickConnect \(candidate.url.host ?? "?") token=\(DiagnosticLog.redact(resp.token))")
          return
        } catch {
          dlog.warn(.auth, "pairing via \(candidate.url.host ?? "?") failed — \((error as? APIError)?.userMessage ?? error.localizedDescription)")
          lastError = error
        }
      }
      dlog.error(.auth, "pairing FAILED — all QuickConnect candidates exhausted")
      loginError = Self.pairingErrorMessage(lastError)
      return
    }

    // TASK-817: same LAN guard as updateAPI()/buildCandidates — never force https on a bare private IP.
    let pairingEffectiveHTTPS = Self.isPrivateLANAddress(baseURL) ? false : useHTTPS
    guard let serverURL = normalizedBaseURL(baseURL, forceHTTPS: pairingEffectiveHTTPS, defaultPort: defaultPort) else {
      loginError = "Invalid server address. Please check the URL."
      return
    }

    do {
      let resp = try await APIClient(baseURL: serverURL, token: nil)
        .exchangePairingCode(code: code)
      sessionToken = resp.token
      startHeartbeatTimer()
    } catch {
      loginError = Self.pairingErrorMessage(error)
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
  /// Bumped by clearHomeState(). Detached rail computations capture it and drop their
  /// result if it changed while they were running.
  private var homeStateGeneration: UInt64 = 0

  func clearHomeState() {
    // Invalidate any in-flight off-actor rail computation. Cancelling
    // homeBackgroundFetchTask is not enough — recomputeHomeRails runs in a detached task
    // that is never stored, so it cannot be cancelled and must be fenced instead.
    homeStateGeneration &+= 1
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
    // SECURITY (TASK-775): explicitly delete the Top Shelf snapshot on logout/clear.
    // Setting homeJustAdded = [] above triggers writeTopShelfSnapshot()'s didSet, but that
    // function early-returns on empty state and never overwrites/removes the file — so a
    // stale topshelf.json from the previous session would otherwise persist on disk. Delete
    // it directly, independent of the empty-write guard.
    deleteTopShelfSnapshot()
  }

  /// Removes the persisted Top Shelf snapshot from the shared App Group container.
  /// Called on logout/clearHomeState so no cached content survives sign-out (TASK-775).
  func deleteTopShelfSnapshot() {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.HeiloProjects.DSReel"
    ) else { return }
    let fileURL = container.appendingPathComponent("topshelf.json")
    try? FileManager.default.removeItem(at: fileURL)
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
    let generation = homeStateGeneration
    Task.detached(priority: .userInitiated) { [weak self] in
      let (cont, added, watched) = Self.computeHomeRails(items)
      let elapsed = String(format: "%.3f", Date().timeIntervalSince(t))
      // Guard after the off-actor compute: if self was deallocated (e.g. logout)
      // during the heavy lift, silently drop the result (TASK-434).
      guard let self else { return }
      await MainActor.run {
        // The [weak self] check above is NOT sufficient: AppState is the app root and
        // does not deallocate on logout, so an in-flight recompute landed after
        // clearHomeState() had zeroed the rails — repopulating them with the PREVIOUS
        // user's content behind the login screen, and (via the homeJustAdded didSet)
        // rewriting the Top Shelf snapshot that logout had just deleted.
        guard generation == self.homeStateGeneration else {
          self.homeLog.info("recomputeHomeRails: stale result dropped (state was cleared mid-compute)")
          return
        }
        self.homeContinueWatching = cont
        self.homeJustAdded = added
        self.homeRecentlyWatched = watched
        self.homeLog.info("recomputeHomeRails: done in \(elapsed)s — cont=\(cont.count) added=\(added.count) watched=\(watched.count)")
        // The single highest-value line in the log for the "rails are missing" report:
        // it says whether the rails were computed empty (a data/filter problem) or
        // computed full but not rendered (a view problem). Those need opposite fixes.
        if cont.isEmpty && added.isEmpty && watched.isEmpty {
          dlog.warn(.home, "rails computed EMPTY from \(items.count) items — check addedAt/progress fields")
        } else {
          dlog.info(.home, "rails: ContinueWatching=\(cont.count) JustAdded=\(added.count) RecentlyWatched=\(watched.count) (from \(items.count) items)")
        }
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
          // Finished items belong in Recently Watched, not Continue Watching — use the
          // shared rule so the rails agree with what playback will actually resume.
          guard !PlaybackProgress.isFinished(
            positionSeconds: p.positionSeconds, durationSeconds: p.durationSeconds) else { return false }
          return Double(p.positionSeconds) / Double(p.durationSeconds) >= 0.05
        }
        .sorted { parseDate($0.progress?.updatedAt ?? $0.addedAt) > parseDate($1.progress?.updatedAt ?? $1.addedAt) }
    ).prefix(10))

    let recentlyWatched = Array(deduplicated(
      allItems
        .filter { item in
          guard let p = item.progress, p.durationSeconds > 0 else { return false }
          return PlaybackProgress.isFinished(
            positionSeconds: p.positionSeconds, durationSeconds: p.durationSeconds)
        }
        .sorted { parseDate($0.progress?.updatedAt ?? $0.addedAt) > parseDate($1.progress?.updatedAt ?? $1.addedAt) }
    ).prefix(8))

    let watchedIDs = Set((continueWatching + recentlyWatched).map(\.id))
    let justAdded = Array(deduplicatedByShow(
      allItems
        .filter { !watchedIDs.contains($0.id) }
        .sorted { parseDate($0.addedAt) > parseDate($1.addedAt) }
    ).prefix(8))

    return (continueWatching, justAdded, recentlyWatched)
  }

  // MARK: - Home Load

  func homeLoad() async {
    let callID = Int.random(in: 1000...9999)
    homeLog.info("homeLoad[\(callID)]: called — isLoading=\(self.homeIsLoading) isCacheDecoding=\(self.homeIsCacheDecoding) isBackgroundRefreshing=\(self.homeIsBackgroundRefreshing)")
    guard !homeIsLoading, !homeIsCacheDecoding, !homeIsBackgroundRefreshing else {
      homeLog.warning("homeLoad[\(callID)]: already loading/syncing, bailing")
      // A guard that never releases is how the rails stayed empty before: the flag latched
      // and every later call bailed here. If this line repeats with no matching completion,
      // that is the bug — not a slow network.
      dlog.warn(.home, "homeLoad bailed — busy (load=\(homeIsLoading) decode=\(homeIsCacheDecoding) bg=\(homeIsBackgroundRefreshing))")
      return
    }

    if isDemoMode {
      homeLibraries = DemoData.libraries
      let demoItems = DemoData.movieItems + DemoData.tvItems
      recomputeHomeRails(from: demoItems)
      return
    }

    // Already have in-memory rail data — run heartbeat to check for changes.
    //
    // This MUST gate on the rails themselves, not on libraries. The condition used to
    // be `!homeAllRailsEmpty || !homeLibraries.isEmpty`, and that `||` meant a session
    // which had loaded libraries but NOT yet loaded rails took this early return and
    // never reached the cold-start path below that actually queries them from SQLite.
    // On tvOS that was reliably the case — libraries populate first — so Continue
    // Watching / Just Added / Recently Watched never appeared on the TV at all while
    // the Movies and TV Shows rails showed fine.
    if !homeAllRailsEmpty {
      homeLog.info("homeLoad[\(callID)]: PATH=in-memory — rails populated, running heartbeat")
      dlog.info(.home, "homeLoad: in-memory (CW=\(homeContinueWatching.count) JA=\(homeJustAdded.count) RW=\(homeRecentlyWatched.count))")
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
      dlog.info(.home, "homeLoad: cold start from local DB")
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
      // defer, NOT a straight-line reset after the await. `.task` cancellation is
      // cooperative and unwinds through this await, so a plain `homeIsLoading = false` on
      // the next line never runs when the task is cancelled — the flag LATCHES true and
      // every later homeLoad() bails at the re-entrancy guard above.
      //
      // That is precisely the tvOS pairing case: homeLoad() starts on the pairing screen,
      // the token arrives, .task(id: sessionToken) cancels the in-flight run and starts a
      // new one — which then found homeIsLoading still true and returned immediately,
      // leaving the rails empty. Same defect class as the AuthenticatedImage isLoading
      // latch (fixed 2026-07-28): a bool guard that a cancelled task never clears.
      defer { homeIsLoading = false }
      await runDeltaSync(background: false)
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
    defer { homeIsLoading = false }   // see homeLoad(): cancellation must not latch the flag
    await runDeltaSync(background: false)
    // Bump version so TVLibraryRail views re-fetch their content via .task(id:).
    libraryRailsVersion = UUID()
  }

  /// TASK-738: lightweight refresh when the app returns to the foreground, so
  /// Continue Watching reflects playback that happened on another device while we
  /// were backgrounded. Runs a background delta sync (heartbeat + changed items
  /// only — not a full reload) and skips when offline or already busy.
  func foregroundRefresh() async {
    reconcileOfflineFlag()
    guard !isDemoMode, !isOffline, !serverUnreachable else { return }
    guard !homeIsLoading, !homeIsCacheDecoding, !homeIsBackgroundRefreshing else { return }
    await runDeltaSyncWithBackgroundTask()
  }

  /// TASK-787: single foreground-coordination owner. Previously TWO scenePhase==.active
  /// handlers (app-level → foregroundRefresh, LibrariesView → revalidateConnection+homeLoad)
  /// fired on the same event with no ordering, racing the shared home-* flags. This is now
  /// the ONLY foreground entry point: revalidate the connection first (running the LAN→WAN
  /// cascade if the address went stale while backgrounded), then refresh exactly once.
  /// On `.switched`, revalidateConnection already posts networkDidReconnect (which drives
  /// homeLoad), so we must not refresh again here.
  private var isForegroundCoordinating = false
  func foregroundReconnectAndRefresh() async {
    guard sessionToken != nil else { return }
    // Re-entrancy guard: a second .active event (or a slow revalidate overlapping the
    // next foreground) must not launch a parallel revalidate/refresh pass.
    guard !isForegroundCoordinating else { return }
    isForegroundCoordinating = true
    defer { isForegroundCoordinating = false }

    let result = await revalidateConnection()
    // .switched → networkDidReconnect already triggered homeLoad; don't double-refresh.
    guard result != .switched else { return }
    await foregroundRefresh()
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

    // Step 0: push before pulling. Any progress recorded while the NAS was unreachable is
    // still flagged pending; it MUST go up before we download the server's copy, otherwise
    // the server's older value comes back down and upsertProgress's last-writer-wins
    // comparison overwrites the newer local position — silently losing the user's place.
    await flushPendingProgress()

    do {
      // Step 1: Get server seq numbers and our local cursors
      let status = try await apiSnapshot.syncStatus()
      let cursors = await LocalStore.shared.getSyncCursors()
      homeLog.info("runDeltaSync: server itemSeq=\(status.itemSeq) local=\(cursors.itemSeq) | server progressSeq=\(status.progressSeq) local=\(cursors.progressSeq)")

      // Step 2: Fetch libraries (always fast, small payload)
      let libs = try await apiSnapshot.libraries().libraries
      homeLibraries = libs
      // Library names and counts. If a library the user expects is absent here, the problem
      // is server-side indexing, not the client — which saves a round of client debugging.
      if libs.isEmpty {
        dlog.warn(.library, "server returned ZERO libraries")
      } else {
        dlog.info(.library, "libraries: \(libs.map(\.title).joined(separator: ", "))")
      }
      dlog.info(.library, "sync: server itemSeq=\(status.itemSeq) local=\(cursors.itemSeq) progressSeq=\(status.progressSeq)/\(cursors.progressSeq)")

      // Step 3: Fetch item deltas if server has new items
      let localCount = await LocalStore.shared.totalItemCount()
      if status.itemSeq > cursors.itemSeq || localCount == 0 {
        homeLog.info("runDeltaSync: fetching item deltas since seq=\(cursors.itemSeq)")
        var since = cursors.itemSeq
        var afterRowid: Int? = nil
        var pageCount = 0
        // Safety valves, mirroring the TASK-790 valve on the library grid. This loop
        // is driven entirely by server-supplied `hasMore` + cursor, so a server that
        // reports hasMore:true without advancing the cursor would spin it forever,
        // hammering the NAS. 200 pages x 500 = 100k items, far past any real library.
        let maxSyncPages = 200
        var lastCursor: (Int, Int?)? = nil
        // TASK-847: did the loop actually reach the end of the server's changes?
        // Only a natural termination (empty page, or hasMore == false) means "we have
        // consumed everything up to status.itemSeq". Bailing out through either safety
        // valve leaves an un-fetched gap, and jumping the cursor to status.itemSeq anyway
        // would skip that gap PERMANENTLY: the next sync sees cursors.itemSeq ==
        // status.itemSeq, the `status.itemSeq > cursors.itemSeq` gate is false, and step 3
        // never runs again. The tail of the library would be missing from grids, search and
        // every rail until a sign-out forced a full resync — while the log line at the
        // page cap promised the opposite ("remaining items sync on the next cycle").
        var reachedEndOfChanges = false
        repeat {
          let page = try await apiSnapshot.syncItems(since: since, limit: 500, afterRowid: afterRowid)
          if !page.items.isEmpty {
            await LocalStore.shared.upsertItems(page.items)
            since = page.nextSeq
            afterRowid = page.hasMore ? page.nextAfterRowid : nil
            pageCount += 1

            // Non-advancing cursor: the next request would be byte-identical to the
            // one we just made, so we'd refetch the same page indefinitely. Stop and
            // let the next sync cycle retry from the last committed cursor.
            let cursor = (since, afterRowid)
            if let last = lastCursor, last.0 == cursor.0, last.1 == cursor.1 {
              homeLog.error("runDeltaSync: cursor stalled at seq=\(since) after \(pageCount) pages — aborting to avoid an infinite sync loop")
              break
            }
            lastCursor = cursor

            if pageCount >= maxSyncPages {
              homeLog.error("runDeltaSync: hit \(maxSyncPages)-page cap — stopping; remaining items sync on the next cycle")
              break
            }
            // After first page on cold start, show rails immediately
            if !background && pageCount == 1 {
              let rails = await LocalStore.shared.queryRails()
              homeContinueWatching = rails.continueWatching
              homeJustAdded = rails.justAdded
              homeRecentlyWatched = rails.recentlyWatched
            }
            if !page.hasMore {
              reachedEndOfChanges = true
              break
            }
          } else {
            // Server returned no items for this cursor — nothing further to consume.
            reachedEndOfChanges = true
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
          // TASK-847: advance only to what was actually consumed. On a clean run that is
          // status.itemSeq; on an early exit it is `since`, the last cursor the loop
          // committed, so the un-fetched remainder is re-requested next cycle instead of
          // being skipped forever.
          let committedSeq = reachedEndOfChanges ? status.itemSeq : min(since, status.itemSeq)
          await LocalStore.shared.setItemSeq(committedSeq)
          if reachedEndOfChanges {
            homeLog.info("runDeltaSync: item sync complete — \(pageCount) page(s)")
          } else {
            homeLog.warning("runDeltaSync: item sync stopped early — cursor advanced only to \(committedSeq) of \(status.itemSeq); remainder syncs next cycle")
          }
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
      // Heartbeat failures are usually transient. But a persistent failure here is the
      // signal that we've moved off the network the current address lives on (e.g. left
      // the LAN mid-session and NWPathMonitor didn't deliver a path update). Re-probe:
      // if the current address is dead, revalidateConnection() runs the LAN→WAN cascade
      // and switches us over so the next heartbeat lands. Guard against piling up behind
      // an in-flight reconnect.
      homeLog.debug("heartbeat: failed — \(error.localizedDescription); revalidating")
      if !isReconnecting {
        _ = await revalidateConnection()
      }
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

  /// Optimistic progress write: update the local store immediately (durability), mark it
  /// pending, then attempt the network write. On failure the row STAYS pending and is
  /// retried by `flushPendingProgress()`.
  ///
  /// The previous version fired a detached, unretried Task and only logged failure. Its
  /// comment claimed "the delta-sync cursor reconciles the server on the next sync pass" —
  /// that mechanism never existed; sync is download-only. Every progress update made while
  /// the NAS was unreachable was therefore lost permanently, which is why the server held
  /// zero progress rows while the phone displayed a populated Continue Watching rail, and
  /// why Continue Watching / Recently Watched were empty on every other device.
  func recordProgress(itemId: String, positionSeconds: Int, durationSeconds: Int) async {
    guard !isDemoMode else { return }
    await LocalStore.shared.upsertSingleProgress(
      itemId: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds)

    do {
      try await api.setProgress(id: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
      await LocalStore.shared.markProgressSynced(
        itemId: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    } catch {
      // Stays flagged pending — flushPendingProgress() will retry on the next foreground,
      // reconnect, or sync pass. Not data loss: the local write above already landed.
      homeLog.warning("recordProgress: server write failed for \(itemId) — \(error.localizedDescription); queued for retry")
    }
  }

  /// Mark an item fully watched, or clear its progress entirely.
  ///
  /// Watched state in this app is DERIVED from position (PlaybackProgress.isFinished), and
  /// the only writer was implicit playback progress — so there was no way to mark something
  /// watched that you saw elsewhere, and no way to evict a title from Continue Watching
  /// short of playing it to the end. An accidental tap parked a film there permanently.
  ///
  /// Implemented on the existing progress endpoint rather than a new one: writing
  /// position == duration reads as finished everywhere (rails, badges, resume), and
  /// writing 0 clears it. Both route through recordProgress, so they inherit its
  /// local-first write and retry outbox and work offline.
  func setWatched(itemId: String, durationSeconds: Int, watched: Bool) async {
    await recordProgress(
      itemId: itemId,
      positionSeconds: watched ? durationSeconds : 0,
      durationSeconds: durationSeconds
    )
    await refreshProgressFromLocal()
  }

  /// Uploads progress the server has not confirmed. Idempotent and safe to call often —
  /// returns immediately when the outbox is empty.
  ///
  /// Called on foreground, after a successful reconnect, and at the start of a delta sync,
  /// so a device that recorded progress offline pushes it as soon as the NAS is reachable
  /// again. Ordering is oldest-first so a replay reconstructs the real watch sequence.
  ///
  /// On the server side each write is stamped with a monotone progress.write_seq and the
  /// upsert only applies when the incoming seq is higher, so a replayed backlog cannot
  /// clobber a newer value written from another device.
  ///
  /// This comment previously claimed the server ran "a last-writer-wins comparison [that]
  /// discards anything staler than what it holds." That was FALSE when written — the
  /// ON CONFLICT had no WHERE clause at all, making the server a pure last-write-wins sink,
  /// and a replay from an upgraded device destroyed newer progress (proven live 2026-08-05:
  /// POST 7500 then POST 6000 left the row at 6000). The guarantee is real NOW because
  /// aabc29a implemented it; it is described here as mechanism, not assumption. Verify
  /// against handleProgress before trusting it again.
  func flushPendingProgress() async {
    guard !isDemoMode, sessionToken != nil, !isOffline, !serverUnreachable else { return }

    // Re-entrancy guard, same pattern as reconnect()'s isReconnecting.
    //
    // @MainActor gives memory safety, NOT mutual exclusion across an await. There are two
    // callers — runDeltaSync awaits this, and clearNetworkError fires it detached — and a
    // reconnect during a sync runs both. The second entrant reads pendingProgress() before
    // the first has confirmed its rows, so the same progress is POSTed twice: duplicate
    // writes, and a doubled progress_seq bump that forces every other device into a
    // redundant re-sync.
    guard !isFlushingProgress else {
      homeLog.info("flushPendingProgress: already in flight — skipping re-entrant call")
      return
    }
    isFlushingProgress = true
    defer { isFlushingProgress = false }

    let pending = await LocalStore.shared.pendingProgress()
    guard !pending.isEmpty else { return }

    homeLog.info("flushPendingProgress: \(pending.count) queued progress row(s) to upload")
    var uploaded = 0
    var dropped = 0
    for row in pending {
      do {
        try await api.setProgress(
          id: row.itemId, positionSeconds: row.positionSeconds, durationSeconds: row.durationSeconds)
        await LocalStore.shared.markProgressSynced(
          itemId: row.itemId, positionSeconds: row.positionSeconds, durationSeconds: row.durationSeconds)
        uploaded += 1
      } catch {
        // A PERMANENT rejection must not block the queue behind it.
        //
        // The server 404s progress for an item it no longer has (main.go TASK-797 guard) and
        // 400s a value that fails validation. Neither will ever succeed on retry. The original
        // version of this loop returned on ANY error, so one deleted movie with queued progress
        // stalled the entire outbox forever — silently, and with no self-heal: every later
        // update queued behind it and never uploaded. Drop the row (clear its flag so it stops
        // being retried) and keep going.
        //
        // Transient failures — offline, timeout, 5xx, auth — still stop the loop, because those
        // WILL succeed later and hammering an unreachable NAS with the whole backlog is exactly
        // what the stop-on-first-failure rule was for.
        if let apiErr = error as? APIError, apiErr.isPermanentRejection {
          homeLog.warning("flushPendingProgress: dropping \(row.itemId) — server rejected permanently (\(apiErr.userMessage))")
          // dropPendingProgress, NOT markProgressSynced: the latter is value-guarded on
          // (position, duration) so a stale ack cannot clear a newer local write. If the
          // user kept watching during the flush, the row now holds a different position and
          // the guarded update matches nothing — the row stayed pending and was retried on
          // every subsequent flush, exactly the stall this drop path exists to prevent.
          await LocalStore.shared.dropPendingProgress(itemId: row.itemId)
          dropped += 1
          continue
        }
        homeLog.warning("flushPendingProgress: stopped after \(uploaded) upload(s), \(dropped) dropped — \(error.localizedDescription)")
        return
      }
    }
    homeLog.info("flushPendingProgress: uploaded \(uploaded) row(s), dropped \(dropped) permanently-rejected row(s)")
  }

  // homeRefreshProgress kept for backwards compat with any view that calls it
  func homeRefreshProgress() async {
    await runHeartbeat()
  }

  // MARK: - Watchlist

  var watchlistItems: [ItemSummary] = []

  /// TASK-851: non-nil when the last loadWatchlist() attempt failed.
  ///
  /// Without this, a failed load is indistinguishable from a genuinely empty watchlist:
  /// watchlistItems stays at its previous value — [] on a cold launch, and [] again after
  /// logout/softLogout/handleConnectionFailure force-clear it — so WatchlistView renders
  /// its "nothing in your watchlist" empty state and tells the user their list is empty
  /// when in fact the request threw.
  ///
  /// VIEW HOOKUP (owned by another agent): Views/MainView.swift — WatchlistView, whose
  /// `.task { await appState.loadWatchlist() }` is around line 646. It should branch on
  /// `appState.watchlistLoadFailed` BEFORE its empty-state branch and show an error +
  /// Retry affordance (Retry = call loadWatchlist() again) instead of "nothing here".
  var watchlistLoadFailed: Bool = false

  func loadWatchlist() async {
    guard !isDemoMode, sessionToken != nil else { return }
    do {
      let resp = try await api.watchlist()
      watchlistItems = resp.items
      watchlistLoadFailed = false
    } catch {
      // Still non-fatal — the watchlist is supplementary and must not block the home load.
      // But it is no longer silent:
      //  - TASK-850: every other failure path in this file logs; an empty catch left a
      //    permanently stale/empty watchlist with zero signal in a sysdiagnose to explain it.
      //  - TASK-851: record the failure so the view can distinguish it from a real empty list.
      //  - TASK-851: route through handleConnectionFailure so a 401 here contributes to
      //    session-expiry detection like every other network path in AppState. This was the
      //    only one that did not.
      watchlistLoadFailed = true
      homeLog.warning("loadWatchlist failed: \(error.localizedDescription)")
      handleConnectionFailure(error)
    }
  }

  func toggleWatchlist(item: ItemSummary) async {
    guard !isDemoMode else { return }
    // TASK-820: optimistic update, but revert on server failure so the UI can't
    // diverge silently from the server until the next full sync.
    let alreadyIn = watchlistItems.contains(where: { $0.id == item.id })
    if alreadyIn {
      let removedIndex = watchlistItems.firstIndex(where: { $0.id == item.id })
      watchlistItems.removeAll(where: { $0.id == item.id })
      do {
        try await api.removeFromWatchlist(id: item.id)
      } catch {
        // Restore at the original position (clamped) so ordering is preserved.
        let insertAt = min(removedIndex ?? 0, watchlistItems.count)
        watchlistItems.insert(item, at: insertAt)
        // A bare catch swallowed 401s here: the write silently no-op'd while the UI kept
        // looking authenticated. loadWatchlist already routes failures this way.
        handleConnectionFailure(error)
      }
    } else {
      watchlistItems.insert(item, at: 0)
      do {
        try await api.addToWatchlist(id: item.id)
      } catch {
        watchlistItems.removeAll(where: { $0.id == item.id })
        handleConnectionFailure(error)
      }
    }
  }

  // MARK: - Deep Link

  /// Set when the app is opened via a dsvideo://item/{id} URL from the Top Shelf.
  var pendingDeepLinkItemID: String? = nil

  // MARK: - Top Shelf Snapshot

  /// Writes the Just Added rail (up to 10 items) to the shared App Group container
  /// so the Top Shelf extension can display them when the app is focused.
  func writeTopShelfSnapshot() {
    // An empty rail must CLEAR the shelf, not leave the previous contents advertised.
    // The early-return here meant any non-logout path to an empty homeJustAdded (server
    // unreachable, library removed, a failed load that cleared the rails) left a stale
    // topshelf.json on disk — so the Top Shelf kept offering titles that deep-linked into
    // items the user may no longer have access to.
    guard !homeJustAdded.isEmpty else {
      deleteTopShelfSnapshot()
      return
    }
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.HeiloProjects.DSReel"
    ) else { return }

    let items: [TopShelfItem] = homeJustAdded.prefix(10).compactMap { item in
      // Prefer backdrop for landscape Top Shelf cards, fall back to poster
      let imageID = item.backdropImageId ?? item.posterImageId
      // SECURITY (TASK-774): do NOT bake the live bearer session token into the persisted
      // image URL. This file is unencrypted JSON in a shared App Group container — a token
      // written here is a working, long-lived credential readable via device backup or any
      // process with the group entitlement. The Top Shelf extension uses setImageURL(), which
      // is fetched by the tvOS system and cannot inject an Authorization header, and there is
      // no shared Keychain access group between the app and the extension. So we fail closed:
      // persist the tokenless URL only. Artwork that requires auth simply won't render in Top
      // Shelf; titles + deep links still work. Never persist the credential.
      let imageURLString: String? = imageID.flatMap { api.imageURL(id: $0, width: 760)?.absoluteString }
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

/// Canonical ports. These are the ONLY port defaults in the app.
///
/// There used to be three conflicting sources — this function's signature defaulted to 8090,
/// AppState.init() read a stored value falling back to 5000, and QuickConnectResolver had its
/// own 5001/5000 pair. Worse, the scheme did not influence the port at all: turning HTTPS on
/// without typing a port produced `https://host:5000`, which cannot work because 5000 is
/// DSM's plaintext port. That combination — HTTPS on, no port — is what a user naturally
/// enters for a remote address, and it failed with a generic "check that the server is
/// running" message pointing at a server that was answering perfectly well.
enum ServerPort {
  /// DSM's HTTPS port. nginx proxies /api/v1 through to the backend.
  static let https = 5001
  /// DSM's HTTP port. Same proxy, no TLS.
  static let http = 5000
  /// The backend listening directly, bypassing DSM's nginx. HTTP only.
  static let backendDirect = 8090
}

/// Builds the base URL for a server address.
///
/// `defaultPort` is a caller-supplied preference (the user's saved Default Port setting). It
/// is used ONLY when it is consistent with the scheme — an explicit port in the input always
/// wins, and when no preference applies the scheme decides. Passing nil means "let the scheme
/// decide", which is what every remote-address path should do.
func normalizedBaseURL(_ input: String, forceHTTPS: Bool, defaultPort: Int? = nil) -> URL? {
  var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !s.isEmpty else { return nil }
  if !s.contains("://") {
    s = (forceHTTPS ? "https://" : "http://") + s
  }
  if forceHTTPS {
    s = s.replacingOccurrences(of: "http://", with: "https://")
  }

  guard var url = URL(string: s), url.host != nil else { return nil }

  // Add a port only if none was typed.
  // Skip quickconnect.to — it's a relay host, not a DSVideoServer endpoint.
  let host = url.host ?? ""
  if url.port == nil && !host.hasSuffix("quickconnect.to") {
    // THE SCHEME DECIDES. A saved preference is honoured only when it matches the scheme:
    // carrying 5000 (plaintext DSM) onto an https:// URL builds an address nothing answers,
    // and carrying 5001 onto http:// does the same in reverse.
    let schemeDefault = forceHTTPS ? ServerPort.https : ServerPort.http
    let port: Int
    if let preferred = defaultPort, preferred > 0 {
      let preferredMatchesScheme = forceHTTPS
        ? (preferred != ServerPort.http)
        : (preferred != ServerPort.https)
      port = preferredMatchesScheme ? preferred : schemeDefault
    } else {
      port = schemeDefault
    }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.port = port
    if let newURL = components?.url { url = newURL }
  }

  return url
}

