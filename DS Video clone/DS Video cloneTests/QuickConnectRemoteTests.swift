import Foundation
import Testing
@testable import DSM_Video

// Remote sign-in through a QuickConnect ID failed with "Secure connection failed" on cellular
// (2026-10-21). Both remote candidates were wrong: WAN-direct took service.https_port, which is
// the relay's 443, and the relay was opened for the plain-HTTP portal but spoken to over https.
// The responses below are the live Serv.php answers for that NAS, trimmed to the read fields.

@Suite("QuickConnect remote candidates")
@MainActor
struct QuickConnectRemoteTests {
  private static let serverInfo: [String: Any] = [
    "errno": 0,
    "server": [
      "ddns": "DSMvideo.synology.me", "fqdn": "NULL",
      "external": ["ip": "96.253.99.70", "ipv6": "::"],
      "interface": [["ip": "192.168.50.145"], ["ip": "192.168.50.148"]],
    ],
    "service": ["port": 5000, "ext_port": 0, "https_ip": "89.187.185.92", "https_port": 443],
  ]
  private static let tunnel: [String: Any] = [
    "service": ["relay_dn": "synr-us6.PRIMEAUNAS.direct.quickconnect.to", "relay_port": 29326,
                "https_port": 443],
  ]

  private func candidates() async throws -> [String] {
    try await QuickConnectResolver.resolveCandidates(id: "primeaunas") { command, _ in
      command == "request_tunnel" ? Self.tunnel : Self.serverInfo
    }.map(\.url.absoluteString)
  }

  /// Red if: the WAN-direct candidate takes the relay's https_port (443) instead of DSM's 5001.
  @Test func wanDirectUsesDSMHTTPSPortOnDDNSName() async throws {
    let urls = try await candidates()
    #expect(urls.contains("https://DSMvideo.synology.me:5001"))
    #expect(!urls.contains { $0.hasSuffix(":443") })
  }

  /// Red if: LAN candidates stop being plain HTTP on DSM's HTTP port.
  @Test func lanCandidatesStayHTTP() async throws {
    let urls = try await candidates()
    #expect(urls.prefix(2) == ["http://192.168.50.145:5000", "http://192.168.50.148:5000"])
  }

  /// Red if: the relay is opened for the plain-HTTP portal while the app speaks https to it.
  @Test func relayIsRequestedForTheHTTPSPortal() {
    #expect(QuickConnectResolver.portalService(for: "request_tunnel") == "dsm_portal_https")
    #expect(QuickConnectResolver.portalService(for: "get_server_info") == "dsm_portal")
  }
}
