import Foundation

// MARK: - FR-152 · guided server install and the first-connection moment
//
// This file is the ONE home for: the steps to install DSVideo Server on a NAS, the wording
// of the "something answered but it is not DSVideo Server" error, whether a failed sign-in
// offers the install help, and how "this server has been welcomed" is remembered. The views
// (ConnectionHelpView, Settings > Help, the sign-in error row, the tvOS sign-in and pairing
// screens) and AppState only call into it.

nonisolated enum ServerInstallGuide {
  struct Step: Equatable, Sendable {
    let title: String
    let detail: String
  }

  /// Installing the server, in order. Step 1 names the same address as
  /// `RecommendedServer.displayURL` (the page `RecommendedServer.downloadURL` opens).
  static let steps: [Step] = [
    Step(
      title: "Download DSVideoServer",
      detail: "Download the latest DSVideoServer package from \(RecommendedServer.displayURL) onto your Mac or PC."),
    Step(
      title: "Install on Your NAS",
      detail: "Open DSM in a browser. Go to Package Center → Manual Install, select the downloaded file, and follow the prompts. You may need to allow third-party packages in Package Center settings."),
    Step(
      title: "Configure Your Video Folders",
      detail: "After installation, open DSVideoServer from the DSM desktop. Enter the paths to your Movies and TV Shows folders on the NAS, then click Save."),
    Step(
      title: "Note Your NAS Address",
      detail: "You'll need your NAS's local IP address (e.g. 192.168.1.100) or your QuickConnect ID. Both are found in DSM → Control Panel → Network or QuickConnect."),
  ]

  /// The topic on the pre-sign-in help sheet.
  static let topicTitle = "Install the server"
  static let topicDetail = "This app plays what is on your Synology NAS through DSVideo Server, a free package you install on the NAS once."

  /// The error-row link and the tvOS heading.
  static let linkTitle = "How to install the server"
  static let tvHeading = "Install DSVideo Server on your NAS"
  static let tvScanPrompt = "On a phone or computer, scan the code or visit"

  /// A host answered the sign-in request with a bodyless 404: it is a web server (usually DSM
  /// itself) with no DSVideo Server behind that address. Deliberately avoids the words the
  /// sign-in screen's last-resort prettifier keys on ("couldn't find", "refused", "timed out").
  static let notDSVideoMessage =
    "Something answered at this address, but it isn't DSVideo Server. Is DSVideo Server installed on your NAS?"
}

/// Whether a failed sign-in or pairing offers the install help. Pure: everything it needs is
/// passed in. The rule is "no DSVideo server answered", so it is never offered for a wrong
/// password, a permission refusal, a Local Network denial or a failed QuickConnect lookup.
nonisolated enum InstallLinkPolicy {
  static func shouldOffer(
    lastError: Error?,
    localNetworkRefused: Bool = false,
    quickConnectLookupFailed: Bool = false
  ) -> Bool {
    guard !localNetworkRefused, !quickConnectLookupFailed, let lastError else { return false }
    if let api = lastError as? APIError {
      switch api {
      case .network:
        return true
      case .connection(let code):
        return !isTransportSecurityFailure(code)
      case .http(let status):
        return status == 404
      case .localNetworkDenied, .server, .invalidURL, .converting, .decode:
        return false
      }
    }
    if let url = lastError as? URLError {
      return !isTransportSecurityFailure(url.code)
    }
    return false
  }

  /// A TLS or ATS failure means a server IS there (or iOS refused to ask): installing the
  /// server is not the fix, so the link would send the user the wrong way.
  private static func isTransportSecurityFailure(_ code: URLError.Code) -> Bool {
    switch code {
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
         .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
         .appTransportSecurityRequiresSecureConnection:
      return true
    default:
      return false
    }
  }
}

/// "Found N libraries, M videos", shown once per server on the first successful connection.
nonisolated struct FirstConnectionRecord {
  static let defaultsKey = "dsReel.firstConnectionWelcomedServers"

  let defaults: UserDefaults

  /// Which server a sign-in reached: the QuickConnect ID when the device connects through one
  /// (the same NAS from home and away), else the host and port that answered. Lower-cased.
  /// The server reports no identity of its own, so the same NAS reached by two unrelated
  /// addresses counts as two servers; that errs toward showing the moment once more, never
  /// toward hiding it.
  static func serverKey(quickConnectID: String?, baseURL: String) -> String? {
    let id = quickConnectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !id.isEmpty { return "qc:" + id.lowercased() }
    let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    let parsed = URL(string: raw.contains("://") ? raw : "http://" + raw)
    guard let host = parsed?.host?.lowercased(), !host.isEmpty else { return nil }
    return "host:" + host + (parsed?.port.map { ":\($0)" } ?? "")
  }

  func hasWelcomed(_ key: String) -> Bool {
    (defaults.stringArray(forKey: Self.defaultsKey) ?? []).contains(key)
  }

  func markWelcomed(_ key: String) {
    var keys = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    guard !keys.contains(key) else { return }
    keys.append(key)
    defaults.set(keys, forKey: Self.defaultsKey)
  }

  /// "Found 2 libraries, 1,204 videos". Nil when there is nothing to report yet (a server with
  /// no libraries and no videos is not a moment to celebrate; it stays pending for a later sync).
  static func message(libraries: Int, videos: Int, locale: Locale = .current) -> String? {
    guard libraries > 0 || videos > 0 else { return nil }
    let libs = libraries.formatted(.number.locale(locale))
    let vids = videos.formatted(.number.locale(locale))
    return "Found \(libs) \(libraries == 1 ? "library" : "libraries"), \(vids) \(videos == 1 ? "video" : "videos")"
  }
}
