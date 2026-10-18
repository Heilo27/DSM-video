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
  /// Transcode quality cap, bound to a Picker on both platforms.
  ///
  /// Was `@ObservationIgnored @AppStorage`, which is a contradiction here: @Observable
  /// cannot see through @AppStorage, and @ObservationIgnored explicitly opts the property
  /// OUT of change tracking — so mutating it emitted no observation event and the Picker
  /// would not re-render when the value changed from anywhere but itself. Its seven
  /// sibling settings all use this observed-property + didSet form; this was the outlier.
  var qualityCap: String {
    didSet { UserDefaults.standard.set(qualityCap, forKey: Keys.qualityCap) }
  }

  /// Non-routable placeholder used when the stored URL is empty or malformed at init time.
  /// Uses HTTPS so ATS doesn't block it; requests fail silently since 0.0.0.0 is unreachable.
  static let fallbackURL = URL(string: "https://0.0.0.0")!
  private enum Keys {
    static let baseURL = "dsReel.baseURL"
    /// The last address a login or reconnect actually SUCCEEDED on — see lastGoodAddress.
    static let lastGoodAddress = "dsReel.lastGoodAddress"
    static let lanAddress = "dsReel.lanAddress"
    static let wanAddress = "dsReel.wanAddress"
    static let username = "dsReel.username"
    static let rememberMe = "dsReel.rememberMe"
    static let useHTTPS = "dsReel.useHTTPS"
    static let defaultPort = "dsReel.defaultPort"
    static let keychainService = "com.heiloprojects.dsreel"
    static let keychainAccount = "savedPassword"
    static let keychainAccountToken = "sessionToken"
    static let qualityCap = "dsReel.qualityCap"
  }

  var baseURL: String {
    didSet {
      UserDefaults.standard.set(baseURL, forKey: Keys.baseURL)
      updateAPI()
    }
  }

  /// The last address a login or reconnect actually succeeded on.
  ///
  /// The candidate cascade tries addresses in the order QuickConnect happens to list the
  /// NAS's interfaces, which is arbitrary — this NAS advertises both eth0 (.145) and eth1
  /// (.148) and the app used whichever DSM named first. That is not a failure (both answer),
  /// but it is a coin flip on every launch, and it means a working address is re-discovered
  /// rather than remembered.
  ///
  /// Recording the winner and trying it FIRST makes the choice stable, and makes a stale
  /// baseURL self-correcting in one attempt instead of a full cascade: the device log that
  /// prompted this showed a stored baseURL of 192.168.50.146:8090 — a host that has not
  /// existed for some time — with the app reaching the server only because QuickConnect
  /// supplied working candidates behind it.
  ///
  /// Deliberately NOT the same thing as baseURL: baseURL is what the USER configured (or
  /// the last winner), while this is purely a performance/stability hint. A wrong value
  /// here costs one failed 2s probe and nothing else, so it never needs to be authoritative.
  var lastGoodAddress: String {
    didSet { UserDefaults.standard.set(lastGoodAddress, forKey: Keys.lastGoodAddress) }
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
    // The legacy "http://localhost:5000" default is still treated as "not configured" so a
    // user upgrading from a build that persisted it is not mistaken for a returning user.
    return !addr.isEmpty && addr != "http://localhost:5000" && !savedPassword.isEmpty
  }

  var isOffline: Bool = false
  var serverUnreachable: Bool = false
  /// The ONE "the server cannot be reached right now" rule (explicitly offline, or a failed
  /// reach). Every gate, banner and animation reads this, never `isOffline || serverUnreachable`
  /// written out again (TASK-1022). The static form is for the few places that hold the two
  /// flags as plain values (OfflineBanner, ItemDetailView.playUnavailableOffline).
  nonisolated static func serverUnavailable(isOffline: Bool, serverUnreachable: Bool) -> Bool {
    isOffline || serverUnreachable
  }
  var isServerUnavailable: Bool {
    Self.serverUnavailable(isOffline: isOffline, serverUnreachable: serverUnreachable)
  }
  /// A request to the server was refused because Local Network access is off (TASK-949).
  /// Rides alongside `serverUnreachable` (the reconnect loop still runs, and can land on the
  /// WAN address) and only changes what the banner says. Never sets `isOffline`: the device's
  /// network works, and NWPathMonitor would never clear a flag it did not set.
  var localNetworkDenied: Bool = false

  /// Whether this session's server supports profiles. In memory: `.unknown` at launch and
  /// after sign-out, moved only by `refreshProfiles()`. Read through `progressSyncAllowed`.
  var profileSupport: ProfileSupport = .unknown

  /// True while the views must show the profile picker instead of home (FR-260). Set only by
  /// `evaluateProfilePicker` from `ProfileGate.shouldShowPicker`; cleared by `switchProfile`.
  /// While it is set, `homeLoad` loads nothing, so no rail from the remembered profile renders
  /// behind the picker.
  private(set) var needsProfilePicker: Bool = false
  /// The last picker moment not yet settled against a FRESH profile list. Kept because the
  /// moment (pairing, launch) usually arrives before `GET /profiles` answers.
  private var pendingPickerTrigger: ProfilePickerTrigger?

  /// Bumped whenever ActiveProfileStore changes from here, so views observing the computed
  /// profile properties below re-render. The store stays the ONE home of the data (it is
  /// app-group UserDefaults, which Observation cannot see); this only makes reads tracked.
  private var profileRevision = 0
  /// The account's profile limit as the server last stated it (FR-200).
  private var serverMaxProfiles: Int?
  /// The age ladder's display labels from GET /profiles/age-levels. Display only: the
  /// ladder itself is never re-implemented here. Empty until the server has answered.
  private(set) var ageLevels: [AgeLevelsResponse.Level] = []

  /// The account's profiles as last known (fresh list, else the cached one) (FR-263).
  var profiles: [Profile] {
    _ = profileRevision
    return profileStore.cachedProfiles
  }

  /// The profile this device is acting for, if one is chosen and still listed.
  var activeProfile: Profile? {
    _ = profileRevision
    guard let id = profileStore.activeProfileID else { return nil }
    return profileStore.cachedProfiles.first { $0.id == id }
  }

  /// FR-200's limit, owner included. The server enforces it (`profile_limit_reached`).
  var maxProfiles: Int { serverMaxProfiles ?? 4 }

  /// The display label for an age level ("Little Kids"): this session's ladder, else the one
  /// the device last stored (so an offline cold launch still names it, FR-265). nil only if the
  /// server has never sent a ladder to this device; callers then fall back to wording that
  /// does not name the level.
  func ageLevelLabel(_ level: Int) -> String? {
    ageLevel(level)?.label
  }

  /// The certifications an age level covers, as the server's ladder lists them
  /// ("PG · TV-Y7, TV-Y7-FV, TV-PG"), plus "Unrated" on the level unrated titles count as
  /// (FR-242). Same source and fallback as `ageLevelLabel`; nil when no ladder has ever arrived.
  func ageLevelRatings(_ level: Int) -> String? {
    guard let tier = ageLevel(level) else { return nil }
    var parts = [tier.movie, tier.tv].map { $0.joined(separator: ", ") }.filter { !$0.isEmpty }
    if level == profileStore.unratedLevel { parts.append("Unrated") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func ageLevel(_ level: Int) -> AgeLevelsResponse.Level? {
    ageLevels.first { $0.level == level } ?? profileStore.cachedAgeLevels.first { $0.level == level }
  }
  /// When the app last went to the background, for the tvOS 30-minute rule.
  private var enteredBackgroundAt: Date?

  /// Set when the on-disk store could not be opened, so local persistence is dead and the
  /// server write is the only copy of a watch position. Surfaced as a banner; nil when healthy.
  var localStoreUnavailableMessage: String?
  /// Warn once per launch, not once per progress tick.
  private var hasWarnedStoreUnavailable = false
  // FIX-16: Guard flag so concurrent reconnect() calls don't race.
  var isReconnecting: Bool = false
  /// Guards flushPendingProgress against concurrent entry (runDeltaSync awaits it while
  /// clearNetworkError fires it detached). See flushPendingProgress for why @MainActor
  /// alone is not enough.
  var isFlushingProgress: Bool = false

  private var networkMonitor: NWPathMonitor?
  private var heartbeatTimer: Timer?
  /// Readable so a test can stop the retry it drove; only startBackgroundReconnectRetry()
  /// and the sign-out paths assign it.
  private(set) var reconnectRetryTask: Task<Void, Never>?

  /// Pacing for startBackgroundReconnectRetry(). A fast ladder for the first minutes, then a
  /// slow steady cadence for as long as the session lives: running out of attempts is never a
  /// reason to sign out (FR-120). Instance-level so a test can shrink the waits.
  struct ReconnectRetryPolicy {
    /// Waits before each fast attempt, in order.
    var fastDelays: [Duration]
    /// Wait before every attempt after the fast ladder is spent.
    var slowInterval: Duration

    /// 5, 10, 20, then 30s for 20 attempts in all (~9.5 min), then every 2 minutes.
    static let standard = ReconnectRetryPolicy(
      fastDelays: [.seconds(5), .seconds(10), .seconds(20)] + Array(repeating: .seconds(30), count: 17),
      slowInterval: .seconds(120))

    func delay(beforeAttempt attempt: Int) -> Duration {
      attempt <= fastDelays.count ? fastDelays[attempt - 1] : slowInterval
    }
  }
  var reconnectRetryPolicy = ReconnectRetryPolicy.standard

  /// The QuickConnect lookup every candidate cascade goes through. Production asks
  /// global.quickconnect.to; a test swaps in a resolver that fails or answers on cue.
  var quickConnectResolve: (String) async throws -> [QuickConnectResolver.Candidate] = {
    try await QuickConnectResolver.resolveCandidates(id: $0)
  }

  /// How a device with no server configured finds one to redeem a pairing code on (TASK-972,
  /// FR-117). Production browses the local network for `_dsvideo._tcp`; a test answers with
  /// its stub server, or with nothing.
  var discoverPairingServers: @MainActor () async -> (urls: [URL], denied: Bool) = {
    await AppState.browseForPairingServers(window: .seconds(4))
  }

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
      // A new session (sign-in, pairing) is a picker moment (FR-260). A token refresh is not:
      // it replaces a token, never starts from none.
      if oldValue == nil, sessionToken != nil {
        notePickerTrigger(.signedIn)
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

  /// The ONE home of the active profile and the cached profile list for this AppState
  /// (FR-220, FR-264). Production is always `.shared`; tests pass a store on a throwaway
  /// UserDefaults suite so they never touch the app-group defaults (TASK-925). Every
  /// APIClient this AppState builds reads its `X-DSVideo-Profile` header from this same store.
  let profileStore: ActiveProfileStore
  /// The offline catalog this AppState reads and writes. Production is always `.shared`;
  /// tests pass a store on a temp database (`LocalStore.makeForTesting`).
  let localStore: LocalStore

  // Use custom REST API client (our backend)
  private(set) var api: APIClient

  /// Every APIClient this AppState makes goes through here so it carries `profileStore`.
  private func makeClient(baseURL: URL, token: String?, usesTunnelCookie: Bool = false) -> APIClient {
    var client = APIClient(baseURL: baseURL, token: token, usesTunnelCookie: usesTunnelCookie)
    client.profileStore = profileStore
    return client
  }

  private func updateAPI() {
    // If baseURL is a bare QuickConnect ID, we can't build a usable URL without
    // resolving it first — leave api as-is. login() will resolve and set api correctly.
    if QuickConnectResolver.extractBareID(from: baseURL) != nil { return }
    // TASK-817: useHTTPS is really "the last winning network's scheme," not a per-address
    // preference. Apply the same LAN guard as buildCandidates() (TASK-779) so a bare
    // private IP is never forced to https:// — bare-IP TLS has no valid cert and fails.
    let effectiveHTTPS = Self.isPrivateLANAddress(baseURL) ? false : useHTTPS
    // An unconfigured or malformed address yields no URL. Still rebuild the client — on the
    // non-routable placeholder — so that a token set before an address (QuickConnect resolves
    // the address later) is not silently dropped. Requests against the placeholder fail
    // harmlessly; a client holding a stale token while `sessionToken` says otherwise does not.
    let url = normalizedBaseURL(baseURL, forceHTTPS: effectiveHTTPS, defaultPort: defaultPort)
      ?? Self.fallbackURL
    api = makeClient(
      baseURL: url,
      token: sessionToken
    )
  }

  init(profileStore: ActiveProfileStore = .shared, localStore: LocalStore = .shared) {
    self.profileStore = profileStore
    self.localStore = localStore
    #if DEBUG
    // Must run BEFORE any stored value is read below, or this launch would load the state it
    // is supposed to be clearing.
    if AppState.isUITestResetLaunch {
      AppState.resetPersistedStateForUITests()
    }
    #endif
    let d = UserDefaults.standard
    // Empty means "not configured yet" — the setup screen prompts for an address.
    //
    // This used to default to "http://localhost:5000", which SHIPPED prefilled on the tvOS
    // sign-in screen. On an Apple TV localhost is the Apple TV itself, so the default could
    // never work, and it also poisoned pairing (the code exchange POSTed to localhost and
    // 403'd). normalizedBaseURL already maps an empty value to the non-routable placeholder,
    // so nothing downstream needs a sentinel address.
    let storedBaseURL = d.string(forKey: Keys.baseURL) ?? ""
    // useHTTPS defaults to false — port 5000 is plain HTTP; login() auto-detects
    // and persists the correct scheme from whichever candidate wins.
    let storedUseHTTPS = d.object(forKey: Keys.useHTTPS) as? Bool ?? false
    let storedRememberMe = d.object(forKey: Keys.rememberMe) as? Bool ?? true
    let storedDefaultPort = d.object(forKey: Keys.defaultPort) as? Int ?? 5000

    qualityCap = d.string(forKey: Keys.qualityCap) ?? "auto"
    baseURL = storedBaseURL
    lastGoodAddress = d.string(forKey: Keys.lastGoodAddress) ?? ""
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
    var initialClient = APIClient(baseURL: resolvedInitURL, token: storedToken)
    initialClient.profileStore = profileStore
    api = initialClient
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
    // UI-TEST SIRI HOOK: stands in for FindItemIntent setting a pending search term.
    // A UI test cannot speak to Siri, and the intent itself is thin — it resolves a term
    // and writes this property. Injecting the property is what lets a test exercise the
    // part that actually broke on the Top Shelf deep link: the cold-launch race where a
    // value is set before the view exists.
    //   Launch argument: -UITestSiriSearch <term>
    if let term = AppState.uiTestSiriSearchTerm {
      pendingSearchTerm = term
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

    // didSet does not run in init, so a stored session is registered as a launch here. The
    // cached list decides at once (tvOS asks before any rail renders); a fresh list settles it.
    if sessionToken != nil, !isDemoMode {
      notePickerTrigger(.coldLaunch)
    }
  }

  #if DEBUG
  /// True when the process was launched with the demo hook explicitly requested.
  /// Gated to DEBUG builds; the launch-arg/env-var check is the real guard.
  static var isUITestDemoLaunch: Bool {
    ProcessInfo.processInfo.arguments.contains("-UITestDemoMode")
      || ProcessInfo.processInfo.environment["UITEST_DEMO"] == "1"
  }

  /// The term passed as `-UITestSiriSearch <term>`, standing in for Siri's FindItemIntent.
  /// nil unless the argument is present, so ordinary launches are untouched.
  static var uiTestSiriSearchTerm: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let flag = args.firstIndex(of: "-UITestSiriSearch"),
          args.index(after: flag) < args.endIndex else { return nil }
    let term = args[args.index(after: flag)]
    return term.isEmpty ? nil : term
  }

  /// UI-TEST RESET HOOK: clears the app's own persisted defaults so every test starts from a
  /// known state. Without it a saved address or theme leaks between tests and a failure
  /// becomes unreproducible — the kind of flakiness that gets a suite disabled rather than
  /// fixed, at which point it protects nothing.
  ///
  /// Scoped deliberately: only keys this app owns (the `dsReel.` prefix), never the whole
  /// domain, and DEBUG-only behind an explicit launch argument.
  static var isUITestResetLaunch: Bool {
    ProcessInfo.processInfo.arguments.contains("-UITestResetState")
  }

  private static func resetPersistedStateForUITests() {
    let d = UserDefaults.standard
    for key in d.dictionaryRepresentation().keys where key.hasPrefix("dsReel.") {
      d.removeObject(forKey: key)
    }
    // The credentials live in the Keychain, not in defaults, so clear them explicitly —
    // otherwise an unconfigured-launch test inherits a real saved password and takes the
    // returning-user path instead of the first-run path it means to exercise.
    deleteFromKeychain(account: Keys.keychainAccount)
    deleteFromKeychain(account: Keys.keychainAccountToken)
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
      api = makeClient(baseURL: api.baseURL, token: resp.token, usesTunnelCookie: api.usesTunnelCookie)
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
    await resolveCandidateSet().candidates
  }

  /// The cascade plus, when baseURL is a QuickConnect ID whose lookup produced nothing, why.
  /// login() needs the reason to tell an unknown ID from a failed lookup (TASK-974); reconnect
  /// only needs the list. Returned rather than stored so a background reconnect resolving at the
  /// same moment cannot overwrite the reason a sign-in is about to show.
  func resolveCandidateSet() async -> (candidates: [QuickConnectResolver.Candidate], quickConnectFailure: QuickConnectError?) {
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
    var quickConnectFailure: QuickConnectError?
    if let qcID = QuickConnectResolver.extractBareID(from: raw) {
      // A failed lookup must not sink the LAN/WAN addresses already in the list: they are tried
      // regardless, and the failure is only reported if nothing else answers.
      var qcCandidates: [QuickConnectResolver.Candidate] = []
      do {
        qcCandidates = try await quickConnectResolve(qcID)
      } catch let failure as QuickConnectError {
        quickConnectFailure = failure
      } catch let urlError as URLError {
        quickConnectFailure = .unreachable(id: qcID, code: urlError.code)
      } catch {
        quickConnectFailure = .unreachable(id: qcID, code: .unknown)
      }
      // Avoid duplicating any LAN IP that QC also resolved
      let existing = Set(candidates.map(\.url.absoluteString))
      for c in qcCandidates where !existing.contains(c.url.absoluteString) {
        candidates.append(c)
      }
    } else if lan.isEmpty && wan.isEmpty {
      // No dual addresses — fall back to baseURL directly
      addDirect(raw)
    }

    return (Self.preferringLastGood(candidates, lastGood: lastGoodAddress), quickConnectFailure)
  }

  /// The one sentence for an address that could not be turned into a URL at all. Only for input
  /// that does not parse; a QuickConnect ID that parses but resolves to nothing has its own
  /// messages (QuickConnectError.userMessage).
  static let invalidServerAddressMessage = "Invalid server address. Please check the URL."

  /// Moves the last known-good address to the front of the cascade.
  ///
  /// Order matters because the cascade tries candidates SEQUENTIALLY with a timeout each,
  /// and QuickConnect lists the NAS's interfaces in an order the client does not control.
  /// This NAS answers on both eth0 (.145) and eth1 (.148), so which one the app used was a
  /// coin flip per launch — not a failure, but not stable either, and it meant a working
  /// address was re-discovered instead of remembered.
  ///
  /// The bigger win is a STALE baseURL. The device log that prompted this had
  /// 192.168.50.146:8090 stored, a host that no longer exists; every launch paid its full
  /// timeout before the cascade found a live address. Starting from the last address that
  /// actually answered skips that.
  ///
  /// STABLE otherwise: a pure move-to-front, so every other candidate keeps its relative
  /// position and the LAN-before-WAN-before-relay ordering the timeouts are tuned around
  /// (2s / 8s / 15s) is preserved. An unmatched or empty hint is a no-op.
  static func preferringLastGood(
    _ candidates: [QuickConnectResolver.Candidate],
    lastGood: String
  ) -> [QuickConnectResolver.Candidate] {
    let hint = lastGood.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hint.isEmpty,
          let idx = candidates.firstIndex(where: { $0.url.absoluteString == hint }),
          idx != 0
    else { return candidates }

    var reordered = candidates
    let winner = reordered.remove(at: idx)
    reordered.insert(winner, at: 0)
    return reordered
  }

  /// Records the address a sign-in (password or pairing code) just succeeded on, so
  /// reconnect() has a real URL to probe and the next launch tries it first rather than
  /// re-discovering it from whatever order QuickConnect happens to return. Relay candidates
  /// are skipped: relay URLs are ephemeral edge addresses.
  private func adoptWinningAddress(_ candidate: QuickConnectResolver.Candidate) {
    guard !candidate.requiresTunnelCookie else { return }
    baseURL = candidate.url.absoluteString
    useHTTPS = candidate.url.scheme == "https"
    if let port = candidate.url.port { defaultPort = port }
    lastGoodAddress = candidate.url.absoluteString
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
      let (candidates, quickConnectFailure) = await resolveCandidateSet()
      guard !candidates.isEmpty else {
        loginError = quickConnectFailure?.userMessage ?? Self.invalidServerAddressMessage
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

      // Remember the LAN address QuickConnect just told us about.
      //
      // The user only ever signs in with a QuickConnect ID (FRD-000 M5: "the user does not
      // choose a mode, does not re-enter an address"). QuickConnect's response already
      // contains the NAS's private interface addresses, so persisting the first one here
      // means the LAN path is available on the NEXT launch without waiting for a
      // resolution round-trip — and it stops Settings → Home being something the user has
      // to discover and fill in by hand.
      //
      // Only when the user has not set one themselves: a hand-entered address is a
      // deliberate choice and must not be overwritten by discovery.
      if lanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         let discoveredLAN = candidates.first(where: {
           !$0.requiresTunnelCookie && Self.isPrivateLANAddress($0.url.absoluteString)
         })?.url.absoluteString {
        lanAddress = discoveredLAN
        dlog.info(.auth, "learned LAN address from QuickConnect: \(discoveredLAN)")
      }

      var lastError: Error?
      // Every candidate's failure, as "host:port — reason". The user-facing error names
      // these; without them "Login failed" is indistinguishable across a stale LAN address,
      // a blocked port, a cert mismatch and a genuine outage.
      var attemptFailures: [String] = []
      // TASK-949: a LAN candidate refused for Local Network access. When nothing answered, that
      // is the one cause the user can fix, so it leads the message.
      var localNetworkRefused = false
      for (index, candidate) in candidates.enumerated() {
        do {
          var tempClient = makeClient(baseURL: candidate.url, token: nil)
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
          api = makeClient(baseURL: candidate.url, token: resp.token, usesTunnelCookie: candidate.requiresTunnelCookie)
          adoptWinningAddress(candidate)
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
          if case .localNetworkDenied? = error as? APIError { localNetworkRefused = true }
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
      } else if localNetworkRefused {
        loginError = LocalNetworkPermission.deniedMessage
      } else if let qcID = QuickConnectResolver.extractBareID(from: raw) {
        let detail = attemptFailures.isEmpty ? "" : "\n\n" + attemptFailures.joined(separator: "\n")
        // The saved LAN/WAN addresses failed AND the QuickConnect lookup failed: the lookup is
        // the actionable half (a typo, or no internet), so lead with it.
        let headline = quickConnectFailure?.userMessage ?? "Couldn't reach \"\(qcID)\" on any known address."
        loginError = headline + detail
      } else if !attemptFailures.isEmpty {
        loginError = attemptFailures.count == 1
          ? "Couldn't reach \(attemptFailures[0])"
          : "Couldn't reach the server. Tried:\n" + attemptFailures.joined(separator: "\n")
      } else {
        loginError = (lastError as? APIError)?.userMessage
          ?? (lastError as? URLError).map { APIError.transport($0).userMessage }
          ?? "Login failed — no server address could be built. Check the address."
      }
    } catch {
      // Do NOT collapse an unrecognised error into a generic string here: a transport
      // failure is now APIError.connection and carries the actual reason, and the fallback
      // must not imply the credentials were the problem.
      loginError = (error as? APIError)?.userMessage
        ?? (error as? URLError).map { APIError.transport($0).userMessage }
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
    // Profiles belong to the account: the next sign-in must re-learn support and must not
    // send this account's profile id.
    profileSupport = .unknown
    profileStore.clearAll()
    serverMaxProfiles = nil
    ageLevels = []
    profileRevision += 1
    needsProfilePicker = false
    pendingPickerTrigger = nil
    enteredBackgroundAt = nil
    // TASK-807: purge on-device content so a shared device leaves no cross-user residue.
    // Downloads are @MainActor (sync); the SQLite cache is an actor (async).
    DownloadManager.shared.clearAll()
    Task { await localStore.clearAll() }
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
    // Cancellation is NOT a connection failure. Navigating away from a view cancels its
    // .task, and the resulting URLError(-999)/CancellationError was being classified as
    // serverUnreachable — so backing out of a library on a slow link flipped the global
    // offline banner on a perfectly healthy connection. Handled once here rather than at
    // each of the ~12 call sites.
    if error is CancellationError { return }
    if let urlErr = error as? URLError, urlErr.code == .cancelled { return }
    if case .connection(.cancelled)? = error as? APIError { return }

    if let apiErr = error as? APIError {
      switch apiErr {
      // isAuthFailure, not `.http(401)`: the backend sends a JSON body with every error,
      // so an expired token arrives as .server("invalid_token", status: 401) and the old
      // `.http(401)` pattern never matched. This branch was dead code — a rejected token
      // left the user on an authenticated-looking UI with empty rails and no way back to
      // the login screen.
      case _ where apiErr.isAuthFailure:
        // Try to recover silently before dumping the user to the login screen.
        //
        // refreshToken() existed but its ONLY caller was a once-per-launch check gated on
        // "expires in under 24h", so any 401 outside that window tore the session down
        // even though the server would have happily issued a new token. attemptSilentReauth
        // does the teardown itself if recovery fails.
        attemptSilentReauth()
      case .network:
        serverUnreachable = true
      case .localNetworkDenied:
        applyLocalNetworkDenied()
      // TASK-953: APIClient wraps EVERY transport failure as .connection(code), so this is
      // the shape a timeout or refused connection actually arrives in. It used to fall to
      // `default`, which made the URLError branch below unreachable from any APIClient call:
      // a view hitting a dead server changed nothing, and the banner only appeared once some
      // other path happened to notice. Same classification as a bare URLError.
      case .connection(let code):
        applyConnectionFailure(Self.connectionFailureKind(code))
      default:
        break  // transient, don't change state
      }
    } else if let urlErr = error as? URLError {
      if case .localNetworkDenied = APIError.transport(urlErr) {
        applyLocalNetworkDenied()
      } else {
        applyConnectionFailure(Self.connectionFailureKind(urlErr.code))
      }
    }
  }

  /// TASK-949: the server is unreachable for a reason the user can fix in Settings.
  private func applyLocalNetworkDenied() {
    serverUnreachable = true
    localNetworkDenied = true
  }

  enum ConnectionFailureKind: Equatable {
    case deviceOffline      // this device has no network at all
    case serverUnreachable  // the network is up; the server didn't answer
  }

  /// The one classification of a transport error code, for both a bare URLError and
  /// APIError.connection. nil = transient or not a connectivity failure; change nothing.
  static func connectionFailureKind(_ code: URLError.Code) -> ConnectionFailureKind? {
    switch code {
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
      return .deviceOffline
    case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut,
         .dnsLookupFailed, .secureConnectionFailed:
      return .serverUnreachable
    default:
      return nil
    }
  }

  private func applyConnectionFailure(_ kind: ConnectionFailureKind?) {
    switch kind {
    case .deviceOffline: isOffline = true
    case .serverUnreachable: serverUnreachable = true
    case nil: break
    }
  }

  /// In-flight silent re-auth, so a burst of concurrent 401s triggers ONE attempt.
  private var silentReauthTask: Task<Void, Never>?

  /// Attempts to recover an expired session without user interaction, and only tears the
  /// session down if that fails.
  ///
  /// Several requests typically fail together when a token expires; without the task
  /// guard each would fire its own refresh, and the losers would clobber the winner's
  /// fresh token. Teardown is deferred until recovery has actually been ruled out, which
  /// is what stops a recoverable expiry from bouncing the user to the login screen.
  private func attemptSilentReauth() {
    guard silentReauthTask == nil else { return }
    // Nothing to refresh with, and no password to fall back on — tear down now.
    guard sessionToken != nil, !isDemoMode else {
      failSession()
      return
    }
    silentReauthTask = Task { @MainActor in
      defer { silentReauthTask = nil }
      await refreshSession()
      // refreshSession() falls back to login() when a password is saved. If either
      // worked we now hold a live token and the user never saw an interruption.
      if sessionToken == nil {
        failSession()
      } else {
        dlog.info(.auth, "silent re-auth recovered the session after a 401")
        loginError = nil
      }
    }
  }

  /// Clears credentials and routes the user to the connect screen with a stated reason.
  private func failSession() {
    Self.deleteFromKeychain(account: Keys.keychainAccountToken)
    sessionToken = nil
    watchlistItems = []  // prevent stale watchlist briefly visible on the login screen
    loginError = "Your session expired. Please sign in again."
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
    let wasDown = isServerUnavailable
    serverUnreachable = false
    isOffline = false
    localNetworkDenied = false
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
      let probe = makeClient(baseURL: candidate.url, token: sessionToken, usesTunnelCookie: candidate.requiresTunnelCookie)
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
        if !candidate.requiresTunnelCookie {
          baseURL = candidate.url.absoluteString
          lastGoodAddress = candidate.url.absoluteString
        }
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
        if !candidate.requiresTunnelCookie {
          baseURL = candidate.url.absoluteString
          lastGoodAddress = candidate.url.absoluteString
        }
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

  /// The first private-network candidate that answers, or nil when none does.
  ///
  /// Deliberately FAST and deliberately quiet. This runs on every foreground, including the
  /// overwhelmingly common case of being away from home where no LAN address can possibly
  /// answer — so a slow probe here would add latency to every single resume. A LAN that is
  /// actually present answers in milliseconds (measured: 13ms), so 1.5s is generous; a LAN
  /// that is absent fails fast on a closed network rather than timing out.
  ///
  /// Candidates come from buildCandidates(), which resolves them out of the QuickConnect
  /// response — so the user signing in with a QuickConnect ID is all that is ever required.
  /// A hand-entered LAN address in Settings still works and is still preferred, but is no
  /// longer necessary.
  private func firstReachableLANCandidate() async -> URL? {
    guard let candidates = try? await buildCandidates() else { return nil }
    for candidate in candidates where !candidate.requiresTunnelCookie {
      guard Self.isPrivateLANAddress(candidate.url.absoluteString) else { continue }
      let probe = makeClient(baseURL: candidate.url, token: sessionToken, usesTunnelCookie: false)
      if (try? await probe.serverVersion(timeout: 1.5)) != nil {
        return candidate.url
      }
    }
    return nil
  }

  /// Returns how the revalidation resolved so the caller knows whether it still needs
  /// to trigger a load itself. On `.switched` this method already posts
  /// networkDidReconnect (which drives homeLoad), so the caller must NOT load again.
  func revalidateConnection() async -> RevalidateResult {
    guard sessionToken != nil, !isDemoMode else { return .failed }
    guard api.baseURL != AppState.fallbackURL else {
      // Never resolved (QC ID) — go straight to the full cascade.
      guard await reconnect() else { return .failed }
      // `.switched` promises networkDidReconnect has been posted, and the foreground caller
      // skips its own refresh on that promise. This branch used to return without posting,
      // so a foreground that finally reached the server never reloaded the library.
      NotificationCenter.default.post(name: .networkDidReconnect, object: nil)
      return .switched
    }
    // PREFER THE LAN WHENEVER IT IS REACHABLE — do not wait for the WAN path to die.
    //
    // This used to return .stillGood the moment the current address answered a 2s probe.
    // The WAN/QuickConnect path answers perfectly well from inside the house — it is just
    // ~100x slower (measured: 21s for an /items call that takes 13ms on the LAN) — so
    // coming home never switched anything. The app stayed on the relay all evening and
    // every sync crawled, which is what made a full re-fetch time out repeatedly.
    //
    // FRD-000 M5 is explicit that this is the product, not a setting: connect on the LAN
    // when home, over WAN when away, "the user does not choose a mode, does not re-enter
    // an address, and ideally does not notice". Requiring a hand-entered LAN address in
    // Settings was the app failing that requirement and charging the user for it.
    //
    // So: if we are NOT on a private address, ask whether a private one is reachable now.
    // buildCandidates() already resolves the LAN IPs out of the QuickConnect response, so
    // signing in with a QuickConnect ID is all the user ever has to do.
    let onLAN = Self.isPrivateLANAddress(api.baseURL.absoluteString)
    if !onLAN, let lanCandidate = await firstReachableLANCandidate() {
      homeLog.info("revalidateConnection: on WAN but the LAN is reachable — switching to \(lanCandidate.absoluteString)")
      dlog.info(.auth, "came home — switching from the remote path to \(lanCandidate.host ?? "?")")
      baseURL = lanCandidate.absoluteString
      lastGoodAddress = lanCandidate.absoluteString
      if let port = lanCandidate.port { defaultPort = port }
      useHTTPS = lanCandidate.scheme == "https"
      api = makeClient(baseURL: lanCandidate, token: sessionToken, usesTunnelCookie: false)
      clearNetworkError()
      NotificationCenter.default.post(name: .networkDidReconnect, object: nil)
      return .switched
    }

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

  /// Retries the candidate cascade in the background until the server answers, the session
  /// ends, or another path reconnects first. On success: clears serverUnreachable and
  /// triggers a fresh homeLoad. Called when homeLoad() can't reach the server on cold start.
  ///
  /// TASK-973: this used to give up after 20 attempts (~10 min) and call softLogout(), which
  /// deleted the Keychain token and sent the user to the login screen although no server had
  /// rejected anything: a NAS that was off, or a QuickConnect outage, cost the user their
  /// sign-in and put their downloads behind a password prompt. Only a server's 401 may end a
  /// session (FR-121), so an unreachable server now leaves the session alone: the cached
  /// library stays up under the "Can't reach your NAS" banner, retries slow to every two
  /// minutes, and every foreground re-runs the cascade at once (revalidateConnection).
  private func startBackgroundReconnectRetry() {
    reconnectRetryTask?.cancel()
    // The banner is the user's only sign the library is stale (FR-130). Cold start used to
    // reach here without it, so the app sat on cached rails looking healthy for ten minutes.
    serverUnreachable = true
    let policy = reconnectRetryPolicy
    reconnectRetryTask = Task { @MainActor in
      // QC resolution can take up to ~24s per attempt, so a flat short delay piled attempts
      // up behind isReconnecting; the ladder backs off before settling on the slow cadence.
      var attempt = 0
      while !Task.isCancelled {
        attempt += 1
        let delay = policy.delay(beforeAttempt: attempt)
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        guard sessionToken != nil else { return }  // logged out — stop retrying
        // Another path already reconnected (a foreground revalidate, a sign-in, a successful
        // sync): each funnels through clearNetworkError(), which drops this flag.
        guard serverUnreachable else {
          homeLog.info("backgroundReconnect: connection restored elsewhere — stopping")
          reconnectRetryTask = nil
          return
        }
        homeLog.info("backgroundReconnect: attempt \(attempt) (waited \(delay))")
        let ok = await reconnect()
        if ok {
          homeLog.info("backgroundReconnect: succeeded on attempt \(attempt) — url=\(self.api.baseURL)")
          // Nil the task handle BEFORE reconnect()'s clearNetworkError() path fires,
          // so the cancel() it used to call doesn't abort this task mid-flight.
          reconnectRetryTask = nil
          serverUnreachable = false
          localNetworkDenied = false
          startHeartbeatTimer()
          await homeLoad()
          return
        }
        if attempt == policy.fastDelays.count {
          homeLog.warning("backgroundReconnect: still unreachable after \(attempt) attempts — keeping the session, retrying every \(policy.slowInterval)")
        }
      }
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
          let urlBefore = self.api.baseURL
          let switched = await self.reconnect()
          let urlAfter = self.api.baseURL
          if switched && urlBefore.absoluteString != urlAfter.absoluteString {
            // COMPARED raw — an exact match is the question being asked — but LOGGED
            // redacted. A base URL can carry a live `_sid=`, since Video Station puts the
            // session in the query string, and this log exists to be screenshotted and sent
            // over chat, which makes a token in it a real leak. safeURL was written for
            // exactly this and had no callers anywhere (TASK-897 #7).
            homeLog.info("networkMonitor: effective address changed \(DiagnosticLog.safeURL(urlBefore), privacy: .public) → \(DiagnosticLog.safeURL(urlAfter), privacy: .public) — posting networkDidReconnect")
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
      let resp = try await api.generatePairingCode(server: pairingServerInfo())
      pairingCode = resp.code
      pairingCodeExpiresInSeconds = resp.expiresInSeconds
    } catch {
      pairingError = (error as? APIError)?.userMessage ?? "Failed to generate pairing code."
    }
  }

  /// This device's way to the server, sent with a pairing code so the device that redeems it
  /// can reach the server from anywhere, not only the network it found it on (TASK-972).
  /// Values are the user's own settings; the server drops anything that is not an address.
  func pairingServerInfo() -> PairingServerInfo {
    let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let lan = lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let wan = wanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    // After a QuickConnect sign-in the ID lives in wanAddress (ServerSetupView.connect) and
    // baseURL holds the winning URL, so look in all three.
    var info = PairingServerInfo(
      quickConnectId: [raw, wan, lan].lazy.compactMap { QuickConnectResolver.extractBareID(from: $0) }.first
    )
    func direct(_ address: String) -> String? {
      address.isEmpty || QuickConnectResolver.extractBareID(from: address) != nil ? nil : address
    }
    info.lanAddress = direct(lan)
    info.wanAddress = direct(wan)
    if let current = direct(raw) {
      if Self.isPrivateLANAddress(current) {
        if info.lanAddress == nil { info.lanAddress = current }
      } else if info.wanAddress == nil {
        info.wanAddress = current
      }
    }
    return info
  }

  /// Shown when a device with no server configured looks for one on its network and finds none.
  static let pairingNoServerFoundMessage =
    "Couldn't find your DS Video server on this network. Make sure this device is on the same Wi-Fi as your server, or sign in with your server address."

  /// Browses the local network for DS Video servers for up to `window`, returning as soon as
  /// one answers (plus a short settle so a second interface can arrive) or access is refused.
  static func browseForPairingServers(window: Duration) async -> (urls: [URL], denied: Bool) {
    let discovery = BonjourDiscovery(noResultsTimeout: window)
    discovery.startScan()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: window)
    var settleUntil: ContinuousClock.Instant?
    while clock.now < deadline, !Task.isCancelled {
      if discovery.status == .denied { break }
      if !discovery.servers.isEmpty {
        if settleUntil == nil { settleUntil = clock.now.advanced(by: .milliseconds(300)) }
        if let settle = settleUntil, clock.now >= settle { break }
      }
      try? await Task.sleep(for: .milliseconds(150))
    }
    // stopScan() clears `servers`: read them first.
    let urls = discovery.servers.compactMap { URL(string: $0.baseURL) }
    let denied = discovery.status == .denied
    discovery.stopScan()
    return (urls, denied)
  }

  /// Redeems a pairing code (FR-117). Works on a device that has never connected: with no
  /// address configured it finds the server on the local network, and on success it keeps
  /// the address that answered plus the connection details the generating device sent, so
  /// it can reach the server again from anywhere (TASK-972).
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
    let nothingConfigured = raw.isEmpty
      && lanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && wanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    // Configured addresses: the same LAN → WAN → QuickConnect cascade sign-in uses (TASK-974
    // reasons included). Discovery only for a device with nothing configured, so a typo'd
    // address fails as a typo instead of silently pairing with whatever is on the network.
    let candidates: [QuickConnectResolver.Candidate]
    let quickConnectFailure: QuickConnectError?
    var discoveryDenied = false
    if nothingConfigured {
      let found = await discoverPairingServers()
      candidates = found.urls.map { .init(url: $0, requiresTunnelCookie: false) }
      quickConnectFailure = nil
      discoveryDenied = found.denied
      dlog.info(.auth, "pairing: no server configured — discovery found \(candidates.count)\(found.denied ? " (local network denied)" : "")")
    } else {
      (candidates, quickConnectFailure) = await resolveCandidateSet()
    }

    guard !candidates.isEmpty else {
      if nothingConfigured {
        loginError = discoveryDenied ? LocalNetworkPermission.deniedMessage : Self.pairingNoServerFoundMessage
      } else if let qcID = QuickConnectResolver.extractBareID(from: raw) {
        loginError = quickConnectFailure?.userMessage ?? QuickConnectError.noAddress(id: qcID).userMessage
      } else {
        loginError = Self.invalidServerAddressMessage
      }
      return
    }

    var lastError: Error?
    var localNetworkRefused = false
    for candidate in candidates {
      let timeout: TimeInterval = candidate.requiresTunnelCookie ? 15
        : Self.isPrivateLANAddress(candidate.url.absoluteString) ? 4 : 8
      do {
        var client = makeClient(baseURL: candidate.url, token: nil)
        client.usesTunnelCookie = candidate.requiresTunnelCookie
        let resp = try await client.exchangePairingCode(code: code, timeoutInterval: timeout)
        sessionToken = resp.token
        clearNetworkError()
        api = makeClient(baseURL: candidate.url, token: resp.token, usesTunnelCookie: candidate.requiresTunnelCookie)
        adoptWinningAddress(candidate)
        adoptPairedServerInfo(resp.server, winner: candidate)
        startHeartbeatTimer()
        dlog.info(.auth, "pairing OK via \(candidate.url.host ?? "?") token=\(DiagnosticLog.redact(resp.token))")
        return
      } catch {
        dlog.warn(.auth, "pairing via \(candidate.url.host ?? "?") failed — \((error as? APIError)?.userMessage ?? error.localizedDescription)")
        if case .localNetworkDenied? = error as? APIError { localNetworkRefused = true }
        lastError = error
        // The server answered and refused the code: every other address is the same server,
        // would refuse it too, and would count one more wrong code against it.
        if let apiErr = error as? APIError, apiErr.serverReached { break }
      }
    }
    dlog.error(.auth, "pairing FAILED — \(candidates.count) candidate(s) tried")
    let serverAnswered = (lastError as? APIError)?.serverReached ?? false
    loginError = !serverAnswered && localNetworkRefused
      ? LocalNetworkPermission.deniedMessage
      : Self.pairingErrorMessage(lastError)
  }

  /// Keeps the generating device's connection details so this one can reach the server once
  /// it leaves the network it paired on. Never overwrites an address the user set (the same
  /// rule login() applies to the LAN address QuickConnect reports).
  private func adoptPairedServerInfo(_ info: PairingServerInfo?, winner: QuickConnectResolver.Candidate) {
    if lanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if let lan = info?.lanAddress, !lan.isEmpty {
        lanAddress = lan
      } else if !winner.requiresTunnelCookie, Self.isPrivateLANAddress(winner.url.absoluteString) {
        lanAddress = winner.url.absoluteString
      }
    }
    if wanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let wan = [info?.wanAddress, info?.quickConnectId].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
      wanAddress = wan
    }
  }

  // MARK: - Home Data

  private let homeLog = Logger(subsystem: "com.dsm.dsvideo", category: "HomeState")

  // Persistent across tab switches — populated once, never cleared unless logout/forceRefresh
  var homeLibraries: [Library] = []
  /// Bumped on homeForceRefresh so TVLibraryRail's .task(id:) re-triggers a fresh fetch.
  var libraryRailsVersion: UUID = UUID()
  /// Both rails write the Top Shelf snapshot, because the shelf prefers Continue Watching
  /// and falls back to Just Added. Hooking only one meant the shelf went stale exactly when
  /// it mattered — finishing an episode changes Continue Watching, and without this didSet
  /// the shelf kept offering the thing you just watched. What the shelf may show from these
  /// rails (e.g. never Continue Watching on an account with a restricted profile) is
  /// TopShelfPolicy's decision, not the didSet's.
  var homeContinueWatching: [ItemSummary] = [] {
    didSet { writeTopShelfSnapshot() }
  }
  var homeJustAdded: [ItemSummary] = [] {
    didSet { writeTopShelfSnapshot() }
  }
  var homeRecentlyWatched: [ItemSummary] = []

  /// Titles sharing a genre with something watched recently.
  ///
  /// Replaces Recently Watched on the home screen. That rail required an item to be past
  /// 95% complete — the `isFinished` rule — so anything stopped partway went to Continue
  /// Watching and could never appear in it. On a real library that left it showing two
  /// finished shows while an evening of half-watched films sat in the other rail: the two
  /// rails were competing for the same data, and one of them always lost.
  ///
  /// Suggested has no such overlap. It reads the genres of what was watched most recently
  /// and offers OTHER things in those genres, so it complements Continue Watching instead
  /// of duplicating it, and it is useful on a night when nothing is half-finished.
  ///
  /// Populated separately from computeHomeRails because it needs the network: ItemSummary
  /// carries no genres (only ItemDetail does), so the genres of the seed item and the
  /// matching titles both come from the server.
  var homeSuggested: [ItemSummary] = []
  /// The genre the current suggestions were built from, for the rail's subtitle — "Because
  /// you watched" with no reason is just a shrug.
  var homeSuggestedGenre: String = ""

  // Loading state flags
  var homeIsLoading: Bool = false
  var homeIsCacheDecoding: Bool = false
  var homeIsBackgroundRefreshing: Bool = false
  var homeError: String?

  // Background fetch task handle — cancelled on forceRefresh/logout
  private var homeBackgroundFetchTask: Task<Void, Never>?
  /// Identifies the sync that owns homeBackgroundFetchTask, so a finishing sync clears
  /// only its own handle — never one a later start put there.
  private var homeBackgroundSyncID = UUID()

  /// Starts a background sync unless one is genuinely still running.
  ///
  /// The handle is cleared when the sync finishes. A finished Task is never `isCancelled`,
  /// so a handle left behind read as "a sync is already running" for the rest of the
  /// session: after the launch sync, every heartbeat that saw a change skipped it, and
  /// progress from other devices never arrived until a relaunch.
  private func startBackgroundSyncIfIdle(_ work: @escaping @MainActor () async -> Void) -> Bool {
    if let existing = homeBackgroundFetchTask, !existing.isCancelled { return false }
    let id = UUID()
    homeBackgroundSyncID = id
    homeBackgroundFetchTask = Task {
      await work()
      if self.homeBackgroundSyncID == id { self.homeBackgroundFetchTask = nil }
    }
    return true
  }
  /// Bumped by clearHomeState() and by a profile change. Every async home load captures it
  /// before its first await and drops its result if it changed meanwhile (FR-261).
  private(set) var homeStateGeneration: UInt64 = 0

  /// Whether a home result that started at `generation` may still be applied. False once the
  /// state was cleared or the profile changed while it was in flight: its data belongs to a
  /// previous session or profile and must never render (FR-261, AC-002-42).
  func homeResultIsCurrent(_ generation: UInt64, _ site: StaticString) -> Bool {
    guard generation == homeStateGeneration else {
      homeLog.info("\(site): stale result dropped (state cleared or profile switched mid-flight)")
      return false
    }
    return true
  }

  func clearHomeState() {
    // Cancelling homeBackgroundFetchTask is not enough on its own — recomputeHomeRails runs
    // in a detached task that is never stored, so it is fenced by the generation instead.
    homeBackgroundFetchTask?.cancel()
    homeBackgroundFetchTask = nil
    discardProfileScopedHomeState()
    homeLibraries = []
    homeIsLoading = false
    homeIsCacheDecoding = false
    homeIsBackgroundRefreshing = false
    homeError = nil
  }

  /// Fences every in-flight home load and empties everything that belongs to one profile:
  /// rails, Suggested, watchlist and the Top Shelf snapshot. Shared by sign-out
  /// (clearHomeState) and a profile change, so the two can never drift apart.
  private func discardProfileScopedHomeState() {
    homeStateGeneration &+= 1
    homeContinueWatching = []
    homeJustAdded = []
    homeRecentlyWatched = []
    homeSuggested = []
    homeSuggestedGenre = ""
    watchlistItems = []
    watchlistLoadFailed = false
    homeCollections = []
    homeCollectionsLoad = .notLoaded
    collectionsInFlightGeneration = nil
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
    guard let fileURL = topShelfSnapshotURL else { return }
    // Nothing on disk means the shelf is already empty: no change to announce (TASK-992).
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      try FileManager.default.removeItem(at: fileURL)
      TopShelfRefresh.notify()
    } catch {
      homeLog.error("deleteTopShelfSnapshot: could not remove the shelf file — \(error.localizedDescription)")
    }
  }

  /// Where the Top Shelf snapshot lives: topshelf.json in the app group the extension reads.
  /// A stored property only so tests can point the writer at a file they own.
  @ObservationIgnored var topShelfSnapshotURL: URL? = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: ActiveProfileStore.appGroupID
  )?.appendingPathComponent("topshelf.json")


  var homeAllRailsEmpty: Bool {
    homeContinueWatching.isEmpty && homeJustAdded.isEmpty && homeRecentlyWatched.isEmpty
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
        // Suggested depends on the rails above (it seeds from what was watched most
        // recently) and needs the network, so it runs after them and never blocks them.
        Task { await self.loadSuggestedRail() }
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


  /// Builds the Suggested rail from the genres of what was watched most recently.
  ///
  /// Network-backed, unlike the other rails: ItemSummary carries no genres, so both the
  /// seed's genres and the candidate list come from the server.
  ///
  /// Best-effort by design. Every failure path leaves the rail EMPTY rather than surfacing
  /// an error — a suggestion that could not be computed is not a problem the user needs to
  /// act on, and the home screen must not grow an error state for a nicety.
  /// Applies a computed rail set and refreshes Suggested from it.
  ///
  /// Four code paths assign the three rails — cold start, first-page-of-sync, post-sync, and
  /// the detached recompute — and Suggested has to follow all of them. It was wired into the
  /// recompute alone, so on a cold start (the common launch) the rail simply never appeared
  /// until something else forced a full recompute. Funnelling every site through here is
  /// what stops the next path from silently skipping it.
  ///
  /// Suggested is fired and not awaited: it is a network call, and the three local rails
  /// must render immediately rather than waiting on it.
  @discardableResult
  func applyRails(_ rails: HomeRails, startedAt generation: UInt64) -> Bool {
    guard homeResultIsCurrent(generation, "applyRails") else { return false }
    homeContinueWatching = rails.continueWatching
    // The local value is a FALLBACK, shown immediately so the rail is never blank, then
    // replaced by the server's answer below. See loadJustAddedRail.
    homeJustAdded = rails.justAdded
    homeRecentlyWatched = rails.recentlyWatched
    Task { await loadJustAddedRail() }
    Task { await loadSuggestedRail() }
    Task { await loadCollections() }
    return true
  }

  // MARK: - Collections (FRD-002 §9)

  /// The active profile's collections exactly as GET /collections returned them. The server
  /// decides which collections a profile is offered and hides empty ones (FR-273, FR-274), so
  /// nothing here filters, reorders or re-derives tiers.
  var homeCollections: [MediaCollection] = []
  var homeCollectionsLoad: CollectionsLoadState = .notLoaded
  /// The generation a collections request is in flight for, so the several applyRails calls a
  /// sync makes do not stack duplicate requests. A new generation always gets its own load.
  private var collectionsInFlightGeneration: UInt64?

  /// What every browse surface shows for collections right now. Offline (or demo) hides them:
  /// they are never recomputed from the local catalog.
  var collectionsBrowse: CollectionsBrowse {
    CollectionsBrowse.decide(
      collections: homeCollections,
      load: homeCollectionsLoad,
      isKids: activeProfile?.kids ?? false,
      isOffline: isDemoMode || isServerUnavailable)
  }

  func loadCollections() async {
    guard !isDemoMode, sessionToken != nil, !isServerUnavailable else { return }
    let generation = homeStateGeneration
    guard collectionsInFlightGeneration != generation else { return }
    collectionsInFlightGeneration = generation
    let apiSnapshot = api
    let result: Result<[MediaCollection], any Error>
    do {
      result = .success(try await apiSnapshot.collections().collections)
    } catch {
      result = .failure(error)
    }
    if collectionsInFlightGeneration == generation { collectionsInFlightGeneration = nil }
    applyCollections(result, startedAt: generation)
  }

  /// Applies a GET /collections answer that started at `generation`. Dropped when the profile
  /// changed or the state was cleared meanwhile (FR-261). A failure with nothing on screen is
  /// recorded so a kids' profile can say "couldn't load", distinct from "none yet" (FR-276);
  /// a failed refresh over collections already shown keeps them.
  @discardableResult
  func applyCollections(_ result: Result<[MediaCollection], any Error>,
                        startedAt generation: UInt64) -> Bool {
    guard homeResultIsCurrent(generation, "collections") else { return false }
    switch result {
    case .success(let list):
      homeCollections = list
      homeCollectionsLoad = .loaded
      homeLog.info("collections: \(list.count) from the server")
    case .failure(let error):
      if error is CancellationError { return false }
      let message = (error as? APIError)?.userMessage ?? error.localizedDescription
      homeLog.warning("collections: request failed — \(message)")
      if homeCollections.isEmpty { homeCollectionsLoad = .failed }
    }
    return true
  }

  /// Replaces Just Added with the server's own answer.
  ///
  /// The rail used to be derived entirely from the local SQLite mirror — ORDER BY added_at
  /// over whatever had been synced. That is the client guessing about a library it does not
  /// hold, and it fails silently in the one way that matters: when the sync stalls, the rail
  /// keeps rendering confidently stale content with nothing anywhere reporting a problem.
  /// A phone showed the same four TV shows for days while the server held a dozen newer
  /// films, and four separate client-side fixes chased the symptom.
  ///
  /// The server has first-hand knowledge of its library, precomputes this on a timer, and
  /// is now the authority. The local query survives only as the offline fallback: if the
  /// request fails, whatever applyRails already set stays on screen rather than the rail
  /// going blank.
  ///
  /// TASK-1020: a request that SUCCEEDS is the answer, even when it is empty. An empty rail is
  /// the server's verdict (a profile ceiling that hides every new title, a library with nothing
  /// added), and showing the local list instead would put titles on screen that the server just
  /// said this profile may not see. Only a failed request keeps the local fallback.
  func loadJustAddedRail() async {
    guard !isDemoMode, sessionToken != nil else { return }
    let apiSnapshot = api
    let generation = homeStateGeneration
    do {
      let resp = try await apiSnapshot.justAdded(limit: 16)
      guard homeResultIsCurrent(generation, "justAdded") else { return }
      homeJustAdded = resp.items
      homeLog.info("justAdded: \(resp.items.count) item(s) from the server")
    } catch {
      // Offline, or an older server with no /just-added. The local fallback is already on
      // screen, so there is nothing to surface to the user.
      homeLog.warning("justAdded: server request failed, keeping local — \(error.localizedDescription)")
    }
  }

  func loadSuggestedRail() async {
    let apiSnapshot = api
    let generation = homeStateGeneration
    let libraryID = homeLibraries.first(where: { $0.kind != "tv" })?.id ?? homeLibraries.first?.id

    // Preferred path: one request, seeded server-side from the progress table. That matters
    // beyond the round-trip saving — a client whose sync has stalled would otherwise seed
    // from its own stale rails and suggest against something watched weeks ago.
    do {
      let resp = try await apiSnapshot.suggested(libraryId: libraryID, limit: 16)
      guard homeResultIsCurrent(generation, "suggested") else { return }
      if !resp.items.isEmpty {
        homeSuggested = resp.items
        homeSuggestedGenre = resp.genre
        homeLog.info("suggested: \(resp.items.count) item(s) for genre \(resp.genre) (server)")
        return
      }
      // An empty answer is legitimate — no progress yet on a fresh install. Don't fall
      // through to the legacy path, which would only reach the same conclusion slowly.
      homeSuggested = []
      homeSuggestedGenre = ""
      return
    } catch let err as APIError {
      guard homeResultIsCurrent(generation, "suggested") else { return }
      // Only a MISSING endpoint justifies the fallback. Any other failure (auth, timeout,
      // a real server error) should leave the rail empty rather than quietly doing twice
      // the work against a server that is already struggling.
      guard case .http(404) = err else {
        homeLog.warning("suggested: server request failed — \(err.userMessage)")
        homeSuggested = []
        homeSuggestedGenre = ""
        return
      }
      homeLog.info("suggested: server has no /suggested endpoint — using the client fallback")
    } catch {
      guard homeResultIsCurrent(generation, "suggested") else { return }
      homeLog.warning("suggested: server request failed — \(error.localizedDescription)")
      homeSuggested = []
      homeSuggestedGenre = ""
      return
    }

    // Fallback for an older server: derive it client-side in two requests. Seeds from the
    // local rails, which is why it is second choice — those are only as fresh as this
    // device's sync.
    let seedPool = homeContinueWatching + homeRecentlyWatched
    guard let seed = seedPool.first else {
      homeSuggested = []
      homeSuggestedGenre = ""
      return
    }
    do {
      let detail = try await apiSnapshot.itemDetail(id: seed.id)
      guard let genre = Self.suggestionGenre(from: detail.genres) else {
        homeSuggested = []
        homeSuggestedGenre = ""
        return
      }
      let resp = try await apiSnapshot.items(
        libraryId: seed.libraryId ?? libraryID ?? "lib_movies",
        limit: 60, genres: [genre], genreMode: .any)
      guard homeResultIsCurrent(generation, "suggested fallback") else { return }
      let exclude = Set(seedPool.map(\.id) + homeJustAdded.map(\.id))
      let picks = resp.items.filter { !exclude.contains($0.id) }.shuffled().prefix(16)
      homeSuggested = Array(picks)
      homeSuggestedGenre = genre
      homeLog.info("suggested: \(picks.count) item(s) for genre \(genre) (client fallback)")
    } catch {
      guard homeResultIsCurrent(generation, "suggested fallback") else { return }
      homeLog.warning("suggested: could not build rail — \(error.localizedDescription)")
      homeSuggested = []
      homeSuggestedGenre = ""
    }
  }

  /// Picks the most useful genre to recommend from.
  ///
  /// Skips the broadest categories when anything more specific is available: a library's
  /// Drama bucket is typically a third of it, so "Because you watched … Drama" is close to
  /// a random shuffle. Falls back to whatever exists rather than giving up, since a broad
  /// suggestion still beats an empty rail.
  nonisolated static func suggestionGenre(from genres: [String]?) -> String? {
    guard let genres, !genres.isEmpty else { return nil }
    let tooBroad: Set<String> = ["Drama", "Comedy", "Action", "Thriller", "Adventure"]
    return genres.first(where: { !tooBroad.contains($0) }) ?? genres.first
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
      // FR-021: a show is one entry, the first (newest, the caller sorts first) episode seen.
      // The show key is ItemSummary.showDedupKey, the same one LocalStore.fetchItems uses.
      var seen = Set<String>()
      return items.filter { item in
        let key = item.showDedupKey.map { "show|" + $0 } ?? (item.title.lowercased() + "|\(item.type)")
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
          // The "genuinely started" test, from the shared classifier.
          //
          // This was a raw `>= 0.05` written out one line below the isFinished call above —
          // the same rule in two forms, in adjacent lines. startedThreshold's own doc
          // comment records what that costs: it was 0.05 here and still 0.02 in the show
          // page, so for a 45-minute episode watched between 54s and 135s the show page
          // offered to resume an episode this rail said had never been started.
          return PlaybackProgress.watchState(
            positionSeconds: p.positionSeconds, durationSeconds: p.durationSeconds) != .unwatched
        }
        .sorted { parseDate($0.progress?.updatedAt ?? $0.addedAt) > parseDate($1.progress?.updatedAt ?? $1.addedAt) }
    ).prefix(16))

    let recentlyWatched = Array(deduplicated(
      allItems
        .filter { item in
          guard let p = item.progress, p.durationSeconds > 0 else { return false }
          return PlaybackProgress.isFinished(
            positionSeconds: p.positionSeconds, durationSeconds: p.durationSeconds)
        }
        .sorted { parseDate($0.progress?.updatedAt ?? $0.addedAt) > parseDate($1.progress?.updatedAt ?? $1.addedAt) }
    ).prefix(16))

    // The same function LocalStore.queryJustAdded uses: no progress filter (FR-088, TASK-1019).
    let justAdded = ItemSummary.justAddedRail(from: allItems)

    return (continueWatching, justAdded, recentlyWatched)
  }

  // MARK: - Home Load

  func homeLoad() async {
    let callID = Int.random(in: 1000...9999)
    // FR-260: while the picker is up, no profile is chosen yet, so there is nothing to load.
    // Loading here would render the remembered profile's rails behind the picker.
    guard !needsProfilePicker else {
      homeLog.info("homeLoad[\(callID)]: held — profile picker is showing")
      return
    }
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
      // The rails are reused, but a collections load that failed (or never ran) retries.
      if homeCollectionsLoad != .loaded { Task { await self.loadCollections() } }
      return
    }

    // Cold start — load SQLite first (fast), then sync from network
    homeIsCacheDecoding = true
    defer { homeIsCacheDecoding = false }
    let generation = homeStateGeneration
    // Ensure setup has completed before any store access (TASK-420).
    let localStore = self.localStore
    await localStore.ensureReady()
    let hasLocal = await Task.detached(priority: .userInitiated) {
      await localStore.hasItems()
    }.value

    if hasLocal {
      homeLog.info("homeLoad[\(callID)]: PATH=cold-start — local DB has data, loading rails")
      dlog.info(.home, "homeLoad: cold start from local DB")
      let rails = await Task.detached(priority: .userInitiated) {
        await localStore.queryRails()
      }.value
      applyRails(rails, startedAt: generation)
      homeIsCacheDecoding = false
      // Skip background network sync when offline — cached content is already shown
      // and network calls will fail anyway (TASK-291).
      guard !isServerUnavailable else {
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
      // Same rule as the heartbeat: do not cancel a sync that is still running. A relaunch
      // or a re-entry into homeLoad while a long WAN resync is mid-flight would otherwise
      // restart it from seq 0 and it would never reach the end.
      if startBackgroundSyncIfIdle({ await self.runDeltaSyncWithBackgroundTask() }) {
        homeLog.info("homeLoad[\(callID)]: starting background delta sync")
      } else {
        homeLog.info("homeLoad[\(callID)]: a background sync is already running — leaving it alone")
      }
    } else {
      homeLog.info("homeLoad[\(callID)]: PATH=cold-start — no local data, full sync required")
      homeIsCacheDecoding = false
      homeError = nil  // clear stale error before each retry attempt
      // When offline with no local data, skip the network attempt and surface an
      // appropriate error — avoids a loud failure on every network call (TASK-291).
      guard !isServerUnavailable else {
        homeLog.info("homeLoad[\(callID)]: offline and no local data — skipping sync")
        homeError = isOffline ? "No internet connection."
          : localNetworkDenied ? LocalNetworkPermission.deniedMessage
          : "Can't reach your server."
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
    // DO NOT clearAll() here. This is what broke Just Added.
    //
    // clearAll() deletes every item AND zeroes the cursor, and only THEN tries to
    // re-download the whole library. On a slow link that re-download is likely to fail —
    // this phone is on the WAN path, where a small /items call measured 21 SECONDS against
    // 13ms on the LAN — and the device is then left with ZERO items and a cursor at 0,
    // strictly worse than before the refresh and with no way out: every later cycle
    // restarts from 0 and fails the same way.
    //
    // It was also invisible. clearAll() logs nothing, and this function logs only to
    // homeLog (OSLog), not dlog — so on the device's diagnostic file the cursor appeared
    // to drop to 0 for no reason, which sent four separate fixes after the wrong cause.
    //
    // Resetting the cursor alone gets the same full re-fetch, because upsertItems is
    // idempotent by id: every row is rewritten as it arrives. The difference is that the
    // user keeps a working library the entire time the re-fetch is running, and keeps it
    // even if the re-fetch never finishes.
    homeLog.info("homeForceRefresh: resetting sync cursor, running full sync")
    dlog.info(.library, "force refresh — re-fetching the library from seq 0")
    homeBackgroundFetchTask?.cancel()
    homeBackgroundFetchTask = nil
    homeIsBackgroundRefreshing = false
    await localStore.setItemSeq(0)
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
    guard !isDemoMode, !isServerUnavailable else { return }
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
    // FR-261: a pass that started under one profile never writes another profile's screen.
    let generation = homeStateGeneration
    homeLog.info("runDeltaSync: background=\(background)")

    // Learn profile support BEFORE any progress traffic, so a sync that starts ahead of the
    // list load cannot send header-less progress (FR-221 would file it under a kid).
    if profileSupport == .unknown {
      await refreshProfiles()
    }
    // One profile for the whole pass, even if the user switches mid-sync (FR-233).
    let scope = await localStore.activeScope
    let progressAllowed = ProfileGate.progressSyncAllowed(scope: scope, support: profileSupport)
    let progressAPI = apiSnapshot.pinned(to: scope.headerValue)

    // Step 0: push before pulling. Any progress recorded while the NAS was unreachable is
    // still flagged pending; it MUST go up before we download the server's copy, otherwise
    // the server's older value comes back down and upsertProgress's last-writer-wins
    // comparison overwrites the newer local position — silently losing the user's place.
    await flushPendingProgress()

    do {
      // Step 1: Get server seq numbers and our local cursors
      let status = try await apiSnapshot.syncStatus()
      var cursors = await localStore.getSyncCursors(profileID: scope.id)
      homeLog.info("runDeltaSync: server itemSeq=\(status.itemSeq) local=\(cursors.itemSeq) | server progressSeq=\(status.progressSeq) local=\(cursors.progressSeq)")

      // A local cursor AHEAD of the server's is impossible, and it is a permanent stall.
      //
      // Both delta gates below are `status.seq > cursors.seq`. When a local cursor somehow
      // exceeds the server's, that test is false forever: the app stops fetching item
      // deltas entirely and new shows and episodes never appear again, while the app keeps
      // logging healthy syncs. Caught on a real device, where the iOS cursor read 348155
      // against a server at 13789 and the server advanced 115 changes that were never
      // fetched. Nothing surfaced — progress kept syncing on its own cursor, so the app
      // looked alive.
      //
      // The cause is a server-side sequence RESET (a rebuilt or restored database restarts
      // the counter) rather than anything the client did, so the client cannot prevent it —
      // it can only refuse to be wedged by it. Clamping means the next sync re-fetches from
      // the clamped point, which is correct: if the server's sequence space was rebuilt,
      // everything in it is new to us.
      if SyncCursorClamp.isAhead(local: cursors, server: status) {
        homeLog.warning("""
          runDeltaSync: local cursor AHEAD of server           (item \(cursors.itemSeq) > \(status.itemSeq), progress \(cursors.progressSeq) > \(status.progressSeq))           — server sequence was reset; clamping so deltas resume
          """)
        dlog.warn(.library, "sync cursor ahead of server — resetting and re-fetching")
        // RESET TO ZERO, not to the server's current seq.
        //
        // Clamping to status.itemSeq looks like the conservative choice and is wrong: the
        // gate below is `status.itemSeq > cursors.itemSeq`, so a cursor set equal to the
        // server's makes it FALSE, and nothing would be fetched until the server's next
        // change. The library would stay exactly as stale as it was, having logged a fix.
        //
        // Zero is correct because a cursor ahead of the server means the server's sequence
        // space was REBUILT. Nothing local can be assumed to correspond to it, so the whole
        // stream is genuinely new to us. This costs one full item re-fetch, once, which is
        // the same work a fresh install does.
        if cursors.itemSeq > status.itemSeq {
          await localStore.setItemSeq(0)
        }
        if cursors.progressSeq > status.progressSeq {
          await localStore.setProgressSeq(0, profileID: scope.id)
        }
        cursors = await localStore.getSyncCursors(profileID: scope.id)
      }

      // Step 2: Fetch libraries (always fast, small payload)
      let libs = try await apiSnapshot.libraries().libraries
      if homeResultIsCurrent(generation, "runDeltaSync libraries") { homeLibraries = libs }
      // Library names and counts. If a library the user expects is absent here, the problem
      // is server-side indexing, not the client — which saves a round of client debugging.
      if libs.isEmpty {
        dlog.warn(.library, "server returned ZERO libraries")
      } else {
        dlog.info(.library, "libraries: \(libs.map(\.title).joined(separator: ", "))")
      }
      dlog.info(.library, "sync: server itemSeq=\(status.itemSeq) local=\(cursors.itemSeq) progressSeq=\(status.progressSeq)/\(cursors.progressSeq)")

      // Step 3: Fetch item deltas if server has new items
      let localCount = await localStore.totalItemCount()

      // A cursor that agrees with the server but a LIBRARY that does not.
      //
      // The clamp above catches a cursor that ran ahead. It does not catch every way a sync
      // can wedge, and the symptom is identical and invisible in all of them: rails keep
      // rendering, the log keeps saying "done", and the library silently stops growing.
      // Reported from a real phone — new movies were on the server and in the delta feed,
      // and Just Added kept showing the same TV shows.
      //
      // So check the thing the user actually notices rather than only the bookkeeping: if
      // the server has items newer than anything stored locally, the delta stream has not
      // been delivering whatever the cursors claim, and a resync from zero is warranted.
      // Cheap to be wrong — one re-fetch — and the alternative is a library that never
      // recovers without a reinstall.
      var forceResync = false
      if localCount > 0 {
        // filter=justAdded, NOT a bare limit:1.
        //
        // /items defaults to ORDER BY title, so `limit: 1` returns the alphabetical head —
        // on this library "Wuthering Heights", added in April. The first version of this
        // check compared that five-month-old timestamp against local, concluded the library
        // was current, and could never fire. filter=justAdded is ORDER BY added_at DESC.
        //
        // Across EVERY library, not just movies: a TV-only addition is exactly as stale and
        // would have been missed by checking the movie library alone.
        var serverNewest = ""
        for lib in libs {
          if let newest = try? await apiSnapshot.items(
            libraryId: lib.id, limit: 1, filter: "justAdded").items.first?.addedAt,
             newest > serverNewest {
            serverNewest = newest
          }
        }
        let localNewest = await localStore.newestAddedAt()
        if !serverNewest.isEmpty, !localNewest.isEmpty, serverNewest > localNewest {
          homeLog.warning("""
            runDeltaSync: server has items newer than local             (server \(serverNewest) > local \(localNewest)) while cursors agree —             the delta stream is not delivering; forcing a resync
            """)
          dlog.warn(.library, "library is behind the server — forcing a full resync")
          await localStore.setItemSeq(0)
          // The pass's own profile, not the active one: a switch mid-pass must not hand
          // this pass another profile's progress cursor.
          cursors = await localStore.getSyncCursors(profileID: scope.id)
          forceResync = true
        }
      }

      if status.itemSeq > cursors.itemSeq || localCount == 0 || forceResync {
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
        // A page failure must not discard the pages that already landed.
        //
        // This was a bare `try`, so a timeout on ANY page threw straight past the
        // setItemSeq below to the outer catch — leaving the cursor exactly where it was
        // when the loop started. Combined with a reset to 0 (the staleness path, or a
        // clearAll), that stranded the device at seq 0 with an empty items table: every
        // launch re-reset, re-fetched, timed out, and got nowhere. The user's log shows
        // that loop — "local=0" at 09:07:17, 09:14:28, 09:14:31, 09:21:55, each followed
        // by a timeout, never once reaching the end.
        //
        // It is not a rare edge either: this phone is on the WAN path, where /items
        // measured 21 SECONDS against 13ms on the LAN, and syncItems asks for 500 items
        // with a 30s budget. Timing out mid-sync is the NORMAL case there, so the sync has
        // to be resumable rather than all-or-nothing.
        //
        // Catch it, keep every page already upserted, and let the cursor advance below to
        // whatever was actually consumed. The next cycle resumes from there instead of
        // starting over.
        var fetchError: Error? = nil
        // Resuming from a known cursor means few pages, so ask for large ones. Starting
        // from zero means ~11 pages at 500, every one of them a timeout risk on WAN.
        let pageLimit = since == 0 ? 200 : 500
        repeat {
          let page: SyncItemsResponse
          do {
            // Smaller pages when starting from zero. A full re-fetch is the slowest case
            // and the one most likely to be interrupted, so each page should be cheap
            // enough to land over a slow link — a page that times out costs the whole
            // page, and at 500 items that is most of a minute of work discarded.
            page = try await apiSnapshot.syncItems(since: since, limit: pageLimit, afterRowid: afterRowid)
          } catch {
            homeLog.warning("""
              runDeltaSync: page \(pageCount + 1) failed at seq=\(since) — \(error.localizedDescription);               keeping the \(pageCount) page(s) already fetched and resuming next cycle
              """)
            fetchError = error
            break
          }
          if !page.items.isEmpty {
            await localStore.upsertItems(page.items)
            since = page.nextSeq
            afterRowid = page.hasMore ? page.nextAfterRowid : nil
            pageCount += 1

            // CHECKPOINT EVERY PAGE. The items are already durable — upsertItems commits
            // its own transaction — so the watermark recording them must be durable too.
            //
            // The cursor used to be written ONCE, after the loop. Every page's rows landed
            // on disk while the bookkeeping that says so did not, so any interruption threw
            // away the record of work that had actually completed: a throw, a cancellation,
            // or iOS suspending the app when its ~30s background grant expired. On an
            // 11-page fetch at 21s per page over WAN, that is a four-minute window in which
            // every termination mode loses everything.
            //
            // Checkpointing here makes the sync resumable under all of them. Deliberately
            // NOT capped at status.itemSeq: `since` is the server's own nextSeq, which is
            // exactly what the next request should ask from.
            await localStore.setItemSeq(min(since, status.itemSeq))

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
              let rails = await localStore.queryRails()
              applyRails(rails, startedAt: generation)
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
        // Deletions are swept only when the item fetch finished. Skipping them is safe now
        // that the cursor is checkpointed per page: the next cycle re-requests deletions
        // from the LAST CHECKPOINT, so nothing in the unswept range is lost — the earlier
        // version of this advanced the cursor past deletions it had deliberately skipped,
        // which would have made those deletions unreachable forever.
        var deletionSucceeded = false
        if fetchError != nil {
          homeLog.info("runDeltaSync: skipping deletions — the item fetch did not finish; they sweep on the next cycle from the checkpointed cursor")
        } else {
          do {
            let deleted = try await apiSnapshot.syncDeleted(since: cursors.itemSeq)
            if !deleted.deletedIds.isEmpty {
              homeLog.info("runDeltaSync: \(deleted.deletedIds.count) deleted items")
              await localStore.deleteItems(deleted.deletedIds)
            }
            deletionSucceeded = true
          } catch {
            homeLog.warning("runDeltaSync: syncDeleted failed — will retry on next sync: \(error.localizedDescription)")
          }
        }

        // Advance the cursor to whatever was ACTUALLY consumed, even when the fetch failed
        // partway. This is the durability half of the fix above: upserted pages are on
        // disk, so the cursor must reflect them or the next cycle re-downloads work that
        // already landed — and, when the cursor was reset to 0, never escapes the loop.
        if deletionSucceeded || fetchError != nil {
          // TASK-847: advance only to what was actually consumed. On a clean run that is
          // status.itemSeq; on an early exit it is `since`, the last cursor the loop
          // committed, so the un-fetched remainder is re-requested next cycle instead of
          // being skipped forever.
          let committedSeq = reachedEndOfChanges ? status.itemSeq : min(since, status.itemSeq)
          await localStore.setItemSeq(committedSeq)
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
      // Held while no profile is active on a profile server (ProfileGate): a header-less
      // fetch returns the most restricted profile's progress into the legacy bucket.
      if !progressAllowed {
        homeLog.info("runDeltaSync: progress fetch held — no active profile yet (support=\(String(describing: self.profileSupport)))")
      } else if status.progressSeq > cursors.progressSeq || cursors.progressSeq == 0 {
        homeLog.info("runDeltaSync: fetching fresh progress (server=\(status.progressSeq) local=\(cursors.progressSeq))")
        let progressMap = try await progressAPI.progressAll().progress
        if !progressMap.isEmpty {
          await localStore.upsertProgress(progressMap, profileID: scope.id)
        }
        // Only advance cursor if server reports a real seq, otherwise stay at 0
        // so we re-check on next launch until the server starts tracking
        if status.progressSeq > 0 {
          await localStore.setProgressSeq(status.progressSeq, profileID: scope.id)
        }
      }

      // Step 5: Recompute rails from local store and update UI
      let rails = await localStore.queryRails()
      clearNetworkError()
      // Cursors and the store are account-wide and already committed above; only the
      // screen belongs to the profile, so a superseded pass stops here.
      guard applyRails(rails, startedAt: generation) else { return }
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
      if homeResultIsCurrent(generation, "runDeltaSync error"), homeAllRailsEmpty && homeLibraries.isEmpty {
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
      // The server answered, so a standing "Can't reach your NAS" is stale. Without this the
      // flag outlives the outage: homeLoad and foregroundRefresh both skip while it is set,
      // so the sync that would otherwise clear it never runs.
      if serverUnreachable { clearNetworkError() }
      let cursors = await localStore.getSyncCursors()

      // A cursor AHEAD of the server means "sync" here, not "nothing to do".
      //
      // THIS is where Just Added actually died, and it took three attempts to find because
      // the fixes were all downstream. `beat.itemSeq > cursors.itemSeq` is the same
      // comparison as runDeltaSync's delta gate, so a local cursor of 348155 against a
      // server at 13904 makes itemsChanged FALSE — and runDeltaSync is never called at
      // all. The clamp and the staleness check both live INSIDE runDeltaSync, so neither
      // could ever run. The device log said so plainly on every beat:
      // "change detected (items=false progress=true)" — only progress ever triggered a
      // sync, on its own separate cursor, which is why the app looked alive while the
      // library silently stopped growing.
      //
      // The warm-launch path makes this permanent rather than transient: homeLoad takes
      // PATH=in-memory whenever the rails are already populated, so the heartbeat is the
      // ONLY thing that runs, and it had decided there was nothing to do.
      let cursorAhead = SyncCursorClamp.isAhead(
        localItem: cursors.itemSeq, localProgress: cursors.progressSeq,
        serverItem: beat.itemSeq, serverProgress: beat.progressSeq)
      let itemsChanged = beat.itemSeq > cursors.itemSeq
      let progressChanged = beat.progressSeq > cursors.progressSeq
      if cursorAhead {
        homeLog.warning("""
          heartbeat: local cursor is AHEAD of the server           (item \(cursors.itemSeq) vs \(beat.itemSeq)) — the delta gate would read this as           "no changes" forever; forcing a sync so the reset can run
          """)
        dlog.warn(.library, "cursor ahead of server — forcing a sync to recover")
      }
      if itemsChanged || progressChanged || cursorAhead {
        // NEVER cancel a sync that is still running.
        //
        // This is what actually broke Just Added, and it hid behind three wrong diagnoses.
        // The heartbeat fires every 30s. A full re-fetch is 11 pages, and over the WAN path
        // this phone uses (https://DSMvideo.synology.me:5001) a single /items call measured
        // 21 SECONDS against 13ms on the LAN. So the resync could never finish inside one
        // heartbeat interval: the next beat cancelled it, restarted from seq 0, and the
        // next cancelled that. The device log shows the loop plainly — "local=0" at
        // 09:07:17, 09:14:28 and 09:14:31, each followed by a cancellation, never once
        // reaching the end.
        //
        // Cancelling made sense when this only ever started a SHORT delta. It is wrong for
        // a full resync, and wrong in general: an in-flight sync is strictly closer to done
        // than a fresh one, so restarting it can only lose progress. Whatever this beat
        // detected will still be there for the next one.
        if !startBackgroundSyncIfIdle({ await self.runDeltaSync(background: true) }) {
          homeLog.info("""
            heartbeat: change detected (items=\(itemsChanged) progress=\(progressChanged))             but a sync is already running — leaving it alone
            """)
        } else {
          homeLog.info("heartbeat: change detected (items=\(itemsChanged) progress=\(progressChanged)) — syncing")
        }
      }
    } catch {
      // Heartbeat failures are usually transient. But a persistent failure here is the
      // signal that we've moved off the network the current address lives on (e.g. left
      // the LAN mid-session and NWPathMonitor didn't deliver a path update). Re-probe:
      // if the current address is dead, revalidateConnection() runs the LAN→WAN cascade
      // and switches us over so the next heartbeat lands. Guard against piling up behind
      // an in-flight reconnect.
      homeLog.debug("heartbeat: failed — \(error.localizedDescription); revalidating")
      // No address answered: say so. The heartbeat is the only thing watching an idle
      // session, and it used to discard this result, leaving cached rails under no banner.
      if !isReconnecting, await revalidateConnection() == .failed {
        handleConnectionFailure(error)
      }
    }
  }

  // MARK: - Progress from Local (instant, no network)

  /// Called when player dismisses — recomputes rails from local SQLite immediately.
  func refreshProgressFromLocal() async {
    guard !isDemoMode else { return }
    let generation = homeStateGeneration
    let rails = await localStore.queryRails()
    // Via applyRails so Suggested refreshes too. This is the site where it matters most:
    // the viewer has just finished something, which is precisely when the seed — and so
    // the suggestion — should change. Assigning the three rails directly here would leave
    // Suggested recommending against the PREVIOUS film until something else recomputed.
    applyRails(rails, startedAt: generation)
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
  ///
  /// `asProfile`: the profile id the caller captured when playback STARTED. When given and it
  /// is no longer the active profile (deleted elsewhere, switched), the save is dropped rather
  /// than filed under whoever is active now. nil = the active profile (no check).
  ///
  /// With no profile chosen on a profile account (the unchosen scope) the save is dropped:
  /// there is nobody to file it under, and it must never land in the legacy bucket that the
  /// owner claims (FR-233).
  func recordProgress(itemId: String, positionSeconds: Int, durationSeconds: Int,
                      asProfile profileID: String? = nil) async {
    guard !isDemoMode else { return }
    let scope = await localStore.activeScope
    if scope.isUnchosen {
      homeLog.warning("recordProgress: dropped for \(itemId) — no profile is chosen on this profile account")
      return
    }
    if let profileID, profileID != scope.id {
      homeLog.warning("recordProgress: dropped for \(itemId) — playback began as another profile than the active one")
      return
    }
    let watchedAt = await localStore.upsertSingleProgress(
      itemId: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds,
      profileID: scope.id)

    // If the store could not be opened, the write above was a silent no-op and the outbox
    // has nothing to replay — so the server write is the ONLY copy. Surface the degraded
    // state once rather than letting positions vanish while the UI looks healthy.
    if await localStore.isUnavailable, !hasWarnedStoreUnavailable {
      hasWarnedStoreUnavailable = true
      localStoreUnavailableMessage = await localStore.unavailableReason
      homeLog.error("recordProgress: LocalStore unavailable — progress depends on the server write alone")
    }

    // Legacy scope while support is unknown (no list yet): keep the row pending locally
    // (written above) rather than let a header-less write land on the most restricted
    // profile (FR-221). It is the owner's once the list proves who that is (FR-233).
    guard ProfileGate.progressSyncAllowed(scope: scope, support: profileSupport) else {
      homeLog.info("recordProgress: server write held for \(itemId) — no active profile yet; queued")
      return
    }

    do {
      let applied = try await api.pinned(to: scope.headerValue).setProgress(
        id: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds,
        watchedAt: watchedAt)
      // TASK-891: honour the server's `applied` flag, which the API documents as "callers
      // must not treat a 200 alone as saved". Both outcomes clear the pending flag, but for
      // different reasons, and the log must not claim a save that did not happen:
      //  - applied:true  → stored. Synced.
      //  - applied:false → a NEWER write superseded this one. This value is stale, so
      //    requeueing it would later overwrite fresher progress. Clear it, don't retry it.
      await localStore.markProgressSynced(
        itemId: itemId, positionSeconds: positionSeconds, durationSeconds: durationSeconds,
        profileID: scope.id)
      if !applied {
        homeLog.info("recordProgress: server superseded the write for \(itemId) — a newer position already won")
        await forceProgressRefetch(profileID: scope.id)
      }
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
  /// `asProfile`: as for recordProgress.
  func setWatched(itemId: String, durationSeconds: Int, watched: Bool,
                  asProfile profileID: String? = nil) async {
    await recordProgress(
      itemId: itemId,
      positionSeconds: watched ? durationSeconds : 0,
      durationSeconds: durationSeconds,
      asProfile: profileID
    )
    await refreshProgressFromLocal()
  }

  /// A write the server refused as older than what it holds (applied:false) means this
  /// device's copy of that title is stale. The server moves no progress counter for a refused
  /// write, so nothing else would prompt a refetch; resetting the cursor makes the next sync
  /// (or heartbeat) fetch /progress/all and take the row that stands.
  private func forceProgressRefetch(profileID: String) async {
    await localStore.setProgressSeq(0, profileID: profileID)
  }

  /// Uploads progress the server has not confirmed. Idempotent and safe to call often —
  /// returns immediately when the outbox is empty.
  ///
  /// Called on foreground, after a successful reconnect, and at the start of a delta sync,
  /// so a device that recorded progress offline pushes it as soon as the NAS is reachable
  /// again. Ordering is oldest-first so a replay reconstructs the real watch sequence.
  ///
  /// Each replayed row carries the time it was WATCHED (`watchedAt`), and the server keeps
  /// the later watch: a row is applied only if its watch time is later than the stored one's
  /// (same second: arrival order), with any time ahead of the server's clock counted as the
  /// receive time (backend profiles.go, upsertProgress; FRD-001 FR-014, FR-019). So a backlog
  /// replayed after a long offline stretch cannot overwrite a position watched later on another
  /// device, nor undo a later Mark Watched / Unwatched. A refused row answers applied:false;
  /// the local copy is then stale, so the progress cursor is reset to refetch the row that stands.
  ///
  /// History: this comment once claimed a last-writer-wins comparison that did not exist (the
  /// upsert had no WHERE), and later that ordering by the server's arrival write_seq protected
  /// replays. It did the opposite: a late replay always arrived last and won (TASK-960).
  /// Verify against upsertProgress before trusting this again.
  func flushPendingProgress() async {
    guard !isDemoMode, sessionToken != nil, !isServerUnavailable else { return }

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

    // One profile for the whole drain, and none at all while the gate is shut: legacy rows
    // stay pending until claimLegacyRows hands them to the owner, then upload under the
    // owner's header. Never header-less (FR-221 would file them under a kid).
    let scope = await localStore.activeScope
    guard ProfileGate.progressSyncAllowed(scope: scope, support: profileSupport) else {
      homeLog.info("flushPendingProgress: held — no active profile yet (support=\(String(describing: self.profileSupport)))")
      return
    }
    let progressAPI = api.pinned(to: scope.headerValue)

    let pending = await localStore.pendingProgress(profileID: scope.id)
    guard !pending.isEmpty else { return }

    homeLog.info("flushPendingProgress: \(pending.count) queued progress row(s) to upload")
    var uploaded = 0
    var dropped = 0
    // Rows the server accepted but DISCARDED as superseded by a newer write. Cleared from
    // the outbox like an upload, but counted apart so the log never overstates what landed.
    var superseded = 0
    for row in pending {
      do {
        let applied = try await progressAPI.setProgress(
          id: row.itemId, positionSeconds: row.positionSeconds, durationSeconds: row.durationSeconds,
          // The time this was WATCHED, not the time the queue happens to be draining.
          watchedAt: row.updatedAt.isEmpty ? nil : row.updatedAt)
        // TASK-891: only clear the pending flag when the server actually STORED the write.
        // An applied:false means a newer write superseded this one — the row is obsolete, so
        // clearing it is correct, but count it separately from a real upload so the log
        // doesn't claim progress that never landed.
        await localStore.markProgressSynced(
          itemId: row.itemId, positionSeconds: row.positionSeconds, durationSeconds: row.durationSeconds,
          profileID: scope.id)
        if applied {
          uploaded += 1
        } else {
          superseded += 1
          if superseded == 1 { await forceProgressRefetch(profileID: scope.id) }
        }
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
          await localStore.dropPendingProgress(itemId: row.itemId, profileID: scope.id)
          dropped += 1
          continue
        }
        homeLog.warning("flushPendingProgress: stopped after \(uploaded) upload(s), \(dropped) dropped — \(error.localizedDescription)")
        return
      }
    }
    homeLog.info("flushPendingProgress: uploaded \(uploaded) row(s), \(superseded) superseded, dropped \(dropped) permanently-rejected row(s)")
  }

  // homeRefreshProgress() lived here, "kept for backwards compat with any view that calls
  // it". No view did — and both LibrariesView and TVMainView carry comments explaining
  // why they deliberately call refreshProgressFromLocal directly instead.

  // MARK: - Profiles

  /// Loads the account's profile list and records what it proves about profile support
  /// (ProfileGate). On a list: caches it for the offline picker (FR-263), hands progress
  /// recorded before profiles existed to the owner explicitly (FR-233), and enters a
  /// single-profile account straight into its only profile (AC-002-40). On failure only a
  /// 404 changes anything (server predates profiles); offline, timeouts and 5xx leave
  /// support unknown, so progress traffic stays held and is retried on the next sync.
  func refreshProfiles() async {
    guard !isDemoMode, sessionToken != nil else { return }
    do {
      let resp = try await api.profiles()
      profileSupport = .supported
      profileStore.setCachedProfiles(
        resp.profiles, unrestrictedLevel: resp.unrestrictedLevel)
      serverMaxProfiles = resp.maxProfiles
      defer { profileRevision += 1 }
      // A server that lists profiles sends every title's level: re-fetch any title stored
      // without one. The cursor reset is read by this session's sync: runDeltaSync calls
      // refreshProfiles BEFORE it reads the cursor, and from any other caller the heartbeat
      // (every 30s, both platforms) sees item_seq 0 behind the server and starts a sync.
      if await localStore.beginAgeLevelBackfillIfNeeded() {
        homeLog.info("refreshProfiles: titles without an age level — catalog re-fetch armed")
      }
      if let owner = resp.profiles.first(where: \.isOwner) {
        await localStore.claimLegacyRows(ownerID: owner.id)
        // FR-206 on this device: a profile the server no longer lists was deleted (here or
        // on another device while this one was away). Its positions, unsent outbox and
        // cursor leave this device. Only from a list that names its owner: a list without
        // one is malformed, and deleting against it could erase live profiles' data.
        let listed = Set(resp.profiles.map(\.id))
        for gone in await localStore.storedProfileIDs().subtracting(listed) {
          homeLog.warning("refreshProfiles: profile \(gone) is gone — removing its local progress")
          await localStore.deleteProfileData(profileID: gone)
        }
      } else {
        homeLog.error("refreshProfiles: list has no owner — legacy progress left unclaimed, no purge")
      }
      // FR-260: a remembered profile that was deleted is no longer an identity. Drop it and
      // everything shown for it; the picker (or the single-profile auto-enter) takes over.
      // Reads fall to the unchosen scope (fail closed), never legacy: a save in this window
      // must not reach the bucket the owner claims.
      if let remembered = profileStore.activeProfileID,
         !resp.profiles.contains(where: { $0.id == remembered }) {
        homeLog.warning("refreshProfiles: remembered profile is gone — back to the picker")
        profileStore.setActive(nil)
        await localStore.setActiveProfile(profileStore.activeScope)
        discardProfileScopedHomeState()
      } else if let remembered = profileStore.activeProfileID,
                let fresh = resp.profiles.first(where: { $0.id == remembered }),
                fresh.maxAgeLevel != profileStore.activeScope.maxAgeLevel {
        // The active profile's age level was changed (here or on another device). The local
        // fallback must filter by the NEW ceiling from now on (FR-262); the next home load
        // re-reads under it. Same profile, so nothing else is discarded.
        homeLog.info("refreshProfiles: active profile's level is now \(fresh.maxAgeLevel)")
        profileStore.setActive(fresh)
        await localStore.setActiveProfile(ProfileScope(profile: fresh))
      }
      if profileStore.activeProfileID == nil, resp.profiles.count == 1,
         let only = resp.profiles.first {
        profileStore.setActive(only)
        await localStore.setActiveProfile(ProfileScope(profile: only))
      }
      // Whatever the store now says is the scope reads must use: covers the first list on a
      // device that was legacy (now unchosen until a profile is chosen), an unchosen ceiling
      // that moved with the list, and a new ladder top from the server.
      let wanted = profileStore.activeScope
      let current = await localStore.activeScope
      if current != wanted {
        await localStore.setActiveProfile(wanted)
        if current.id != wanted.id { discardProfileScopedHomeState() }
      }
      evaluateProfilePicker(listIsFresh: true)
      await loadAgeLevelsIfNeeded()
      homeLog.info("refreshProfiles: \(resp.profiles.count) profile(s); active=\(self.profileStore.activeProfileID ?? "none") picker=\(self.needsProfilePicker)")
      writeTopShelfSnapshot()  // the list sets the shelf's ceiling (FR-264, TopShelfPolicy)
    } catch {
      profileSupport = ProfileGate.support(afterProfilesError: error)
      homeLog.warning("refreshProfiles: failed — \(error.localizedDescription); support=\(String(describing: self.profileSupport))")
    }
  }

  /// Fetches the age ladder once per session (GET /profiles/age-levels): the display labels,
  /// and the server's unrated level, persisted in ActiveProfileStore for offline reads. The
  /// guard is `ageLevels.isEmpty`, cleared only by sign-out, so this runs once per app launch
  /// (and after every sign-in); refreshProfiles' success path calls it, so the stored unrated
  /// level is refreshed at least once per launch whenever the server is reachable.
  func loadAgeLevelsIfNeeded() async {
    guard ageLevels.isEmpty, !isDemoMode, sessionToken != nil else { return }
    do {
      let resp = try await api.ageLevels()
      ageLevels = resp.levels
      profileStore.setCachedAgeLevels(resp.levels)
      profileStore.setUnratedLevel(resp.unratedLevel)
      // refreshProfiles hands LocalStore its scope BEFORE calling here, so a changed unrated
      // level must reach the offline reads now, not at the next list fetch. Same profile, so
      // nothing shown is discarded.
      let wanted = profileStore.activeScope
      if await localStore.activeScope != wanted {
        await localStore.setActiveProfile(wanted)
      }
    } catch {
      // Display labels only: empty states and the tier picker fall back to wording that
      // does not name the level. Retried on the next call.
      homeLog.warning("loadAgeLevelsIfNeeded: failed — \(error.localizedDescription)")
    }
  }

  #if DEBUG
  /// QA hook only (ProfileScreenPreviewHost): the ladder labels without a server.
  func seedAgeLevelsForPreview(_ levels: [AgeLevelsResponse.Level]) {
    ageLevels = levels
  }
  #endif

  // MARK: - Profile picker gate (FR-260)

  /// Records a picker moment and decides at once from the list already known (FR-260).
  /// The screens slice calls this with `.switchRequested`; the app wires the others.
  func notePickerTrigger(_ trigger: ProfilePickerTrigger) {
    pendingPickerTrigger = trigger
    evaluateProfilePicker(listIsFresh: false)
  }

  /// Call when the scene enters the background.
  func noteEnteredBackground(at date: Date = Date()) {
    enteredBackgroundAt = date
  }

  /// Call when the scene returns to the foreground. tvOS asks again after more than
  /// `ProfileGate.tvOSPickerBackgroundThreshold`; iOS never does on its own.
  func noteReturnedToForeground(at date: Date = Date()) {
    guard let left = enteredBackgroundAt, sessionToken != nil, !isDemoMode else { return }
    enteredBackgroundAt = nil
    notePickerTrigger(.returnedFromBackground(away: date.timeIntervalSince(left)))
  }

  /// Sets `needsProfilePicker` from `ProfileGate.shouldShowPicker`, using the cached list
  /// (kept fresh by refreshProfiles). A trigger that did not open the picker is settled only
  /// against a fresh list: the cached one may predate a deletion, or be empty after pairing.
  func evaluateProfilePicker(listIsFresh: Bool) {
    let store = profileStore
    let show = ProfileGate.shouldShowPicker(
      platform: .current, trigger: pendingPickerTrigger,
      profileIDs: store.cachedProfiles.map(\.id), activeID: store.activeProfileID)
    if show {
      needsProfilePicker = true
    } else if listIsFresh {
      // A fresh list can also close it: the account is down to one profile, auto-entered.
      pendingPickerTrigger = nil
      needsProfilePicker = false
    }
  }

  /// Makes `profile` the active profile and reloads home for it (FR-261, AC-002-42).
  ///
  /// Order matters. Everything profile-scoped is emptied and fenced BEFORE the identity
  /// changes, so no frame shows the old profile's rails under the new name, and fenced again
  /// AFTER the scope change, because a load that started during the store's await would
  /// otherwise have captured the in-between generation. Only then does home reload.
  /// The caller has already checked the PIN; this does no authorisation.
  func switchProfile(to profile: Profile) async {
    let wasActive = profileStore.activeProfileID == profile.id
    needsProfilePicker = false
    pendingPickerTrigger = nil
    defer { profileRevision += 1 }
    // Re-choosing the profile already on screen (tvOS asks at launch and after 30 minutes)
    // is not a switch: keep what is shown and let homeLoad refresh it.
    if wasActive && !homeAllRailsEmpty {
      await homeLoad()
      return
    }
    clearHomeState()
    profileStore.setActive(profile)
    await localStore.setActiveProfile(ProfileScope(profile: profile))
    // Rows recorded in the legacy bucket since the last refresh still belong to the owner
    // (FR-233). Claiming is idempotent, so doing it on every switch is safe.
    if let owner = profileStore.cachedProfiles.first(where: \.isOwner) {
      await localStore.claimLegacyRows(ownerID: owner.id)
    }
    discardProfileScopedHomeState()
    await homeLoad()
  }

  // MARK: - Watchlist

  var watchlistItems: [ItemSummary] = []

  /// TASK-851: non-nil when the last loadWatchlist() attempt failed.
  ///
  /// Without this, a failed load is indistinguishable from a genuinely empty watchlist:
  /// watchlistItems stays at its previous value — [] on a cold launch, and [] again after
  /// logout/handleConnectionFailure force-clear it — so WatchlistView renders
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
    let generation = homeStateGeneration
    // Header-less, this would show the most restricted profile's list (FR-221).
    guard ProfileGate.progressSyncAllowed(
      scope: await localStore.activeScope, support: profileSupport) else {
      homeLog.info("loadWatchlist: held — no active profile yet")
      return
    }
    do {
      let resp = try await api.watchlist()
      guard homeResultIsCurrent(generation, "loadWatchlist") else { return }
      watchlistItems = resp.items
      watchlistLoadFailed = false
    } catch {
      guard homeResultIsCurrent(generation, "loadWatchlist") else { return }
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

  /// TASK-989 (FR-137): set when a watchlist change could not be saved and was rolled
  /// back, so the user is told at the time instead of watching the toggle silently undo
  /// itself. Shown briefly by the root views, which clear it.
  var watchlistNotice: String?

  /// The watchlist-failure message, naming the real cause when the connection is down.
  static func watchlistNotice(isOffline: Bool, serverUnreachable: Bool) -> String {
    guard let cause = OfflineBanner.cause(isOffline: isOffline, serverUnreachable: serverUnreachable) else {
      return "Couldn't update your watchlist. Try again."
    }
    return "Couldn't update your watchlist. \(cause)."
  }

  func toggleWatchlist(item: ItemSummary) async {
    guard !isDemoMode else { return }
    // Header-less, the write would land on the most restricted profile's list (FR-221).
    guard ProfileGate.progressSyncAllowed(
      scope: await localStore.activeScope, support: profileSupport) else {
      homeLog.warning("toggleWatchlist: held — no active profile yet")
      return
    }
    // TASK-820: optimistic update, but revert on server failure so the UI can't
    // diverge silently from the server until the next full sync.
    // FR-261: the rollback edits the list it started on. After a switch, watchlistItems is
    // the NEW profile's list, and re-inserting the old profile's item would leak it there.
    let generation = homeStateGeneration
    let alreadyIn = watchlistItems.contains(where: { $0.id == item.id })
    if alreadyIn {
      let removedIndex = watchlistItems.firstIndex(where: { $0.id == item.id })
      watchlistItems.removeAll(where: { $0.id == item.id })
      do {
        try await api.removeFromWatchlist(id: item.id)
      } catch {
        guard homeResultIsCurrent(generation, "toggleWatchlist rollback") else { return }
        // Restore at the original position (clamped) so ordering is preserved.
        let insertAt = min(removedIndex ?? 0, watchlistItems.count)
        watchlistItems.insert(item, at: insertAt)
        // A bare catch swallowed 401s here: the write silently no-op'd while the UI kept
        // looking authenticated. loadWatchlist already routes failures this way.
        handleConnectionFailure(error)
        // After handleConnectionFailure, so the flags it sets name the cause (FR-137).
        watchlistNotice = Self.watchlistNotice(isOffline: isOffline, serverUnreachable: serverUnreachable)
      }
    } else {
      watchlistItems.insert(item, at: 0)
      do {
        try await api.addToWatchlist(id: item.id)
      } catch {
        guard homeResultIsCurrent(generation, "toggleWatchlist rollback") else { return }
        watchlistItems.removeAll(where: { $0.id == item.id })
        handleConnectionFailure(error)
        watchlistNotice = Self.watchlistNotice(isOffline: isOffline, serverUnreachable: serverUnreachable)
      }
    }
  }

  // MARK: - Deep Link

  /// Set when the app is opened via a dsvideo://item/{id} URL from the Top Shelf.
  var pendingDeepLinkItemID: String? = nil

  /// Set when Siri asks for a search ("find X in DSM Video"), or when a spoken title
  /// matched nothing and the user is better served by the search screen than by Home.
  ///
  /// Separate from `pendingDeepLinkItemID` because the destinations differ: one opens an
  /// item, the other opens a search surface pre-filled with a term. Collapsing them into a
  /// single "pending navigation" enum was the alternative; two plain optionals read better
  /// at both ends and neither consumer has to switch on a case it does not handle.
  var pendingSearchTerm: String? = nil

  // MARK: - Top Shelf Snapshot

  /// Writes what the tvOS Top Shelf may show to the shared App Group container, so the
  /// extension can display it when the app is focused. TopShelfPolicy decides WHAT; this
  /// only renders it to topshelf.json.
  ///
  /// No restricted profile on the account: Continue Watching (up to 10), falling back to Just
  /// Added. The Top Shelf is the surface you see before opening anything, so its job is to get
  /// you back into what you were already watching in one click.
  ///
  /// Any restricted profile on the account (FR-264, TASK-923): the shelf is the shared TV's
  /// home screen with no chosen viewer, so it shows only Just Added titles the most restricted
  /// profile may see, without resume bars. Independent of the active profile, so it holds while
  /// the picker is pending. Rewritten when the rails change and after every profile list fetch.
  func writeTopShelfSnapshot() {
    // An empty shelf must CLEAR it, not leave the previous contents advertised.
    // The early-return here meant any non-logout path to empty rails (server unreachable,
    // library removed, a failed load that cleared them) left a stale topshelf.json on disk
    // — so the Top Shelf kept offering titles that deep-linked into items the user may no
    // longer have access to. The same holds when the ceiling filters everything out.
    guard let content = TopShelfPolicy.content(
      continueWatching: homeContinueWatching, justAdded: homeJustAdded,
      profiles: profileStore.cachedProfiles,
      unrestrictedLevel: profileStore.unrestrictedLevel,
      unratedLevel: profileStore.unratedLevel
    ) else {
      deleteTopShelfSnapshot()
      return
    }
    guard let fileURL = topShelfSnapshotURL else { return }

    let items: [TopShelfItem] = content.items.map { item in
      // Prefer backdrop for landscape Top Shelf cards, fall back to poster
      let imageID = item.backdropImageId ?? item.posterImageId
      let imageKind: APIClient.ImageKind = item.backdropImageId != nil ? .backdrop : .poster
      // SECURITY (TASK-774): do NOT bake the live bearer session token into the persisted
      // image URL. This file is unencrypted JSON in a shared App Group container — a token
      // written here is a working, long-lived credential readable via device backup or any
      // process with the group entitlement. The Top Shelf extension uses setImageURL(), which
      // is fetched by the tvOS system and cannot inject an Authorization header, and there is
      // no shared Keychain access group between the app and the extension. So we fail closed:
      // persist the tokenless URL only. Artwork that requires auth simply won't render in Top
      // Shelf; titles + deep links still work. Never persist the credential.
      // TASK-913, resolved. The earlier note here claimed the server "ignores ?w=",
      // measured from w=760 and w=1920 returning the identical 883KB 2000x3000 file.
      // That reading was wrong: ParseImageSize snapped EVERYTHING above 500 to
      // `original`, so both requests asked for the same thing and got it. The server
      // now serves w780/w1280 backdrop rungs, and `type=` picks poster vs backdrop —
      // without it this 16:9 shelf card was fed the 2:3 poster and cropped to a torso.
      let imageURLString: String? = imageID.flatMap {
        api.imageURL(id: $0, width: 780, kind: imageKind)?.absoluteString
      }
      return TopShelfItem(
        id: item.id,
        title: item.title,
        year: item.year,
        imageURL: imageURLString,
        deepLinkURL: "dsvideo://item/\(item.id)",
        // tvOS draws the resume bar from this; nil under a restricted ceiling (FR-264).
        playbackProgress: TopShelfPolicy.playbackProgress(for: item, ceiling: content.ceiling),
        ageLevel: item.ageLevel
      )
    }

    let snapshot = TopShelfSnapshot(
      sectionTitle: content.rail.sectionTitle,
      rail: content.rail,
      ceiling: content.ceiling,
      items: items
    )
    do {
      // sortedKeys: key order is otherwise unspecified, so the same shelf could encode to different
      // bytes and the unchanged-file check below would announce a change that is not one.
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(snapshot)
      // The rails' didSet fires this on every change, most of which leave the shelf as it was.
      // Rewriting and announcing an identical file would make tvOS reload for nothing (TASK-992).
      if (try? Data(contentsOf: fileURL)) == data { return }
      try data.write(to: fileURL, options: .atomic)
      TopShelfRefresh.notify()  // tvOS reloads the shelf only when told (FR-146)
    } catch {
      // Fail closed: a failed write must not leave the PREVIOUS snapshot advertised.
      homeLog.error("writeTopShelfSnapshot: write failed — \(error.localizedDescription); clearing the shelf")
      deleteTopShelfSnapshot()
    }
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

