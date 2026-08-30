import SwiftUI

// MARK: - Helpers

private extension View {
  func inlineNavTitle() -> some View {
    #if os(tvOS)
    self
    #else
    self.navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

// MARK: - Flow State
//
// Kept as a type because RootView injects it into the environment for the returning-user
// path. It now carries exactly one thing: the address a discovered-server tap selected.
// Everything the old wizard tracked here (isHTTPS, rememberMe, isSelectingServer) is gone —
// see the header comment on ServerSetupView for why.

@MainActor
@Observable
final class SetupFlowState {
  var resolvedAddress: String = ""
}

// MARK: - Root
//
// ONE SCREEN. This used to be a four-screen wizard: a method picker (Tailscale / Direct /
// QuickConnect) that forked into three address-entry screens, all three of which did the
// identical thing — write a string to flow.resolvedAddress — and converged on a shared
// credentials screen.
//
// The fork was pure ceremony. AppState.buildCandidates() already sniffs whatever string it
// is handed: a QuickConnect ID expands to the full LAN → WAN → relay cascade, a hostname or
// IP is normalised with the right scheme and port. The QuickConnect screen's own comment
// said as much ("Pass the bare ID — AppState.login() handles resolution"). So the user was
// being asked to classify their address in order to reach a destination that did not care
// how it was classified — a decision with no information behind it and no consequence after.
//
// What the wizard DID have worth keeping was the Tailscale setup guidance. That is genuinely
// useful, so it moved into ConnectionHelpView: reference material reachable in one tap,
// rather than a checkpoint standing between the user and the app.
//
// Also gone from this screen:
//   • The HTTPS toggle. It never worked — login() overwrites useHTTPS from the winning
//     candidate (AppState.swift:575) and buildCandidates() forces http on private IPs
//     regardless of the flag. It was a switch wired to nothing that also rendered a
//     "credentials sent without encryption" warning about a setting it did not control.
//   • "Remote address (optional)". A dual-address LAN/WAN concept on a first-run screen,
//     where a new user has no way to know whether they need it. It lives in Settings now.
//   • "Remember this server". Nobody sets up a NAS client planning to retype credentials.
//     Defaults on; togglable in Settings.

struct ServerSetupView: View {
  @State private var flow = SetupFlowState()

  var body: some View {
    NavigationStack {
      SetupConnectScreen()
    }
    .environment(flow)
    .background(Color.dsBackground.ignoresSafeArea())
    .preferredColorScheme(.dark)
  }
}

// MARK: - Connect (the whole flow)

struct SetupConnectScreen: View {
  @Environment(AppState.self) private var appState
  @Environment(SetupFlowState.self) private var flow

  @State private var discovery = BonjourDiscovery()

  @State private var address: String = ""
  @State private var username: String = ""
  @State private var password: String = ""
  @State private var showPassword: Bool = false

  @State private var isConnecting: Bool = false
  @State private var connectError: String?
  @State private var showHelp: Bool = false
  @State private var isReturningUser: Bool = false

  @FocusState private var focusedField: Field?
  private enum Field: Hashable { case address, username, password }

  private var trimmedAddress: String {
    address.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canConnect: Bool {
    !trimmedAddress.isEmpty &&
    !username.trimmingCharacters(in: .whitespaces).isEmpty &&
    !password.isEmpty
  }

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          header

          if !isReturningUser {
            discoverySection
          }

          addressSection
          credentialsSection

          if let connectError {
            errorRow(connectError)
          }

          connectButton

          Button {
            showHelp = true
          } label: {
            HStack(spacing: 6) {
              Text("Need help connecting?")
              Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.dsAccent)
            .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.plain)
        }
        .padding(24)
      }
      .scrollDismissesKeyboard(.interactively)
    }
    .navigationBarHidden(true)
    .sheet(isPresented: $showHelp) {
      NavigationStack { ConnectionHelpView() }
        .preferredColorScheme(.dark)
    }
    .onAppear(perform: prefill)
    .onDisappear { discovery.stopScan() }
  }

  // MARK: Sections

  private var header: some View {
    VStack(spacing: 8) {
      ZStack {
        Circle()
          .fill(Color.dsAccent)
          .frame(width: 72, height: 72)
        Image(systemName: "play.fill")
          .font(.system(size: 28))
          .foregroundStyle(Color.dsAccentOn)
          .offset(x: 3)
      }
      .accessibilityHidden(true)
      .padding(.bottom, 8)

      Text(isReturningUser ? "Welcome Back" : AppInfo.displayName)
        .font(.largeTitle.weight(.semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      Text(isReturningUser ? "Sign in to your NAS." : "Your NAS, beautifully.")
        .font(.subheadline)
        .foregroundStyle(Color.dsTextSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 16)
  }

  /// Bonjour results. This used to be buried one tap deep inside the "Direct address"
  /// branch — the single path that requires no typing at all was the one you had to
  /// correctly guess your way into. It scans on the landing screen now.
  @ViewBuilder
  private var discoverySection: some View {
    if !discovery.servers.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("FOUND ON YOUR NETWORK")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.dsTextMuted)
          if discovery.isScanning {
            ProgressView().controlSize(.mini)
          }
        }

        ForEach(discovery.servers) { server in
          Button {
            address = server.baseURL
            flow.resolvedAddress = server.baseURL
            connectError = nil
            focusedField = username.isEmpty ? .username : .password
          } label: {
            HStack(spacing: 16) {
              Image(systemName: "server.rack")
                .font(.system(size: 22))
                .foregroundStyle(Color.dsAccent)
                .frame(width: 32)

              VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                  .font(.headline)
                  .foregroundStyle(.white)
                  .fixedSize(horizontal: false, vertical: true)
                Text(server.baseURL)
                  .font(.caption)
                  .foregroundStyle(Color.dsTextMuted)
                  .fixedSize(horizontal: false, vertical: true)
              }

              Spacer(minLength: 8)

              Image(systemName: trimmedAddress == server.baseURL
                    ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(trimmedAddress == server.baseURL
                                 ? Color.dsAccent : Color.dsTextMuted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(server.name), \(server.baseURL)")
          .accessibilityAddTraits(trimmedAddress == server.baseURL ? .isSelected : [])
        }
      }
    } else if discovery.isScanning {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("Looking for servers on your network…")
          .font(.subheadline)
          .foregroundStyle(Color.dsTextSecondary)
        Spacer(minLength: 0)
      }
    }
  }

  /// ONE field. It accepts a LAN IP, a DDNS hostname, a Tailscale 100.x address, or a bare
  /// QuickConnect ID, because buildCandidates() accepts all four and works out the rest.
  private var addressSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("SERVER ADDRESS")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.dsTextMuted)

      HStack(spacing: 12) {
        Image(systemName: "network")
          .foregroundStyle(Color.dsTextMuted)
          .frame(width: 20)
        TextField("192.168.1.50 or mynas.synology.me", text: $address)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textContentType(.URL)
          .keyboardType(.URL)
          .submitLabel(.next)
          .focused($focusedField, equals: .address)
          .onSubmit { focusedField = .username }
          // Without an explicit label VoiceOver reads the placeholder as the field's
          // NAME — "192.168.1.50 or mynas.synology.me" — on the app's most critical screen.
          .accessibilityLabel("Server address")
          .accessibilityHint("Your NAS IP address, hostname, QuickConnect ID, or Tailscale address")
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
      .background(Color.dsSurface)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      Text("IP address, hostname, QuickConnect ID, or Tailscale IP — whatever you have.")
        .font(.caption)
        .foregroundStyle(Color.dsTextMuted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var credentialsSection: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "person.fill")
          .foregroundStyle(Color.dsTextMuted)
          .frame(width: 20)
        TextField("Username", text: $username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textContentType(.username)
          .submitLabel(.next)
          .focused($focusedField, equals: .username)
          .onSubmit { focusedField = .password }
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 52)

      Divider().background(Color.dsBorderSubtle)

      HStack(spacing: 12) {
        Image(systemName: "lock.fill")
          .foregroundStyle(Color.dsTextMuted)
          .frame(width: 20)
        Group {
          if showPassword {
            TextField("Password", text: $password)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          } else {
            SecureField("Password", text: $password)
          }
        }
        .textContentType(.password)
        .submitLabel(.go)
        .focused($focusedField, equals: .password)
        .onSubmit { if canConnect { Task { await connect() } } }

        Button {
          showPassword.toggle()
        } label: {
          Image(systemName: showPassword ? "eye.slash" : "eye")
            .foregroundStyle(Color.dsTextMuted)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
    }
    .background(Color.dsSurface)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .privacySensitive()
  }

  private func errorRow(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(Color.dsError)
        .font(.footnote)
      Text(message)
        .font(.footnote)
        .foregroundStyle(Color.dsError)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(Color.dsError.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var connectButton: some View {
    Button {
      Task { await connect() }
    } label: {
      ZStack {
        if isConnecting {
          ProgressView().tint(Color.dsAccentOn)
        } else {
          Text("Connect")
            .font(.headline)
            .foregroundStyle(canConnect ? Color.dsAccentOn : Color.dsTextMuted)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(canConnect && !isConnecting ? Color.dsAccent : Color.dsSurface)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!canConnect || isConnecting)
    .accessibilityLabel(isConnecting ? "Connecting, please wait" : "Connect")
  }

  // MARK: Behaviour

  private func prefill() {
    if !appState.username.isEmpty {
      username = appState.username
      isReturningUser = true
    }

    // Only prefill from AppState when the user has not typed anything here yet.
    //
    // This runs again when the view reappears — including after a FAILED login. It used to
    // overwrite the field with appState.savedPassword, and login() only writes the password
    // to the Keychain on SUCCESS, so a failed attempt left savedPassword empty and blanked
    // the field. The user then tapped Connect again with an empty password and got the same
    // generic failure, with no sign their password had been discarded rather than rejected.
    if password.isEmpty, !appState.savedPassword.isEmpty {
      password = appState.savedPassword
    }

    if address.isEmpty {
      if !flow.resolvedAddress.isEmpty {
        address = flow.resolvedAddress
      } else if !appState.baseURL.isEmpty && appState.baseURL != "http://localhost:5000" {
        address = appState.baseURL
      }
    }

    // A returning user already has an address; scanning would just add noise under a
    // field that is already filled in.
    if !isReturningUser {
      discovery.startScan()
    }
  }

  private func connect() async {
    guard canConnect, !isConnecting else { return }
    focusedField = nil
    isConnecting = true
    connectError = nil
    defer { isConnecting = false }

    let addr = trimmedAddress

    appState.baseURL = addr
    appState.username = username.trimmingCharacters(in: .whitespaces)
    appState.setPassword(password)

    // Preserve any dual-address pairing the user configured in Settings; otherwise classify
    // this address into the slot it belongs in and clear the other. buildCandidates() reads
    // both slots, so leaving a stale one populated would keep a dead address in the cascade.
    let savedLAN = appState.lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let savedWAN = appState.wanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasConfiguredPair = !savedLAN.isEmpty && !savedWAN.isEmpty
                            && (savedLAN == addr || savedWAN == addr)
    if !hasConfiguredPair {
      if AppState.isPrivateLANAddress(addr) {
        appState.lanAddress = addr
        appState.wanAddress = ""
      } else {
        appState.wanAddress = addr
        appState.lanAddress = ""
      }
    }

    await appState.login()

    if let err = appState.loginError {
      connectError = friendlyError(err)
    }
    // On success appState.sessionToken is set and RootView transitions automatically.
  }

  /// Last-resort prettifier for an error string that reached us without its type.
  ///
  /// This used to test for credentials FIRST, which made it actively misleading: a server
  /// that was simply unreachable produced "Incorrect username or password", sending the user
  /// to re-type a password that was never wrong. That is exactly what happened with a stale
  /// saved address — nothing was listening, and the app blamed the credentials.
  ///
  /// Two rules here, both load-bearing:
  ///   1. Connectivity is checked BEFORE credentials. A message can only mean "bad password"
  ///      if the server was actually reached and said so.
  ///   2. Credential matching is narrow. Substrings like "host" or "password" appear inside
  ///      transport errors too, so only explicit server rejections qualify.
  ///
  /// Prefer APIError.userMessage over this function — the typed error carries the real reason.
  /// This exists only for paths that have already flattened the error to a String.
  private func friendlyError(_ raw: String) -> String {
    let lower = raw.lowercased()

    // --- Transport failures first: the server was never reached. ---
    if lower.contains("refused") {
      return "Connection refused. Check the port number, and that DSVideoServer is running."
    }
    if lower.contains("timed out") || lower.contains("timeout") {
      return "The server didn't respond. Check the address and that DSVideoServer is running."
    }
    if lower.contains("cannot connect") || lower.contains("could not connect")
        || lower.contains("connection lost") || lower.contains("unreachable")
        || lower.contains("offline") || lower.contains("not connected to the internet") {
      return "Couldn't connect to the server. Check the address and port, and that DSVideoServer is running."
    }
    if lower.contains("dns") || lower.contains("cannot find host")
        || lower.contains("couldn't find") || lower.contains("hostname could not be found") {
      return "Couldn't find that server. Double-check the address."
    }
    if lower.contains("certificate") || lower.contains("ssl") || lower.contains("tls")
        || lower.contains("secure connection") {
      return "Secure connection failed. Your server may not have a valid HTTPS certificate."
    }

    // --- Only now can this be a real credential rejection. ---
    if lower.contains("invalid_credentials") || lower.contains("401")
        || lower.contains("unauthori") || lower.contains("incorrect username") {
      return "Incorrect username or password."
    }
    if lower.contains("permission_denied") {
      return "Your account isn't allowed to use this app. Ask the server owner to grant access in DSM → Control Panel → Application Privileges."
    }
    if lower.contains("account_disabled") {
      return "This account is disabled. Ask the server owner to enable it."
    }
    return raw
  }
}

// MARK: - Connection Help
//
// Everything the wizard used to gate the user behind, as reference material instead. The
// Tailscale steps in particular were the one genuinely valuable part of the old flow — they
// just did not need to be a mandatory screen to reach a text field.

struct ConnectionHelpView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          Text("Enter whatever address you have — the app works out how to reach your NAS.")
            .font(.subheadline)
            .foregroundStyle(Color.dsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)

          HelpTopic(
            icon: "house",
            title: "On the same network",
            detail: "Pick your server from the list on the connect screen, or type its local IP — for example 192.168.1.50. Add a port after a colon only if you changed it from the default 5000."
          )

          HelpTopic(
            icon: "lock.shield",
            title: "From anywhere — Tailscale",
            detail: "The easiest remote option: no port forwarding, no DDNS, nothing exposed to the internet.",
            steps: [
              "Install the Tailscale package on your NAS — Package Center on Synology, App Center on QNAP.",
              "Install Tailscale on this device from the App Store and sign in with the same account.",
              "In the Tailscale app, open Machines and find your NAS. Its address starts with 100. Enter that on the connect screen."
            ]
          )

          HelpTopic(
            icon: "arrow.clockwise.circle",
            title: "Synology QuickConnect",
            detail: "Enter the QuickConnect ID you chose in DSM → Control Panel → QuickConnect — just the ID, not an email address or serial number. The app resolves it to the fastest working route on its own. Synology NAS only."
          )

          HelpTopic(
            icon: "globe",
            title: "DDNS or a static IP",
            detail: "If you've already set up DDNS or port forwarding on your router, enter that hostname or address — for example mynas.duckdns.org, or 203.0.113.5:8080 with an explicit port."
          )

          HelpTopic(
            icon: "person.badge.key",
            title: "Sign-in problems",
            detail: "Use your NAS account username and password. On DSM, non-admin accounts also need permission for this app, granted in Control Panel → Application Privileges."
          )
        }
        .padding(24)
      }
    }
    .navigationTitle("Connecting")
    .inlineNavTitle()
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
  }
}

private struct HelpTopic: View {
  let icon: String
  let title: String
  let detail: String
  var steps: [String] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(Color.dsAccent)
          .frame(width: 28)
          .accessibilityHidden(true)
        Text(title)
          .font(.headline)
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text(detail)
        .font(.subheadline)
        .foregroundStyle(Color.dsTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if !steps.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .top, spacing: 12) {
              ZStack {
                Circle().fill(Color.dsAccent).frame(width: 24, height: 24)
                Text("\(index + 1)")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(Color.dsAccentOn)
              }
              .accessibilityHidden(true)
              Text(step)
                .font(.footnote)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
          }
        }
        .padding(16)
        .background(Color.dsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    }
  }
}
