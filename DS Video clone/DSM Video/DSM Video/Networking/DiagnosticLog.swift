import Foundation
import os.log

/// On-device diagnostic log, readable from Settings on the device itself.
///
/// WHY THIS EXISTS, AND WHY IT IS NOT os.Logger
///
/// The Apple TV is the hardest device in this project to debug: it ships through App Store
/// review, it is not attached to a Mac, and the only practical way a problem gets reported is
/// Ryan photographing the screen and sending the picture. `os.Logger` writes to the unified
/// log, which is excellent on a tethered device and completely unreachable on a TV in a living
/// room. So this is a small ring buffer that renders on screen.
///
/// Every design choice below follows from "the transport is a photograph":
///
///   * Newest entries first. A photo captures one screenful; the interesting event must be in
///     it without scrolling.
///   * Bounded to `maxEntries` and persisted to disk, so a crash or relaunch does not erase
///     the evidence — the interesting failure is usually the one that just killed the screen.
///   * Timestamps are wall-clock local time, not monotonic. Ryan reads these against "I tried
///     to sign in around 9pm", not against a process clock.
///   * Messages are short and self-contained. A wrapped or truncated line in a photo is a line
///     that has to be asked about again.
///
/// PRIVACY: this is intended to be photographed and sent over chat. Nothing written here may
/// contain a password, a token, or a full auth header. `redact(_:)` exists for that, and the
/// call sites use it. Tokens are logged as a length and a 4-character prefix — enough to tell
/// "empty", "changed", and "unchanged" apart, which is all diagnosis ever needs.
///
/// Thread-safety: entries arrive from URLSession callbacks, actors, and the main thread. All
/// mutation goes through a serial queue; `entries` snapshots under that queue.
final class DiagnosticLog: @unchecked Sendable {
  static let shared = DiagnosticLog()

  /// One line in the log.
  struct Entry: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let category: Category
    let level: Level
    let message: String

    init(date: Date, category: Category, level: Level, message: String) {
      self.id = UUID()
      self.date = date
      self.category = category
      self.level = level
      self.message = message
    }
  }

  enum Level: String, Codable, Sendable {
    case info
    case warn
    case error

    /// Leading glyph. Chosen to be legible in a photo at a distance — colour alone is not
    /// enough, since the photo may be dim, angled, or taken on a warm-tinted TV.
    var symbol: String {
      switch self {
      case .info: return "•"
      case .warn: return "!"
      case .error: return "✕"
      }
    }
  }

  /// Coarse buckets, so a photo can be scanned for the relevant subsystem at a glance.
  enum Category: String, Codable, Sendable, CaseIterable {
    case auth = "AUTH"
    case network = "NET"
    case library = "LIB"
    case home = "HOME"
    case playback = "PLAY"
    case decode = "DECODE"
    case app = "APP"
  }

  /// Ring capacity. Large enough to hold a full launch-plus-login-plus-browse sequence,
  /// small enough that the persisted file stays trivial to write on every append.
  private let maxEntries = 300

  private let queue = DispatchQueue(label: "com.dsm.dsvideo.diagnosticlog")
  private var buffer: [Entry] = []
  private let fileURL: URL?

  /// Mirrors to the unified log too, so a tethered device still gets normal tooling.
  private let mirror = Logger(subsystem: "com.dsm.dsvideo", category: "Diagnostic")

  private init() {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    if let dir {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      fileURL = dir.appendingPathComponent("diagnostic-log.json")
    } else {
      fileURL = nil
    }
    loadFromDisk()
  }

  // MARK: - Writing

  func log(_ category: Category, _ level: Level, _ message: String) {
    let entry = Entry(date: Date(), category: category, level: level, message: message)
    queue.async { [weak self] in
      guard let self else { return }
      self.buffer.append(entry)
      if self.buffer.count > self.maxEntries {
        self.buffer.removeFirst(self.buffer.count - self.maxEntries)
      }
      self.persistLocked()
    }
    switch level {
    case .info: mirror.info("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
    case .warn: mirror.warning("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
    case .error: mirror.error("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
    }
  }

  func info(_ category: Category, _ message: String) { log(category, .info, message) }
  func warn(_ category: Category, _ message: String) { log(category, .warn, message) }
  func error(_ category: Category, _ message: String) { log(category, .error, message) }

  // MARK: - Reading

  /// Newest first — the order the on-screen view renders, and the order that puts the
  /// interesting event at the top of a photograph.
  var entries: [Entry] {
    queue.sync { buffer.reversed() }
  }

  func clear() {
    queue.async { [weak self] in
      guard let self else { return }
      self.buffer.removeAll()
      self.persistLocked()
    }
  }

  /// Plain-text rendering, for share/export paths that want the whole buffer as one string.
  func exportText() -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return entries.map { e in
      "\(fmt.string(from: e.date)) \(e.level.symbol) [\(e.category.rawValue)] \(e.message)"
    }.joined(separator: "\n")
  }

  // MARK: - Redaction

  /// Render a secret as a diagnosable fingerprint that is useless if disclosed.
  ///
  /// Diagnosis needs to distinguish three states — absent, present-and-changed,
  /// present-and-same — and never needs the value itself. A photograph of this screen is
  /// going to be sent over chat, so the value must not be recoverable from it.
  static func redact(_ secret: String?) -> String {
    guard let secret, !secret.isEmpty else { return "<empty>" }
    let prefix = secret.prefix(4)
    return "\(prefix)…(\(secret.count) chars)"
  }

  /// Strip credentials and tokens out of a URL before logging it.
  static func safeURL(_ url: URL?) -> String {
    guard let url else { return "<nil url>" }
    guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    comps.user = nil
    comps.password = nil
    if let items = comps.queryItems {
      comps.queryItems = items.map { item in
        let sensitive = ["token", "password", "pass", "auth", "key", "secret"]
        if sensitive.contains(where: { item.name.lowercased().contains($0) }) {
          return URLQueryItem(name: item.name, value: "<redacted>")
        }
        return item
      }
    }
    return comps.url?.absoluteString ?? url.absoluteString
  }

  // MARK: - Persistence

  /// Must be called on `queue`.
  private func persistLocked() {
    guard let fileURL else { return }
    guard let data = try? JSONEncoder().encode(buffer) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }

  private func loadFromDisk() {
    guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
    guard let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
    buffer = decoded
  }
}

/// Shorthand used at call sites.
let dlog = DiagnosticLog.shared

extension URLError.Code {
  /// Human-readable name for the log. A raw code like `-1004` means nothing in a photograph
  /// of a TV screen; "cannot connect to host" tells Ryan immediately whether to check the
  /// address, the network, or the server process.
  var diagnosticName: String {
    switch self {
    case .cannotConnectToHost: return "cannot connect to host"
    case .cannotFindHost: return "cannot find host"
    case .dnsLookupFailed: return "DNS lookup failed"
    case .timedOut: return "timed out"
    case .networkConnectionLost: return "connection lost"
    case .notConnectedToInternet: return "no internet"
    case .secureConnectionFailed: return "TLS handshake failed"
    case .serverCertificateUntrusted: return "certificate untrusted"
    case .serverCertificateHasBadDate: return "certificate expired"
    case .serverCertificateNotYetValid: return "certificate not yet valid"
    case .serverCertificateHasUnknownRoot: return "certificate unknown root"
    case .badServerResponse: return "bad server response"
    case .cancelled: return "cancelled"
    case .userAuthenticationRequired: return "auth required"
    case .resourceUnavailable: return "resource unavailable"
    case .badURL: return "bad URL"
    case .unsupportedURL: return "unsupported URL"
    default: return "URLError \(self.rawValue)"
    }
  }
}
