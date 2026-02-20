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
    didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
  }
  var username: String {
    didSet { UserDefaults.standard.set(username, forKey: Keys.username) }
  }
  var rememberMe: Bool {
    didSet { UserDefaults.standard.set(rememberMe, forKey: Keys.rememberMe) }
  }
  var useHTTPS: Bool {
    didSet { UserDefaults.standard.set(useHTTPS, forKey: Keys.useHTTPS) }
  }
  var tmdbAPIKey: String {
    didSet { UserDefaults.standard.set(tmdbAPIKey, forKey: Keys.tmdbAPIKey) }
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
    }
  } // For compatibility, stores session ID
  var sessionID: String? // Video Station session ID
  var synoToken: String? // Video Station CSRF token
  var deviceID: String? // Device ID (did) from login - needed for Cookie header
  var isLoggingIn: Bool = false
  var loginError: String?

  var pairingCode: String?
  var isGeneratingPairingCode: Bool = false
  var pairingError: String?

  var savedPassword: String = ""

  // Use custom REST API client (our backend)
  var api: APIClient {
    APIClient(
      baseURL: normalizedBaseURL(baseURL, forceHTTPS: useHTTPS),
      token: sessionToken,
      tmdbAPIKey: tmdbAPIKey.isEmpty ? nil : tmdbAPIKey
    )
  }
  
  // Legacy Video Station WebAPI client (for reference/debugging)
  var videoStationAPI: VideoStationWebAPIClient {
    VideoStationWebAPIClient(
      baseURL: normalizedBaseURL(baseURL, forceHTTPS: useHTTPS),
      sessionID: sessionID,
      synoToken: synoToken,
      deviceID: deviceID
    )
  }

  init() {
    let d = UserDefaults.standard
    baseURL = (d.string(forKey: Keys.baseURL) ?? "http://localhost:8090")
    username = (d.string(forKey: Keys.username) ?? "")
    rememberMe = d.object(forKey: Keys.rememberMe) as? Bool ?? true
    useHTTPS = d.object(forKey: Keys.useHTTPS) as? Bool ?? false
    tmdbAPIKey = (d.string(forKey: Keys.tmdbAPIKey) ?? "")

    // Load saved credentials from Keychain if remember me is enabled
    if rememberMe {
      savedPassword = Self.loadFromKeychain(account: Keys.keychainAccount) ?? ""
      sessionToken = Self.loadFromKeychain(account: Keys.keychainAccountToken)
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
      // Use custom REST API for login
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
    } catch {
      pairingError = (error as? APIError)?.userMessage ?? "Failed to generate pairing code."
    }
  }

  func exchangePairingCode(_ code: String) async {
    loginError = nil
    isLoggingIn = true
    defer { isLoggingIn = false }

    do {
      let resp = try await APIClient(baseURL: normalizedBaseURL(baseURL, forceHTTPS: useHTTPS), token: nil)
        .exchangePairingCode(code: code)
      sessionToken = resp.token
    } catch {
      loginError = (error as? APIError)?.userMessage ?? "Invalid pairing code."
    }
  }
}

func normalizedBaseURL(_ input: String, forceHTTPS: Bool) -> URL {
  var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
  if !s.contains("://") {
    s = (forceHTTPS ? "https://" : "http://") + s
  }
  if forceHTTPS {
    s = s.replacingOccurrences(of: "http://", with: "https://")
  }
  
  // Parse URL to check for port
  guard var url = URL(string: s) else {
    return URL(string: "http://localhost:8090")!
  }
  
  // If no port specified and it's a Video Station URL (likely), add default port
  if url.port == nil {
    let host = url.host ?? url.host(percentEncoded: false) ?? ""
    
    // If it looks like a Synology NAS (IP address or .synology.me), add default port
    if host.contains("192.168.") || host.contains("synology.me") || host.contains("quickconnect.to") {
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

