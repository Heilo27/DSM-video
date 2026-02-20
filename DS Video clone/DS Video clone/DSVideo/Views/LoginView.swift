import SwiftUI

struct LoginView: View {
  @Environment(AppState.self) private var appState

  #if !os(tvOS)
  @State private var showPairing: Bool = false
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

        Text("DS Reel")
          .font(.system(size: 40, weight: .semibold, design: .default))
          .foregroundStyle(.white)

        VStack(spacing: 0) {
          HStack {
            TextField("Server or QuickConnect ID", text: $appState.baseURL)
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
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        #if os(tvOS)
        .frame(maxWidth: 600)
        #else
        .padding(.horizontal, 24)
        #endif

        #if !os(tvOS)
        VStack(alignment: .leading, spacing: 12) {
          Toggle("HTTPS", isOn: $appState.useHTTPS)
          Toggle("Remember me", isOn: $appState.rememberMe)
        }
        .tint(.white)
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 24)
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
        .background(.white)
        .foregroundStyle(DSReelBrandColor.background)
        .clipShape(Capsule())
        #if os(tvOS)
        .frame(maxWidth: 600)
        #else
        .padding(.horizontal, 24)
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
          Button {} label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
          Spacer()
          Text("Downloaded Videos")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.75))
          Spacer()
          Button {} label: { Image(systemName: "info.circle") }
            .accessibilityLabel("About DS Reel")
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
      }
      #endif
      .sheet(isPresented: $showQuickConnect) {
        QuickConnectSheet { selectedURL in
          appState.baseURL = selectedURL
          appState.useHTTPS = selectedURL.hasPrefix("https")
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
  /// Resolves a QuickConnect ID against Synology's relay service.
  /// Returns candidate base URLs ordered https-first.
  static func resolve(id: String) async throws -> [String] {
    let json = try await queryRelay(host: "global.quickconnect.to", id: id)

    // Check for not-found or error
    if let errno = json["errno"] as? Int, errno != 0 { return [] }

    // Extract external IP
    guard let server = json["server"] as? [String: Any],
          let ext = server["external"] as? [String: Any],
          let ip = ext["ip"] as? String, !ip.isEmpty
    else { return [] }

    var candidates: [String] = []

    // Synology puts ports in top-level "service" object (not in external)
    if let service = json["service"] as? [String: Any] {
      let httpsPort = intValue(service["https_ext_port"]) ?? intValue(service["https_port"])
      let httpPort  = intValue(service["ext_port"]) ?? intValue(service["port"])
      if let p = httpsPort { candidates.append("https://\(ip):\(p)") }
      if let p = httpPort  { candidates.append("http://\(ip):\(p)") }
    }

    // Fallback: old format had ports directly in ext as arrays
    if candidates.isEmpty {
      for (scheme, key) in [("https", "https"), ("http", "http")] {
        if let portVal = ext[key] {
          let ports = intArray(portVal)
          for p in ports { candidates.append("\(scheme)://\(ip):\(p)") }
        }
      }
    }

    // If still empty, try default Synology ports
    if candidates.isEmpty {
      candidates = ["https://\(ip):5001", "http://\(ip):5000"]
    }

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
