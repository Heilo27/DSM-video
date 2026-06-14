import Foundation
import Network

/// Scans the local network for DSVideoServer instances advertised via Bonjour (_dsvideo._tcp).
/// Uses NWBrowser (iOS 13+) — replaces the deprecated NetServiceBrowser/NetService APIs.
@MainActor
@Observable
final class BonjourDiscovery {

  struct DiscoveredServer: Identifiable, Equatable {
    let id: String  // host:port
    let name: String
    let host: String
    let port: Int

    var baseURL: String { "http://\(host):\(port)" }
  }

  private(set) var servers: [DiscoveredServer] = []
  private(set) var isScanning: Bool = false

  private var browser: NWBrowser?

  func startScan() {
    guard !isScanning else { return }
    servers = []
    isScanning = true

    let params = NWParameters()
    params.includePeerToPeer = true
    let b = NWBrowser(for: .bonjour(type: "_dsvideo._tcp.", domain: "local."), using: params)

    b.stateUpdateHandler = { [weak self] state in
      Task { @MainActor [weak self] in
        switch state {
        case .ready: break
        case .failed, .cancelled: self?.isScanning = false
        default: break
        }
      }
    }

    b.browseResultsChangedHandler = { [weak self] results, changes in
      Task { @MainActor [weak self] in
        guard let self else { return }
        for change in changes {
          switch change {
          case .added(let result):
            self.resolveEndpoint(result.endpoint)
          case .removed(let result):
            if case .service(let name, _, _, _) = result.endpoint {
              self.servers.removeAll { $0.name == name }
            }
          default: break
          }
        }
      }
    }

    b.start(queue: .main)
    browser = b
  }

  func stopScan() {
    browser?.cancel()
    browser = nil
    servers = []
    isScanning = false
  }

  private func resolveEndpoint(_ endpoint: NWEndpoint) {
    guard case .service(let name, let type, let domain, _) = endpoint else { return }
    let connection = NWConnection(
      to: .service(name: name, type: type, domain: domain, interface: nil),
      using: .tcp
    )
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if case .ready = state, let inner = connection.currentPath?.remoteEndpoint,
           case .hostPort(let host, let port) = inner {
          let hostStr: String
          switch host {
          case .ipv4(let addr):
            // addr.rawValue is Data; take a pointer to its actual bytes via
            // withUnsafeBytes rather than &Data (which points at the struct, not
            // the buffer — the warning was flagging undefined behavior).
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            addr.rawValue.withUnsafeBytes { raw in
              _ = inet_ntop(AF_INET, raw.baseAddress, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            hostStr = String(cString: buf)
          case .ipv6(let addr):
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            addr.rawValue.withUnsafeBytes { raw in
              _ = inet_ntop(AF_INET6, raw.baseAddress, &buf, socklen_t(INET6_ADDRSTRLEN))
            }
            hostStr = String(cString: buf)
          case .name(let n, _):
            hostStr = n.trimmingCharacters(in: CharacterSet(charactersIn: "."))
          @unknown default:
            connection.cancel(); return
          }
          let portInt = Int(port.rawValue) > 0 ? Int(port.rawValue) : 5000
          guard !hostStr.isEmpty, hostStr != "0.0.0.0" else { connection.cancel(); return }
          // Guard against stale resolution completing after stopScan() was called.
          guard self.isScanning else { connection.cancel(); return }
          let server = DiscoveredServer(id: "\(hostStr):\(portInt)", name: name, host: hostStr, port: portInt)
          if !self.servers.contains(server) { self.servers.append(server) }
          connection.cancel()
        } else if case .failed = state {
          connection.cancel()
        }
      }
    }
    connection.start(queue: .main)
  }
}
