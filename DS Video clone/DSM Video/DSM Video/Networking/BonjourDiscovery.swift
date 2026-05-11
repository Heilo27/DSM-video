import Foundation
import Network

/// Scans the local network for DSVideoServer instances advertised via Bonjour (_dsvideo._tcp).
@MainActor
@Observable
final class BonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {

  struct DiscoveredServer: Identifiable, Equatable {
    let id: String  // host:port
    let name: String
    let host: String
    let port: Int

    var baseURL: String { "http://\(host):\(port)" }
  }

  private(set) var servers: [DiscoveredServer] = []
  private(set) var isScanning: Bool = false

  private var browser: NetServiceBrowser?
  // Track pending resolves by name — no NetService stored after didFind
  private var resolvingNames: Set<String> = []

  func startScan() {
    guard !isScanning else { return }
    servers = []
    resolvingNames = []
    isScanning = true

    let b = NetServiceBrowser()
    b.delegate = self
    b.searchForServices(ofType: "_dsvideo._tcp.", inDomain: "local.")
    browser = b
  }

  func stopScan() {
    browser?.stop()
    browser = nil
    resolvingNames = []
    isScanning = false
  }

  // MARK: - NetServiceBrowserDelegate

  nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    // Extract all values from NetService on this thread before any Task hop
    let name = service.name
    service.delegate = self
    service.resolve(withTimeout: 5)
    Task { @MainActor in self.resolvingNames.insert(name) }
  }

  nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    let name = service.name
    Task { @MainActor in
      self.servers.removeAll { $0.name == name }
      self.resolvingNames.remove(name)
    }
  }

  nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
    Task { @MainActor in self.isScanning = false }
  }

  nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    Task { @MainActor in self.isScanning = false }
  }

  // MARK: - NetServiceDelegate

  nonisolated func netServiceDidResolveAddress(_ service: NetService) {
    // Extract ALL value types here — nothing from service crosses into the Task
    let name = service.name
    let port = service.port > 0 ? service.port : 8090
    let addresses = service.addresses ?? []
    let hostnameFallback = service.hostName?
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))

    // Resolve IPv4 address from socket data on this thread
    var resolvedHost: String?
    for addressData in addresses {
      var storage = sockaddr_storage()
      (addressData as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)
      guard storage.ss_family == UInt8(AF_INET) else { continue }
      var addr4 = withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
      }
      var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      inet_ntop(AF_INET, &addr4.sin_addr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
      let candidate = String(cString: hostBuf)
      if !candidate.isEmpty && candidate != "0.0.0.0" {
        resolvedHost = candidate
        break
      }
    }

    if resolvedHost == nil || resolvedHost == "0.0.0.0" {
      resolvedHost = hostnameFallback
    }

    guard let host = resolvedHost, !host.isEmpty, host != "0.0.0.0" else { return }

    Task { @MainActor in
      self.resolvingNames.remove(name)
      let server = DiscoveredServer(id: "\(host):\(port)", name: name, host: host, port: port)
      if !self.servers.contains(server) {
        self.servers.append(server)
      }
    }
  }

  nonisolated func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
    let name = service.name
    Task { @MainActor in self.resolvingNames.remove(name) }
  }
}
