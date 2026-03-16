import SwiftUI

struct LoginView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  #if !os(tvOS)
  @State private var showPairing: Bool = false
  @State private var showSettings: Bool = false
  @State private var showAbout: Bool = false
  #endif
  @State private var showQuickConnect: Bool = false

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
            .fill(Color.white.opacity(0.15))
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
            .font(.system(size: 40, weight: .semibold, design: .default))
            .foregroundStyle(.white)

          Text("Your NAS, beautifully.")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
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

          TextField("Username", text: $appState.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            #if os(tvOS)
            .frame(height: 66)
            #else
            .frame(height: 44)
            #endif

          Divider()

          SecureField("Password", text: passwordBinding)
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
        .background(Color(.systemBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        #if os(tvOS)
        .frame(maxWidth: 600)
        #else
        .padding(.horizontal, 24)
        .frame(maxWidth: horizontalSizeClass == .regular ? 528 : .infinity)
        #endif

        #if !os(tvOS)
        VStack(alignment: .leading, spacing: 12) {
          Toggle("HTTPS", isOn: $appState.useHTTPS)
          Toggle("Remember me", isOn: $appState.rememberMe)
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
            ProgressView()
              .tint(DSReelBrandColor.background)
              .frame(maxWidth: .infinity, minHeight: 52)
          } else {
            Text("Login")
              .font(.system(size: 20, weight: .semibold))
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
        .disabled(appState.isLoggingIn)

        if let err = appState.loginError {
          Text(err)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 24)
        }

        #if !os(tvOS)
        Button {
          showPairing = true
        } label: {
          Label("Pair with Apple TV", systemImage: "appletv")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        #endif

        Spacer(minLength: 24)

        #if !os(tvOS)
        HStack {
          Button { showSettings = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
          Spacer()
          Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.5))
          Spacer()
          Button { showAbout = true } label: { Image(systemName: "info.circle") }
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
      #endif
      .sheet(isPresented: $showQuickConnect) {
        QuickConnectSheet { selectedURL in
          // Strip the Synology DSM port from the resolved URL.
          // normalizedBaseURL will apply the user's configured port (default 8090).
          if let url = URL(string: selectedURL), let host = url.host {
            let scheme = selectedURL.hasPrefix("https") ? "https" : "http"
            appState.baseURL = "\(scheme)://\(host)"
          } else {
            appState.baseURL = selectedURL
          }
          appState.useHTTPS = selectedURL.hasPrefix("https")
        }
      }
    }
  }
}

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

        Text("A native iOS client for Synology Video Station. Browse and stream your personal video library directly from your NAS.")
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
  let onSelect: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var quickConnectID: String = ""
  @State private var isResolving: Bool = false
  @State private var candidates: [String] = []
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("e.g. my-synology", text: $quickConnectID)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit { Task { await resolve() } }
        } header: {
          Text("QuickConnect ID")
        } footer: {
          Text("Enter the QuickConnect ID configured in your Synology DSM control panel.")
        }

        if !candidates.isEmpty {
          Section("Select Server") {
            ForEach(candidates, id: \.self) { url in
              Button {
                onSelect(url)
                dismiss()
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(url)
                      .font(.subheadline)
                      .foregroundStyle(.primary)
                    Text(url.hasPrefix("https") ? "Encrypted" : "Unencrypted")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Image(systemName: url.hasPrefix("https") ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundStyle(url.hasPrefix("https") ? .green : .orange)
                    .accessibilityLabel(url.hasPrefix("https") ? "Encrypted connection" : "Unencrypted connection")
                }
              }
            }
          }
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
    candidates = []
    defer { isResolving = false }

    do {
      let found = try await QuickConnectResolver.resolve(id: id)
      if found.isEmpty {
        error = "Couldn't find \"\(id)\". Check the ID and try again."
      } else if found.count == 1 {
        onSelect(found[0])
        dismiss()
      } else {
        candidates = found
      }
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

  /// Resolves a QuickConnect ID against Synology's relay service.
  /// Returns candidate base URLs: LAN IPs first (avoids NAT hairpin), then WAN IP.
  /// Callers should try each candidate in order and use the first that succeeds.
  static func resolve(id: String) async throws -> [String] {
    // Normalize — strip .quickconnect.to if the caller passed the full domain form
    guard let bareID = extractBareID(from: id) else { return [] }
    let json = try await queryRelay(host: "global.quickconnect.to", id: bareID)

    // Check for not-found or error
    if let errno = json["errno"] as? Int, errno != 0 { return [] }

    guard let server = json["server"] as? [String: Any],
          let ext = server["external"] as? [String: Any],
          let wanIP = ext["ip"] as? String, !wanIP.isEmpty
    else { return [] }

    // Extract ports from the top-level "service" object
    var httpsPort: Int?
    var httpPort: Int?
    if let service = json["service"] as? [String: Any] {
      httpsPort = intValue(service["https_ext_port"]) ?? intValue(service["https_port"])
      httpPort  = intValue(service["ext_port"]) ?? intValue(service["port"])
    }
    // Fallback: old relay format stored ports inside "external"
    if httpsPort == nil, let portVal = ext["https"] { httpsPort = intArray(portVal).first }
    if httpPort  == nil, let portVal = ext["http"]  { httpPort  = intArray(portVal).first }
    // Last resort: standard Synology DSM ports
    if httpsPort == nil { httpsPort = 5001 }
    if httpPort  == nil { httpPort  = 5000 }

    // Collect LAN IPs from server.interface — these work from inside the network
    // without NAT hairpinning and without a valid TLS cert on the external IP.
    var lanIPs: [String] = []
    if let interfaces = server["interface"] as? [[String: Any]] {
      for iface in interfaces {
        if let ip = iface["ip"] as? String, !ip.isEmpty { lanIPs.append(ip) }
      }
    }

    var candidates: [String] = []
    // LAN addresses first: HTTPS before HTTP to avoid sending credentials over unencrypted connections
    for ip in lanIPs {
      if let p = httpsPort { candidates.append("https://\(ip):\(p)") }
      if let p = httpPort  { candidates.append("http://\(ip):\(p)") }
    }
    // WAN fallback (for remote access): HTTPS first
    if let p = httpsPort { candidates.append("https://\(wanIP):\(p)") }
    if let p = httpPort  { candidates.append("http://\(wanIP):\(p)") }

    return candidates
  }

  // MARK: Private

  private static func queryRelay(host: String, id: String) async throws -> [String: Any] {
    let url = URL(string: "https://\(host)/Serv.php")!
    var request = URLRequest(url: url, timeoutInterval: 12)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "version": 1,
      "command": "get_server_info",
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
