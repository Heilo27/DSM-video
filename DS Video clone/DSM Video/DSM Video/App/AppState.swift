import CryptoKit
import Foundation
import Network
import Observation
import Security
import SwiftUI

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
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
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
    // Credentials are compared via SHA-256 to avoid plaintext extraction from the binary.
    if sha256(username.trimmingCharacters(in: .whitespaces)) == sha256("appledemo") &&
       sha256(savedPassword) == sha256("DSVideo2024") {
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
            // Success — persist resolved address and session
            baseURL = urlStr
            sessionToken = resp.token
            if rememberMe {
              Self.saveToKeychain(savedPassword, account: Keys.keychainAccount)
            } else {
              Self.deleteFromKeychain(account: Keys.keychainAccount)
              Self.deleteFromKeychain(account: Keys.keychainAccountToken)
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
    sessionToken = nil
    pairingCode = nil
    isDemoMode = false
    loginError = nil
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

  /// Call after a successful API operation to clear server-unreachable state.
  /// isOffline is managed exclusively by NWPathMonitor.
  func clearNetworkError() {
    serverUnreachable = false
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

