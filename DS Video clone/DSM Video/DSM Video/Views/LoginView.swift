import SwiftUI
import os.log

private let qcLog = Logger(subsystem: "com.dsm.qc", category: "resolver")

struct LoginView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  #if !os(tvOS)
  @State private var showPairing: Bool = false
  @State private var showSettings: Bool = false
  @State private var showAbout: Bool = false
  @State private var showBonjourScan: Bool = false
  #endif
  @State private var showQuickConnect: Bool = false
  @State private var showOfflineDownloads: Bool = false
  // Tracked so SwiftUI observes DownloadManager changes; hasDownloads reads from it (TASK-431).
  @State private var downloadManager = DownloadManager.shared
  private var hasDownloads: Bool { !downloadManager.getDownloadedItems().isEmpty }

  var body: some View {
    @Bindable var appState = appState
    let passwordBinding = Binding(
      get: { appState.savedPassword },
      set: { appState.savedPassword = $0 }
    )

    ZStack {
      DSReelBrandColor.background
        .ignoresSafeArea()

      VStack(spacing: 16) {
        Spacer(minLength: 24)

        // Logomark — red circle with play triangle
        ZStack {
          Circle()
            .fill(Color.dsAccent)
            .frame(width: 80, height: 80)
          Image(systemName: "play.fill")
            .font(.system(size: 32))
            .foregroundStyle(.white)
            .offset(x: 3) // optical centering for play triangle
        }
        .accessibilityHidden(true) // "DSM Video" text label below serves the same purpose
        .padding(.bottom, 4)

        VStack(spacing: 6) {
          Text("DSM Video")
            .font(.largeTitle.weight(.semibold))
            .foregroundStyle(.white)

          Text("Your NAS, beautifully.")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
        }

        VStack(spacing: 0) {
          HStack {
            TextField("192.168.x.x or QuickConnect ID", text: $appState.baseURL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              #if !os(tvOS)
                .keyboardType(.URL)
              #endif
              .submitLabel(.next)
            Button {
              showQuickConnect = true
            } label: {
              Image(systemName: "arrow.right.circle.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("QuickConnect lookup")
            .accessibilityHint("Resolve a QuickConnect ID to a server address")
          }
          .padding(.horizontal, 12)
          #if os(tvOS)
          .frame(height: 66)
          #else
          .frame(height: 44)
          #endif

          Divider()

          HStack(spacing: 10) {
            Image(systemName: "person.fill")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            TextField("USERNAME", text: $appState.username)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .textContentType(.username)
          }
          .padding(.horizontal, 12)
          #if os(tvOS)
          .frame(height: 66)
          #else
          .frame(height: 44)
          #endif

          Divider()

          HStack(spacing: 10) {
            Image(systemName: "lock.fill")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            SecureField("PASSWORD", text: passwordBinding)
              .textContentType(.password)
              .privacySensitive()
          }
          .padding(.horizontal, 12)
          #if os(tvOS)
          .frame(height: 66)
          #else
          .frame(height: 44)
          #endif
        }
        #if os(tvOS)
        .background(Color.white)
        #else
        .background(Color.dsSurface)
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        #if os(tvOS)
        .frame(maxWidth: 600)
        #else
        .padding(.horizontal, 24)
        .frame(maxWidth: horizontalSizeClass == .regular ? 528 : .infinity)
        #endif

        #if os(tvOS)
        // tvOS: show Remember me toggle (HTTPS toggle not applicable on tvOS login flow)
        Toggle("Remember me", isOn: $appState.rememberMe)
          .tint(Color.dsAccent)
          .foregroundStyle(.white.opacity(0.85))
          .frame(maxWidth: 600)
        #else
        VStack(alignment: .leading, spacing: 12) {
          Toggle(appState.useHTTPS ? "HTTPS: On" : "HTTPS: Off", isOn: $appState.useHTTPS)
          Toggle(appState.rememberMe ? "Remember me: On" : "Remember me: Off", isOn: $appState.rememberMe)
        }
        .tint(.white)
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 24)
        .frame(maxWidth: horizontalSizeClass == .regular ? 528 : .infinity)
        #endif

        Button {
          Task { await appState.login() }
        } label: {
          if appState.isLoggingIn {
            ProgressView("Connecting")
              .tint(DSReelBrandColor.background)
              .frame(maxWidth: .infinity, minHeight: 52)
          } else {
            Text("Connect")
              .font(.headline)
              .frame(maxWidth: .infinity, minHeight: 52)
          }
        }
        #if os(tvOS)
        .background(Color.white)
        #else
        .background(Color(.systemBackground))
        #endif
        .foregroundStyle(DSReelBrandColor.background)
        .clipShape(Capsule())
        #if os(tvOS)
        .frame(maxWidth: 600)
        #else
        .padding(.horizontal, 24)
        .frame(maxWidth: horizontalSizeClass == .regular ? 528 : .infinity)
        #endif
        .disabled(appState.isLoggingIn || (appState.isOffline && QuickConnectResolver.extractBareID(from: appState.baseURL) != nil))
        .accessibilityLabel(appState.isLoggingIn ? "Connecting, please wait" : "Connect")

        if appState.isOffline && QuickConnectResolver.extractBareID(from: appState.baseURL) != nil {
          Text("No internet connection (QuickConnect requires internet)")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 24)
        } else if let err = appState.loginError {
          Text(err)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 24)
        }

        #if !os(tvOS)
        Button {
          showQuickConnect = true
        } label: {
          Text("Or connect via QuickConnect")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        #endif

        #if !os(tvOS)
        Button {
          showBonjourScan = true
        } label: {
          Label("Find Server on Network", systemImage: "network")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)

        Button {
          showPairing = true
        } label: {
          Label("Pair with Apple TV", systemImage: "appletv")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)

        Link(destination: URL(string: "https://heiloprojects.com/dsmvideo/#server") ?? URL(string: "https://heiloprojects.com")!) {
          Label("Get DSVideoServer for your NAS", systemImage: "server.rack")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.top, 4)

        if hasDownloads {
          Button {
            showOfflineDownloads = true
          } label: {
            Label("Watch Downloaded Videos", systemImage: "arrow.down.circle.fill")
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.75))
          }
          .buttonStyle(.plain)
          .padding(.top, 4)
          .accessibilityHint("Access videos saved to this device for offline viewing")
        }
        #endif

        Spacer(minLength: 24)

        #if !os(tvOS)
        HStack {
          Button { showSettings = true } label: {
            Image(systemName: "gearshape")
              .frame(width: 44, height: 44)
          }
          .accessibilityLabel("Settings")
          Spacer()
          Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.75))
          Spacer()
          Button { showAbout = true } label: {
            Image(systemName: "info.circle")
              .frame(width: 44, height: 44)
          }
          .accessibilityLabel("About DSM Video")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        #endif
      }
      #if !os(tvOS)
      .sheet(isPresented: $showPairing) {
        PairingCodeView()
          .environment(appState)
          .presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $showSettings) {
        NavigationStack {
          SettingsView()
            .environment(appState)
        }
      }
      .sheet(isPresented: $showAbout) {
        AboutView()
      }
      .sheet(isPresented: $showBonjourScan) {
        BonjourScanSheet { selectedURL in
          appState.baseURL = selectedURL
        }
      }
      #endif
      .fullScreenCover(isPresented: $showOfflineDownloads) {
        NavigationStack {
          DownloadsView()
            .environment(appState)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Done") { showOfflineDownloads = false }
              }
            }
        }
      }
      .sheet(isPresented: $showQuickConnect) {
        QuickConnectSheet(useHTTPS: appState.useHTTPS) { quickConnectID in
          // Keep the bare QuickConnect ID in the address field — login() resolves it.
          appState.baseURL = quickConnectID
        }
      }
    }
  }
}

// MARK: - Bonjour Scan Sheet

#if !os(tvOS)
private struct BonjourScanSheet: View {
  let onSelect: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var discovery = BonjourDiscovery()

  var body: some View {
    NavigationStack {
      Group {
        if discovery.servers.isEmpty {
          VStack(spacing: 20) {
            Spacer()
            if discovery.isScanning {
              ProgressView("Scanning your network…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
              ContentUnavailableView(
                "No Servers Found",
                systemImage: "network.slash",
                description: Text("Make sure DSVideoServer is running on your NAS and both devices are on the same network.")
              )
              Button("Scan Again") { discovery.startScan() }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
          }
        } else {
          List(discovery.servers) { server in
            Button {
              onSelect(server.baseURL)
              dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Label(server.name, systemImage: "server.rack")
                  .font(.headline)
                Text(server.baseURL)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .foregroundStyle(.primary)
          }
        }
      }
      .navigationTitle("Find Server")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        if discovery.isScanning {
          ToolbarItem(placement: .status) {
            ProgressView().scaleEffect(0.8)
          }
        }
      }
      .onAppear { discovery.startScan() }
      .onDisappear { discovery.stopScan() }
    }
  }
}
#endif

// MARK: - About View

private struct AboutView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Spacer()

        Image(systemName: "play.rectangle.fill")
          .font(.system(size: 64))
          .foregroundStyle(Color.dsAccent)

        VStack(spacing: 8) {
          Text("DSM Video")
            .font(.title.bold())
          Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Text("Browse and stream your personal video library directly from your home server.")
          .font(.body)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 32)

        Spacer()
      }
      .navigationTitle("About")
      #if !os(tvOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

// MARK: - QuickConnect Sheet

private struct QuickConnectSheet: View {
  let useHTTPS: Bool
  let onSelect: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var quickConnectID: String = ""
  @State private var isResolving: Bool = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("e.g. my-nas", text: $quickConnectID)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit { Task { await resolve() } }
        } header: {
          Text("QuickConnect ID")
        } footer: {
          Text("Enter the QuickConnect ID from your DSM control panel. The \(useHTTPS ? "secure (HTTPS)" : "standard (HTTP)") remote address will be used based on your HTTPS setting.")
        }

        if let error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .font(.footnote)
          }
        }
      }
      .navigationTitle("QuickConnect")
      #if !os(tvOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Find") {
            Task { await resolve() }
          }
          .disabled(quickConnectID.trimmingCharacters(in: .whitespaces).isEmpty || isResolving)
        }
      }
      .overlay {
        if isResolving {
          ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            ProgressView("Resolving…")
              .padding(20)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          }
        }
      }
    }
  }

  private func resolve() async {
    let id = quickConnectID.trimmingCharacters(in: .whitespaces)
    guard !id.isEmpty else { return }

    isResolving = true
    error = nil
    defer { isResolving = false }

    do {
      // Resolve the WAN address now and pass it directly to the address field so
      // login() can connect immediately without a second QuickConnect lookup (TASK-422).
      guard let resolvedURL = try await QuickConnectResolver.resolveWAN(id: id, useHTTPS: useHTTPS) else {
        error = "Couldn't find \"\(id)\". Check the ID and try again."
        return
      }
      onSelect(resolvedURL)
      dismiss()
    } catch {
      self.error = "Network error. Check your connection and try again."
    }
  }
}

// MARK: - QuickConnect Resolver

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

    // LAN IPs: HTTP first — TLS cert is issued for the DDNS name, not raw IPs,
    // so HTTPS to a bare LAN IP will always fail cert validation.
    for ip in lanIPs {
      if let p = httpPort  { addDirect("http://\(ip):\(p)") }
      if let p = httpsPort { addDirect("https://\(ip):\(p)") }
    }
    // WAN: HTTPS first (cert is valid for DDNS hostname), HTTP fallback for ATS-exempt setups.
    if let p = httpsPort { addDirect("https://\(wanIP):\(p)") }
    if let p = httpPort  { addDirect("http://\(wanIP):\(p)") }

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
    let scheme = httpsPort != nil ? "https" : "http"
    guard let url = URL(string: "\(scheme)://\(relayHost):\(relayPort)") else { return nil }
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

#Preview {
  LoginView()
    .environment(AppState())
}
