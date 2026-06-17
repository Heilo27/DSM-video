import Foundation
import os.log

private let qcLog = Logger(subsystem: "com.dsm.qc", category: "resolver")

enum QuickConnectResolver {
  /// Returns the bare QuickConnect ID if `input` looks like a QC identifier, nil otherwise.
  /// Handles bare IDs ("mynas"), full domains ("mynas.quickconnect.to"),
  /// and full URLs ("https://mynas.quickconnect.to").
  static func extractBareID(from input: String) -> String? {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    // Strip scheme
    let lower = s.lowercased()
    if lower.hasPrefix("https://") { s = String(s.dropFirst(8)) }
    else if lower.hasPrefix("http://") { s = String(s.dropFirst(7)) }
    // Strip path
    if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
    // Strip .quickconnect.to suffix — yields the bare ID
    let qcDomain = ".quickconnect.to"
    if s.lowercased().hasSuffix(qcDomain) {
      s = String(s.dropLast(qcDomain.count))
      return s.isEmpty ? nil : s
    }
    // Bare ID: no dots or colons (e.g. "mynas")
    if !s.isEmpty && !s.contains(".") && !s.contains(":") { return s }
    return nil
  }

  /// A resolved candidate URL and whether it requires the QuickConnect tunnel cookie.
  struct Candidate {
    let url: URL
    let requiresTunnelCookie: Bool
  }

  /// Resolves a QuickConnect ID and returns all candidate base URLs ordered for login attempts.
  /// LAN IPs first (faster on home network), WAN direct next, relay last.
  /// Each URL uses the DSM port (5000/5001) so DSM nginx can proxy to the backend.
  static func resolveCandidates(id: String) async throws -> [Candidate] {
    guard let bareID = extractBareID(from: id) else { return [] }
    let json = try await queryServerInfo(id: bareID)

    if let errno = json["errno"] as? Int, errno != 0 { return [] }

    guard let server = json["server"] as? [String: Any],
          let ext = server["external"] as? [String: Any],
          let wanIP = ext["ip"] as? String, !wanIP.isEmpty
    else { return [] }

    var httpsPort: Int?
    var httpPort: Int?
    if let service = json["service"] as? [String: Any] {
      httpsPort = intValue(service["https_ext_port"]) ?? intValue(service["https_port"])
      httpPort  = intValue(service["ext_port"]) ?? intValue(service["port"])
    }
    if httpsPort == nil, let portVal = ext["https"] { httpsPort = intArray(portVal).first }
    if httpPort  == nil, let portVal = ext["http"]  { httpPort  = intArray(portVal).first }
    if httpsPort == nil { httpsPort = 5001 }
    if httpPort  == nil { httpPort  = 5000 }

    var lanIPs: [String] = []
    if let interfaces = server["interface"] as? [[String: Any]] {
      for iface in interfaces {
        if let ip = iface["ip"] as? String, !ip.isEmpty { lanIPs.append(ip) }
      }
    }

    var candidates: [Candidate] = []
    func addDirect(_ urlStr: String) {
      if let url = URL(string: urlStr) { candidates.append(Candidate(url: url, requiresTunnelCookie: false)) }
    }

    // LAN IPs: HTTP only — TLS cert is issued for the DDNS name (e.g. kestreltak.synology.me),
    // not raw IPs. HTTPS to a bare LAN IP always fails cert validation, wasting ~4s per candidate.
    for ip in lanIPs {
      if let p = httpPort { addDirect("http://\(ip):\(p)") }
      // HTTPS to raw LAN IPs always fails cert (cert is for DDNS name not IP)
    }
    // WAN: HTTPS only — cert is valid for the DDNS hostname assigned by Synology.
    // HTTP to a public IP is blocked by ATS (-1022) and would send credentials in plaintext.
    if let p = httpsPort { addDirect("https://\(wanIP):\(p)") }

    // Relay candidates — Synology's tunnel infrastructure, no port forwarding needed.
    // Appended last; only tried when all direct connections fail.
    if let relayURL = try? await resolveRelay(id: bareID, httpsPort: httpsPort, httpPort: httpPort) {
      candidates.append(relayURL)
    }

    qcLog.info("resolveCandidates: \(candidates.count) candidates: \(candidates.map { "\($0.url) tunnel=\($0.requiresTunnelCookie)" }.joined(separator: ", "))")
    return candidates
  }

  /// Compatibility shim — returns URL strings for callers that don't need relay.
  static func resolve(id: String) async throws -> [String] {
    return try await resolveCandidates(id: id).map { $0.url.absoluteString }
  }

  /// Returns a single WAN address for the QuickConnect sheet — one result, no picker.
  /// Picks the WAN (non-LAN) IP with the requested scheme. Falls back to any matching scheme.
  static func resolveWAN(id: String, useHTTPS: Bool) async throws -> String? {
    let all = try await resolve(id: id)
    let scheme = useHTTPS ? "https" : "http"
    let wan = all.first { url in
      guard url.hasPrefix(scheme), let host = URL(string: url)?.host else { return false }
      return !host.hasPrefix("192.168.") && !host.hasPrefix("10.") &&
             !host.hasPrefix("172.") && host != "localhost" && host != "127.0.0.1"
    }
    return wan ?? all.first(where: { $0.hasPrefix(scheme) })
  }

  // MARK: Private

  /// Requests a relay tunnel from Synology's infrastructure and returns a tunnel candidate.
  /// Uses the `request_tunnel` command; relay URL requires `Cookie: type=tunnel` on every request.
  private static func resolveRelay(id: String, httpsPort: Int?, httpPort: Int?) async throws -> Candidate? {
    let json = try await queryCommand("request_tunnel", id: id)
    guard let service = json["service"] as? [String: Any] else { return nil }

    // Prefer the relay domain name (relay_dn) over raw IP — required for TLS cert validation.
    let relayHost = (service["relay_dualstack"] as? String)
                 ?? (service["relay_dn"] as? String)
                 ?? (service["relay_ip"] as? String)
    guard let relayHost, !relayHost.isEmpty else { return nil }

    let relayPort = intValue(service["relay_port"]) ?? intValue(service["https_port"]) ?? 443
    // Synology relay tunnels speak plain HTTP — the relay handles TLS at its outer edge.
    // Sending HTTPS produces WRONG_VERSION_NUMBER. Always use http for relay candidates.
    guard let url = URL(string: "http://\(relayHost):\(relayPort)") else { return nil }
    return Candidate(url: url, requiresTunnelCookie: true)
  }

  private static func queryServerInfo(id: String) async throws -> [String: Any] {
    try await queryCommand("get_server_info", id: id)
  }

  private static func queryCommand(_ command: String, id: String) async throws -> [String: Any] {
    let url = URL(string: "https://global.quickconnect.to/Serv.php")!
    var request = URLRequest(url: url, timeoutInterval: 12)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "version": 1,
      "command": command,
      "stop_when_error": false,
      "stop_when_success": false,
      "id": "dsm_portal",
      "serverID": id,
    ])
    let (data, _) = try await URLSession.shared.data(for: request)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private static func intValue(_ val: Any?) -> Int? {
    guard let val else { return nil }
    if let i = val as? Int    { return i > 0 ? i : nil }
    if let s = val as? String { return Int(s).flatMap { $0 > 0 ? $0 : nil } }
    return nil
  }

  private static func intArray(_ val: Any) -> [Int] {
    if let i = val as? Int       { return i > 0 ? [i] : [] }
    if let a = val as? [Int]     { return a.filter { $0 > 0 } }
    if let a = val as? [String]  { return a.compactMap(Int.init).filter { $0 > 0 } }
    if let s = val as? String, let i = Int(s), i > 0 { return [i] }
    return []
  }
}
