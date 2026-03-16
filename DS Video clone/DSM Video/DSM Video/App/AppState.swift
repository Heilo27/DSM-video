import Foundation
import Observation
import Security
import SwiftUI

@MainActor
@Observable
final class AppState {
  private enum Keys {
    static let baseURL = "dsReel.baseURL"
    static let username = "dsReel.username"
    static let rememberMe = "dsReel.rememberMe"
    static let useHTTPS = "dsReel.useHTTPS"
    static let tmdbAPIKey = "dsReel.tmdbAPIKey"
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
  var tmdbAPIKey: String {
    didSet {
      UserDefaults.standard.set(tmdbAPIKey, forKey: Keys.tmdbAPIKey)
      updateAPI()
    }
  }

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
  } // For compatibility, stores session ID
  var sessionID: String? // Video Station session ID
  var synoToken: String? // Video Station CSRF token
  var deviceID: String? // Device ID (did) from login - needed for Cookie header
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
    guard let url = normalizedBaseURL(baseURL, forceHTTPS: useHTTPS) else {
      // Invalid URL — leave api as-is; login() will catch this before any request is made.
      return
    }
    api = APIClient(
      baseURL: url,
      token: sessionToken,
      tmdbAPIKey: tmdbAPIKey.isEmpty ? nil : tmdbAPIKey
    )
  }

  // Legacy Video Station WebAPI client (for reference/debugging)
  var videoStationAPI: VideoStationWebAPIClient? {
    guard let url = normalizedBaseURL(baseURL, forceHTTPS: useHTTPS) else { return nil }
    return VideoStationWebAPIClient(
      baseURL: url,
      sessionID: sessionID,
      synoToken: synoToken,
      deviceID: deviceID
    )
  }

  init() {
    let d = UserDefaults.standard
    let storedBaseURL = d.string(forKey: Keys.baseURL) ?? "http://localhost:8090"
    let storedUseHTTPS = d.object(forKey: Keys.useHTTPS) as? Bool ?? false
    let storedTmdbAPIKey = d.string(forKey: Keys.tmdbAPIKey) ?? ""
    let storedRememberMe = d.object(forKey: Keys.rememberMe) as? Bool ?? true

    baseURL = storedBaseURL
    username = d.string(forKey: Keys.username) ?? ""
    rememberMe = storedRememberMe
    useHTTPS = storedUseHTTPS
    tmdbAPIKey = storedTmdbAPIKey

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
    let resolvedInitURL = normalizedBaseURL(storedBaseURL, forceHTTPS: storedUseHTTPS)
      ?? URL(string: "http://0.0.0.0")!
    api = APIClient(
      baseURL: resolvedInitURL,
      token: storedToken,
      tmdbAPIKey: storedTmdbAPIKey.isEmpty ? nil : storedTmdbAPIKey
    )
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

  func login() async {
    loginError = nil
    isLoggingIn = true
    defer { isLoggingIn = false }

    do {
      // If the server field is a bare QuickConnect ID (no dots, no scheme),
      // resolve it to candidate NAS URLs and try each until one works.
      // LAN IPs are tried first to avoid NAT hairpinning and self-signed cert issues.
      let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if let qcID = QuickConnectResolver.extractBareID(from: raw) {
        let candidates = try await QuickConnectResolver.resolve(id: qcID)
        guard !candidates.isEmpty else {
          loginError = "Couldn't find \"\(qcID)\". Check the QuickConnect ID and try again."
          return
        }
        var lastError: Error?
        for candidateURL in candidates {
          guard let url = URL(string: candidateURL) else { continue }
          do {
            let tempClient = APIClient(baseURL: url, token: nil)
            let resp = try await tempClient.login(username: username, password: savedPassword)
            // Success — persist resolved address and session
            baseURL = candidateURL
            sessionToken = resp.token
            sessionID = nil; synoToken = nil; deviceID = nil
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
        loginError = (lastError as? APIError)?.userMessage ?? "Login failed."
        return
      }

      // Validate server address before attempting login
      guard normalizedBaseURL(baseURL, forceHTTPS: useHTTPS) != nil else {
        loginError = "Invalid server address. Please check the URL."
        return
      }

      // Direct IP / hostname login
      let resp = try await api.login(username: username, password: savedPassword)

      // Store session token (didSet persists to Keychain when rememberMe is on)
      sessionToken = resp.token
      sessionID = nil // Clear Video Station session
      synoToken = nil
      deviceID = nil

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
    sessionID = nil
    synoToken = nil
    deviceID = nil
    pairingCode = nil
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

    guard let serverURL = normalizedBaseURL(baseURL, forceHTTPS: useHTTPS) else {
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

func normalizedBaseURL(_ input: String, forceHTTPS: Bool) -> URL? {
  var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !s.isEmpty else { return nil }
  if !s.contains("://") {
    s = (forceHTTPS ? "https://" : "http://") + s
  }
  if forceHTTPS {
    s = s.replacingOccurrences(of: "http://", with: "https://")
  }

  // Parse URL to check for port
  guard var url = URL(string: s), url.host != nil else {
    return nil
  }

  // If no port specified and it's a local NAS address, add default DSM port.
  // Don't add ports to quickconnect.to — it handles routing itself.
  if url.port == nil {
    let host = url.host ?? url.host(percentEncoded: false) ?? ""
    if host.contains("192.168.") || host.contains("10.") || host.contains("172.") || host.contains("synology.me") {
      let defaultPort = forceHTTPS ? 5001 : 5000
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      components?.port = defaultPort
      if let newURL = components?.url {
        url = newURL
      }
    }
  }

  return url
}

