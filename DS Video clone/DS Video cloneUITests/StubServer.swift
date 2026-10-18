import Foundation
import Network
import XCTest

/// A minimal loopback HTTP/1.1 server for the UI suite (TASK-969).
///
/// WHY: the app's profile behaviour (picker, auto-enter, the `X-DSVideo-Profile` header) is
/// decided by what the SERVER says. Demo mode has no server, and the live NAS makes the suite
/// flaky and its failures meaningless (rule 5 in UITestSupport). A canned loopback server gives
/// deterministic server answers AND lets a test read back what the app actually sent.
///
/// Scope: one request per connection (`Connection: close`), canned JSON per path, a request log
/// with headers. It is not a general HTTP server; query strings are logged but not routed on.
final class StubServer: @unchecked Sendable {

  /// One request as the app sent it. Header names are lowercased (HTTP names are case-insensitive).
  struct Request: Sendable {
    let method: String
    let path: String
    let query: String
    let headers: [String: String]
    func header(_ name: String) -> String? { headers[name.lowercased()] }
  }

  struct Response: Sendable {
    var status: Int
    var json: String
    init(_ json: String, status: Int = 200) { self.json = json; self.status = status }
  }

  private let queue = DispatchQueue(label: "StubServer")
  private let lock = NSLock()
  private var listener: NWListener?
  private var routes: [String: Response] = [:]
  private var log: [Request] = []
  private var connections: [NWConnection] = []
  private var boundPort: UInt16 = 0

  /// Starts listening on 127.0.0.1 with a random free port. Throws if it cannot bind in 5s.
  init(routes: [String: Response] = [:]) throws {
    self.routes = routes
    let params = NWParameters.tcp
    params.requiredInterfaceType = .loopback
    let listener = try NWListener(using: params, on: .any)
    self.listener = listener

    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state, let port = listener.port?.rawValue {
        self?.lock.lock(); self?.boundPort = port; self?.lock.unlock()
        ready.signal()
      } else if case .failed = state {
        ready.signal()
      }
    }
    listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    guard port != 0 else {
      listener.cancel()
      throw NSError(domain: "StubServer", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "StubServer could not bind a loopback port"])
    }
  }

  deinit { stop() }

  var port: UInt16 { lock.lock(); defer { lock.unlock() }; return boundPort }
  var baseURL: String { "http://127.0.0.1:\(port)" }

  /// Replaces (or adds) the canned answer for `path` (no query string).
  func setRoute(_ path: String, _ response: Response) {
    lock.lock(); routes[path] = response; lock.unlock()
  }

  /// Every request received so far, oldest first.
  var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }

  func requests(path: String) -> [Request] { requests.filter { $0.path == path } }

  /// Stops listening and drops every open connection. The port is gone afterwards, so the app
  /// sees connection-refused: this is how a row simulates "the NAS is unreachable".
  func stop() {
    lock.lock()
    let l = listener; listener = nil
    let open = connections; connections = []
    lock.unlock()
    l?.cancel()
    open.forEach { $0.cancel() }
  }

  // MARK: - Connection handling

  private func accept(_ conn: NWConnection) {
    lock.lock(); connections.append(conn); lock.unlock()
    conn.start(queue: queue)
    receive(conn, buffer: Data())
  }

  private func receive(_ conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buf = buffer
      if let data { buf.append(data) }
      if let req = Self.parse(buf) {
        self.respond(to: req, on: conn)
      } else if isComplete || error != nil {
        conn.cancel()
      } else {
        self.receive(conn, buffer: buf)
      }
    }
  }

  /// Returns a request once the header block AND the declared body have fully arrived.
  private static func parse(_ data: Data) -> Request? {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)),
          let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    let bodyLength = Int(headers["content-length"] ?? "") ?? 0
    guard data.count - end.upperBound >= bodyLength else { return nil }
    let target = String(requestLine[1])
    let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    return Request(method: String(requestLine[0]), path: String(parts[0]),
                   query: parts.count > 1 ? String(parts[1]) : "", headers: headers)
  }

  private func respond(to req: Request, on conn: NWConnection) {
    lock.lock()
    log.append(req)
    let canned = routes[req.path]
    lock.unlock()

    let response = canned ?? Response(#"{"error":"stub: no route"}"#, status: 404)
    let body = Data(response.json.utf8)
    let head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Stub")\r\n"
      + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var out = Data(head.utf8)
    out.append(body)
    conn.send(content: out, contentContext: .finalMessage, isComplete: true,
              completion: .contentProcessed { _ in conn.cancel() })
  }
}

// MARK: - Canned server data and launch helper

/// A profile as the stub serves it (the `/api/v1/profiles` row shape).
struct StubProfile {
  let id: String
  let name: String
  var maxAgeLevel = 4
  var hasPin = false
  var isOwner = false
  var kids = false

  var json: String {
    #"{"id":"\#(id)","name":"\#(name)","avatar":"star","maxAgeLevel":\#(maxAgeLevel),"#
      + #""hasPin":\#(hasPin),"isOwner":\#(isOwner),"kids":\#(kids),"offersCollections":\#(kids)}"#
  }
}

extension StubServer {

  /// A server that answers every route the home screen needs, for the given profile list.
  /// `activeProfileId` nil = the account has chosen no profile (what the picker keys off).
  static func withProfiles(_ profiles: [StubProfile], activeProfileId: String? = nil) throws -> StubServer {
    let server = try StubServer()
    server.setProfiles(profiles, activeProfileId: activeProfileId)
    let movie = #"{"id":"m1","type":"movie","title":"Stub Movie","year":2020,"durationSeconds":7200,"#
      + #""addedAt":"2026-01-01T00:00:00Z","ageLevel":1,"libraryId":"lib1","changeSeq":1}"#
    server.setRoute("/api/v1/version",
      Response(#"{"serverVersion":"9.9.9","minClientVersion":"0.0.0","capabilities":["profiles"]}"#))
    server.setRoute("/api/v1/profiles/age-levels", Response(
      #"{"unratedLevel":4,"levels":["#
        + #"{"level":1,"key":"little","label":"Little Kids","movie":["G"],"tv":["TV-Y"]},"#
        + #"{"level":2,"key":"older","label":"Older Kids","movie":["PG"],"tv":["TV-PG"]},"#
        + #"{"level":3,"key":"teens","label":"Teens","movie":["PG-13"],"tv":["TV-14"]},"#
        + #"{"level":4,"key":"adult","label":"Adult","movie":["R"],"tv":["TV-MA"]}]}"#))
    server.setRoute("/api/v1/libraries",
      Response(#"{"libraries":[{"id":"lib1","title":"Movies","kind":"movie"}]}"#))
    server.setRoute("/api/v1/items", Response(#"{"total":1,"items":[\#(movie)]}"#))
    server.setRoute("/api/v1/just-added", Response(#"{"items":[\#(movie)]}"#))
    server.setRoute("/api/v1/suggested", Response(#"{"genre":"","items":[]}"#))
    server.setRoute("/api/v1/watchlist", Response(#"{"items":[]}"#))
    server.setRoute("/api/v1/collections", Response(#"{"collections":[]}"#))
    server.setRoute("/api/v1/progress/all", Response(#"{"progress":{}}"#))
    server.setRoute("/api/v1/sync/status", Response(#"{"itemSeq":1,"progressSeq":0,"totalItems":1}"#))
    server.setRoute("/api/v1/sync/heartbeat",
      Response(#"{"itemSeq":1,"progressSeq":0,"serverTimeMs":1790000000000}"#))
    server.setRoute("/api/v1/sync/items",
      Response(#"{"items":[\#(movie)],"nextSeq":1,"hasMore":false,"nextAfterRowid":null}"#))
    server.setRoute("/api/v1/sync/deleted", Response(#"{"deletedIds":[],"asOf":1}"#))
    return server
  }

  /// Makes the library answer "nothing here" on every route the home rails read, so the home
  /// screen lands on its empty state (restricted or generic, depending on the profile).
  func emptyLibrary() {
    setRoute("/api/v1/items", Response(#"{"total":0,"items":[]}"#))
    setRoute("/api/v1/just-added", Response(#"{"items":[]}"#))
    setRoute("/api/v1/sync/items",
      Response(#"{"items":[],"nextSeq":1,"hasMore":false,"nextAfterRowid":null}"#))
    setRoute("/api/v1/sync/status", Response(#"{"itemSeq":1,"progressSeq":0,"totalItems":0}"#))
  }

  func setProfiles(_ profiles: [StubProfile], activeProfileId: String? = nil) {
    let active = activeProfileId.map { "\"\($0)\"" } ?? "null"
    setRoute("/api/v1/profiles", Response(
      #"{"maxProfiles":5,"activeProfileId":\#(active),"unrestrictedLevel":4,"profiles":["#
        + profiles.map(\.json).joined(separator: ",") + "]}"))
  }
}

extension UITest {

  /// A JWT-shaped token (header.payload.signature, base64url payload) whose `exp` is 30 days
  /// out. `AppState.checkTokenExpiryOnLaunch` renews any token expiring within 24h, which would
  /// fire an unrouted `/auth/refresh` mid-test; 30 days keeps it quiet.
  static func stubToken(daysValid: Double = 30) -> String {
    func b64url(_ s: String) -> String {
      Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    let exp = Int(Date().addingTimeInterval(daysValid * 86_400).timeIntervalSince1970)
    return [b64url(#"{"alg":"none","typ":"JWT"}"#), b64url(#"{"sub":"stub","exp":\#(exp)}"#), "sig"]
      .joined(separator: ".")
  }

  /// Launch signed in against a loopback stub (DEBUG `-QALiveToken` / `-QALiveServer` hooks).
  /// `resetState: false` relaunches WITHOUT wiping the saved profile choice, for rows that need
  /// the app to remember something across launches.
  @MainActor
  static func launchAgainst(
    _ server: StubServer, resetState: Bool = true, extraArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    if resetState { app.launchArguments += ["-UITestResetState"] }
    app.launchArguments += ["-QALiveToken", stubToken(), "-QALiveServer", server.baseURL]
    app.launchArguments += extraArguments
    app.launch()
    return app
  }
}
