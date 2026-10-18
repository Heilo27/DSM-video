import Foundation
import Network

/// Scans the local network for DSVideoServer instances advertised via Bonjour (_dsvideo._tcp).
/// Uses NWBrowser (iOS 13+) — replaces the deprecated NetServiceBrowser/NetService APIs.
///
/// A scan always ends in a state the screen can say something about (`status`):
///   - TASK-950 (FR-113): a browse that finds nothing never says so; NWBrowser just stays
///     `.ready`. The spinner used to run for as long as the screen was open. After
///     `noResultsTimeout` the scan window closes and `status` becomes `.noneFound`.
///   - TASK-949: with Local Network access denied, NWBrowser goes `.waiting` with a DNS
///     PolicyDenied error (TN3179) and still reports nothing. That state was ignored, so the
///     spinner ran on with no hint why. It is now `.denied`, which names the permission.
///
/// The browser keeps running after the window closes: a server that comes up late still appears,
/// and a permission granted in Settings moves the browser back to `.ready`.
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

  enum Status: Equatable {
    case idle       // no scan started
    case scanning   // scan window open, nothing found yet
    case found      // at least one server
    case noneFound  // window closed with nothing found; not an error (FR-113)
    case denied     // Local Network access is off (TASK-949)
  }

  /// How long a scan may find nothing before it is reported as `.noneFound`. A NAS on the same
  /// network answers in well under a second; 8 s covers a slow Wi-Fi join.
  static let defaultNoResultsTimeout: Duration = .seconds(8)

  /// What `.noneFound` says, on iOS and tvOS. Not an error (FR-113): manual entry is right there.
  static let noneFoundMessage = "No servers found on your network."

  private(set) var servers: [DiscoveredServer] = []
  /// True while the scan window is open: the spinner. False once the timeout fires, access is
  /// denied, or the browser fails.
  private(set) var isScanning: Bool = false
  private(set) var isDenied: Bool = false
  /// Set when a started scan's window closed (timeout or failure), so `.idle` and `.noneFound`
  /// stay distinct.
  private var windowClosed: Bool = false

  var status: Status {
    if isDenied { return .denied }
    if !servers.isEmpty { return .found }
    if isScanning { return .scanning }
    return windowClosed ? .noneFound : .idle
  }

  private let serviceType: String
  private let noResultsTimeout: Duration
  private var browser: NWBrowser?
  private var windowTask: Task<Void, Never>?

  /// `serviceType` is injectable so a test can browse a type nothing advertises; the app always
  /// uses the default.
  init(serviceType: String = "_dsvideo._tcp.",
       noResultsTimeout: Duration = BonjourDiscovery.defaultNoResultsTimeout) {
    self.serviceType = serviceType
    self.noResultsTimeout = noResultsTimeout
  }

  func startScan() {
    guard browser == nil else { return }
    servers = []
    isDenied = false
    windowClosed = false
    isScanning = true

    let params = NWParameters()
    params.includePeerToPeer = true
    let b = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: params)

    b.stateUpdateHandler = { [weak self] state in
      Task { @MainActor [weak self] in
        self?.handleBrowserState(state)
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
    armWindow()
  }

  func stopScan() {
    windowTask?.cancel()
    windowTask = nil
    browser?.cancel()
    browser = nil
    servers = []
    isScanning = false
    isDenied = false
    windowClosed = false
  }

  /// Applies one NWBrowser state change. Internal so tests can drive the states the simulator
  /// never produces (it does not enforce Local Network privacy).
  func handleBrowserState(_ state: NWBrowser.State) {
    guard browser != nil else { return }  // a late callback after stopScan()
    switch state {
    case .ready:
      // Access granted after a denial (the user turned it on in Settings): scan again.
      if isDenied {
        isDenied = false
        isScanning = true
        armWindow()
      }
    case .waiting(let error):
      if LocalNetworkPermission.isPolicyDenied(error) {
        isDenied = true
        isScanning = false
        windowTask?.cancel()
      }
      // Any other wait (no network yet) is left to the window timeout.
    case .failed(let error):
      windowTask?.cancel()
      browser?.cancel()
      browser = nil
      isScanning = false
      if LocalNetworkPermission.isPolicyDenied(error) {
        isDenied = true
      } else {
        windowClosed = true
      }
    default:
      break
    }
  }

  /// Closes the scan window after `noResultsTimeout`. Found servers stay listed; the spinner
  /// stops either way.
  private func armWindow() {
    windowTask?.cancel()
    let timeout = noResultsTimeout
    windowTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled, let self, self.isScanning else { return }
      self.isScanning = false
      self.windowClosed = true
    }
  }

  private func resolveEndpoint(_ endpoint: NWEndpoint) {
    guard case .service(let name, let type, let domain, _) = endpoint else { return }
    let connection = NWConnection(
      to: .service(name: name, type: type, domain: domain, interface: nil),
      using: .tcp
    )
    // TASK-808: an endpoint stuck in .preparing/.waiting was never cancelled until
    // stopScan(), leaking the NWConnection for the scan's lifetime. Arm a hard timeout
    // that cancels the connection regardless of the state it's stuck in.
    let timeoutTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      connection.cancel()
    }

    connection.stateUpdateHandler = { [weak self] state in
      // Any terminal-ish state means we're done with this connection — stop the timer.
      switch state {
      case .ready, .failed, .cancelled:
        timeoutTask.cancel()
      case .waiting:
        // Won't resolve on this path — release it now rather than waiting for timeout.
        timeoutTask.cancel()
        connection.cancel()
      default:
        break
      }
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
            hostStr = Self.string(fromNullTerminated: buf)
          case .ipv6(let addr):
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            addr.rawValue.withUnsafeBytes { raw in
              _ = inet_ntop(AF_INET6, raw.baseAddress, &buf, socklen_t(INET6_ADDRSTRLEN))
            }
            hostStr = Self.string(fromNullTerminated: buf)
          case .name(let n, _):
            hostStr = n.trimmingCharacters(in: CharacterSet(charactersIn: "."))
          @unknown default:
            connection.cancel(); return
          }
          let portInt = Int(port.rawValue) > 0 ? Int(port.rawValue) : 5000
          guard !hostStr.isEmpty, hostStr != "0.0.0.0" else { connection.cancel(); return }
          // Guard against stale resolution completing after stopScan() was called. Not
          // isScanning: a server resolved after the window closed is still a real result.
          guard self.browser != nil else { connection.cancel(); return }
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

  /// Decodes a null-terminated C string buffer without `String(cString:)`.
  ///
  /// That initialiser is deprecated: it reads to the first null and the compiler can no
  /// longer verify the buffer is terminated. `inet_ntop` does terminate its output, so we
  /// truncate at the null ourselves and decode the prefix — which is exactly what the
  /// deprecation note prescribes, and is safe even if the buffer were somehow unterminated.
  private static func string(fromNullTerminated buf: [CChar]) -> String {
    let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

// MARK: - Local Network permission (TASK-949)

/// The one home for recognising a Local Network denial and for the words that name it.
///
/// iOS (and tvOS) gate every LAN connection behind the Local Network permission. When it is off,
/// nothing says so directly (TN3179): Bonjour browsing waits with a DNS PolicyDenied error, and a
/// connection to a LAN address fails with -1009 `.notConnectedToInternet` whose path reports
/// `.localNetworkDenied`. Both used to read as "searching…" forever or "No network connection.",
/// which sends the user to debug a network that works.
enum LocalNetworkPermission {
  /// Shown wherever the denial stops something: discovery, sign-in, a request mid-session.
  nonisolated static let deniedMessage =
    "DSM Video doesn't have Local Network access, so it can't reach servers on your network. Turn on Local Network for DSM Video in Settings."

  /// The one-line banner form of `deniedMessage`.
  nonisolated static let bannerMessage = "Local Network access is off for DSM Video"

  /// NWBrowser's denial: `.waiting` / `.failed` with `kDNSServiceErr_PolicyDenied`.
  nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
    if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
    return false
  }

  /// URLSession's denial: -1009 whose path was refused for Local Network privacy. Any other
  /// -1009 really is a device with no network.
  nonisolated static func isDenied(code: URLError.Code, unsatisfiedReason: NWPath.UnsatisfiedReason?) -> Bool {
    code == .notConnectedToInternet && unsatisfiedReason == .localNetworkDenied
  }

  /// Reads the path URLSession attaches to a transport error (`_NSURLErrorNWPathKey`, TN3179).
  nonisolated static func isDenied(_ error: URLError) -> Bool {
    let path = error.errorUserInfo["_NSURLErrorNWPathKey"] as? NWPath
    return isDenied(code: error.code, unsatisfiedReason: path?.unsatisfiedReason)
  }
}
