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

@MainActor
@Observable
final class SetupFlowState {
  var resolvedAddress: String = ""
  var isHTTPS: Bool = false
  var rememberMe: Bool = true
  // TASK-805: once a discovered server has been chosen and navigation is under way,
  // ignore a second rapid tap on another row so resolvedAddress can't be overwritten
  // out from under the credentials screen. Reset when leaving the credentials step.
  var isSelectingServer: Bool = false
}

// MARK: - Root

struct ServerSetupView: View {
  @Environment(AppState.self) private var appState
  @State private var flow = SetupFlowState()

  var body: some View {
    NavigationStack {
      SetupWANMethodsScreen()
        .navigationDestination(for: SetupRoute.self) { route in
          switch route {
          case .wanTailscale:
            SetupWANTailscaleScreen()
          case .wanDirect:
            SetupWANDirectScreen()
          case .wanQuickConnect:
            SetupWANQuickConnectScreen()
          case .credentials:
            SetupCredentialsScreen()
          }
        }
    }
    .environment(flow)
    .background(Color.dsBackground.ignoresSafeArea())
    .preferredColorScheme(.dark)
  }
}

enum SetupRoute: Hashable {
  case wanTailscale, wanDirect, wanQuickConnect
  case credentials
}

// MARK: - Connection Methods (root)

private struct SetupWANMethodsScreen: View {
  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // Hero / branding — this is the landing page now.
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

            Text(AppInfo.displayName)
              .font(.largeTitle.weight(.semibold))
              .foregroundStyle(.white)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)

            Text("Your NAS, beautifully.")
              .font(.subheadline)
              .foregroundStyle(Color.dsTextSecondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 16)
          .padding(.bottom, 8)

          Text("Choose how you'd like to connect to your NAS.")
            .font(.subheadline)
            .foregroundStyle(Color.dsTextSecondary)

          NavigationLink(value: SetupRoute.wanTailscale) {
            WANMethodCard(
              icon: "lock.shield",
              title: "Tailscale",
              subtitle: "Works without touching your router",
              detail: "Install Tailscale on your NAS and iPhone — they'll connect securely from anywhere.",
              recommended: true
            )
          }
          .buttonStyle(.plain)

          NavigationLink(value: SetupRoute.wanDirect) {
            WANMethodCard(
              icon: "network",
              title: "Direct address",
              subtitle: "DDNS hostname, static IP, or port forwarding",
              detail: nil,
              recommended: false
            )
          }
          .buttonStyle(.plain)

          NavigationLink(value: SetupRoute.wanQuickConnect) {
            WANMethodCard(
              icon: "arrow.clockwise.circle",
              title: "Synology QuickConnect",
              subtitle: "For Synology NAS only",
              detail: "Enter your QuickConnect ID to connect through Synology's relay.",
              recommended: false
            )
          }
          .buttonStyle(.plain)

          #if !os(tvOS)
          VStack(spacing: 0) {
            Text("Already have a server address?")
              .font(.footnote)
              .foregroundStyle(Color.dsTextMuted)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, minHeight: 44)

            NavigationLink(value: SetupRoute.credentials) {
              Text("Enter it manually")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.dsAccent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
          }
          .padding(.top, 8)
          #endif
        }
        .padding(24)
      }
    }
    .navigationBarHidden(true)
  }
}

private struct WANMethodCard: View {
  let icon: String
  let title: String
  let subtitle: String
  let detail: String?
  let recommended: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: icon)
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(Color.dsAccent)
        .frame(width: 44)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
          if recommended {
            Text("Recommended")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.dsAccentOn)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.dsAccent)
              .clipShape(Capsule())
              .fixedSize()
          }
        }
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(Color.dsTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if let detail {
          Text(detail)
            .font(.footnote)
            .foregroundStyle(Color.dsTextMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
      }

      Spacer(minLength: 8)

      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.dsTextMuted)
        .padding(.top, 4)
    }
    .padding(20)
    .background(Color.dsSurface)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

// MARK: - WAN Tailscale

private struct SetupWANTailscaleScreen: View {
  @Environment(SetupFlowState.self) private var flow
  @State private var address: String = ""

  private var canContinue: Bool {
    let t = address.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("100.") && t.count > 6
  }

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Intro
          VStack(alignment: .leading, spacing: 8) {
            Text("Connect securely from anywhere")
              .font(.title3.weight(.semibold))
              .foregroundStyle(.white)
            Text("Tailscale creates a private network between your devices — no port forwarding, no DDNS, no exposed ports. It just works.")
              .font(.subheadline)
              .foregroundStyle(Color.dsTextSecondary)
          }

          // Steps
          VStack(alignment: .leading, spacing: 0) {
            Text("HOW TO SET IT UP")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.dsTextMuted)
              .padding(.horizontal, 16)
              .padding(.top, 16)
              .padding(.bottom, 12)

            VStack(spacing: 0) {
              TailscaleStep(number: 1,
                title: "Install Tailscale on your NAS",
                detail: "Go to your NAS's package manager and install the Tailscale package. On Synology, it's in Package Center. On QNAP, it's in App Center.")
              Divider().background(Color.dsBorderSubtle).padding(.leading, 52)
              TailscaleStep(number: 2,
                title: "Install Tailscale on this iPhone",
                detail: "Download Tailscale from the App Store and sign in with the same account you used on your NAS.")
              Divider().background(Color.dsBorderSubtle).padding(.leading, 52)
              TailscaleStep(number: 3,
                title: "Enter your Tailscale IP below",
                detail: "In the Tailscale app, find your NAS — it'll have an IP starting with 100.")
            }
            .padding(.bottom, 8)
          }
          .background(Color.dsSurface)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

          // Address field
          VStack(alignment: .leading, spacing: 8) {
            Text("TAILSCALE IP ADDRESS")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.dsTextMuted)

            TextField("100.x.x.x", text: $address)
              .keyboardType(.numbersAndPunctuation)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .padding(.horizontal, 16)
              .frame(minHeight: 48)
              .background(Color.dsSurface)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Find this in the Tailscale app → Machines → your NAS")
              .font(.caption)
              .foregroundStyle(Color.dsTextMuted)
          }

          NavigationLink(value: SetupRoute.credentials) {
            Text("Continue")
              .font(.headline)
              .foregroundStyle(canContinue ? Color.dsAccentOn : Color.dsTextMuted)
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(canContinue ? Color.dsAccent : Color.dsSurface)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .disabled(!canContinue)
          .buttonStyle(.plain)
          .simultaneousGesture(TapGesture().onEnded {
            guard canContinue else { return }
            let t = address.trimmingCharacters(in: .whitespaces)
            flow.resolvedAddress = t
            flow.isHTTPS = false
          })
        }
        .padding(24)
      }
    }
    .navigationTitle("Tailscale Setup")
    .inlineNavTitle()
  }
}

private struct TailscaleStep: View {
  let number: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      ZStack {
        Circle().fill(Color.dsAccent).frame(width: 26, height: 26)
        Text("\(number)")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.dsAccentOn)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
        Text(detail)
          .font(.footnote)
          .foregroundStyle(Color.dsTextSecondary)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }
}

// MARK: - WAN Direct

private struct SetupWANDirectScreen: View {
  @Environment(SetupFlowState.self) private var flow
  @State private var discovery = BonjourDiscovery()
  @State private var address: String = ""

  private var canContinue: Bool {
    !address.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Enter your server address")
              .font(.title3.weight(.semibold))
              .foregroundStyle(.white)
            Text("Use this if you've already set up DDNS, a static IP, or port forwarding on your router. We'll also auto-find any servers on your local network.")
              .font(.subheadline)
              .foregroundStyle(Color.dsTextSecondary)
          }

          // Auto-discovered servers on the local network
          if !discovery.servers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 8) {
                Text("FOUND ON YOUR NETWORK")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(Color.dsTextMuted)
                // TASK-798: keep the spinner visible while more servers may still resolve.
                if discovery.isScanning {
                  ProgressView().controlSize(.mini)
                }
              }

              VStack(spacing: 10) {
                ForEach(discovery.servers) { server in
                  NavigationLink(value: SetupRoute.credentials) {
                    HStack(spacing: 16) {
                      Image(systemName: "server.rack")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 36)

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

                      Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dsTextMuted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color.dsSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                  }
                  .buttonStyle(.plain)
                  .simultaneousGesture(TapGesture().onEnded {
                    // TASK-805: first tap wins; a rapid second tap on another row is ignored
                    // until the credentials screen resets the flag on appear.
                    guard !flow.isSelectingServer else { return }
                    flow.isSelectingServer = true
                    flow.resolvedAddress = server.baseURL
                    flow.isHTTPS = false
                  })
                }
              }
            }
          } else {
            // TASK-798: no servers found yet — give explicit feedback instead of a blank gap.
            HStack(spacing: 10) {
              if discovery.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning your network…")
                  .font(.subheadline)
                  .foregroundStyle(Color.dsTextSecondary)
              } else {
                Image(systemName: "wifi.exclamationmark")
                  .foregroundStyle(Color.dsTextMuted)
                Text("No servers found on your network. Enter an address below.")
                  .font(.subheadline)
                  .foregroundStyle(Color.dsTextSecondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("ADDRESS OR HOSTNAME")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.dsTextMuted)

            TextField("mynas.duckdns.org", text: $address)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .padding(.horizontal, 16)
              .frame(minHeight: 48)
              .background(Color.dsSurface)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Examples: mynas.duckdns.org · mynas.synology.me · 203.0.113.5:8080")
              .font(.caption)
              .foregroundStyle(Color.dsTextMuted)

            Text("Include a port after a colon if needed — e.g., :5001 for Synology's default port.")
              .font(.caption)
              .foregroundStyle(Color.dsTextMuted)
              .padding(.top, 2)
          }

          NavigationLink(value: SetupRoute.credentials) {
            Text("Continue")
              .font(.headline)
              .foregroundStyle(canContinue ? Color.dsAccentOn : Color.dsTextMuted)
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(canContinue ? Color.dsAccent : Color.dsSurface)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .disabled(!canContinue)
          .buttonStyle(.plain)
          .simultaneousGesture(TapGesture().onEnded {
            guard canContinue else { return }
            flow.resolvedAddress = address.trimmingCharacters(in: .whitespaces)
          })
        }
        .padding(24)
      }
    }
    .navigationTitle("Direct Address")
    .inlineNavTitle()
    .onAppear { discovery.startScan() }
    .onDisappear { discovery.stopScan() }
  }
}

// MARK: - WAN QuickConnect

private struct SetupWANQuickConnectScreen: View {
  @Environment(SetupFlowState.self) private var flow
  @State private var qcID: String = ""

  private var canContinue: Bool {
    !qcID.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Connect with QuickConnect")
              .font(.title3.weight(.semibold))
              .foregroundStyle(.white)
            Text("QuickConnect is a Synology feature. Enter the ID you created in DSM's Control Panel.")
              .font(.subheadline)
              .foregroundStyle(Color.dsTextSecondary)
          }

          // Caution
          HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: 18))
              .foregroundStyle(Color.dsWarning)
            Text("QuickConnect only works with Synology NAS. If you have QNAP, UGREEN, TrueNAS, or another brand, use Tailscale or Direct Address instead.")
              .font(.footnote)
              .foregroundStyle(Color.dsTextSecondary)
          }
          .padding(14)
          .background(Color.dsWarning.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(Color.dsWarning.opacity(0.25), lineWidth: 1)
          )

          VStack(alignment: .leading, spacing: 8) {
            Text("QUICKCONNECT ID")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.dsTextMuted)

            TextField("mynas", text: $qcID)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .padding(.horizontal, 16)
              .frame(minHeight: 48)
              .background(Color.dsSurface)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
              Text("This is the custom ID you chose in DSM Control Panel → QuickConnect.")
                .font(.caption)
                .foregroundStyle(Color.dsTextMuted)
              Text("It's not an email address or serial number.")
                .font(.caption)
                .foregroundStyle(Color.dsTextMuted)
            }
          }

          NavigationLink(value: SetupRoute.credentials) {
            Text("Continue")
              .font(.headline)
              .foregroundStyle(canContinue ? Color.dsAccentOn : Color.dsTextMuted)
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(canContinue ? Color.dsAccent : Color.dsSurface)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .disabled(!canContinue)
          .buttonStyle(.plain)
          .simultaneousGesture(TapGesture().onEnded {
            guard canContinue else { return }
            // Pass the bare ID — AppState.login() handles resolution via QuickConnectResolver
            flow.resolvedAddress = qcID.trimmingCharacters(in: .whitespaces)
          })
        }
        .padding(24)
      }
    }
    .navigationTitle("QuickConnect")
    .inlineNavTitle()
  }
}

// MARK: - Credentials (shared final step)

struct SetupCredentialsScreen: View {
  @Environment(AppState.self) private var appState
  @Environment(SetupFlowState.self) private var flow
  @Environment(\.dismiss) private var dismiss

  @State private var username: String = ""
  @State private var password: String = ""
  @State private var useHTTPS: Bool = false
  @State private var rememberMe: Bool = true
  @State private var showPassword: Bool = false
  @State private var isReturningUser: Bool = false

  // Secondary (remote) address for dual-address LAN+WAN setup
  @State private var remoteAddress: String = ""

  // Inline connection state
  @State private var isConnecting: Bool = false
  @State private var connectError: String?
  @State private var connectedAddress: String = ""

  private var effectiveAddress: String {
    connectedAddress.isEmpty ? flow.resolvedAddress : connectedAddress
  }

  private var canConnect: Bool {
    !username.trimmingCharacters(in: .whitespaces).isEmpty &&
    !password.trimmingCharacters(in: .whitespaces).isEmpty &&
    !effectiveAddress.isEmpty
  }

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {

          // Server address display
          if !effectiveAddress.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("CONNECTING TO")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.dsTextMuted)

              HStack {
                Text(effectiveAddress)
                  .font(.subheadline.weight(.medium))
                  .foregroundStyle(.white)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
                Button {
                  connectedAddress = ""
                  // Navigate back to address entry
                  dismiss()
                } label: {
                  Image(systemName: "pencil")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dsAccent)
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(16)
            .background(Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }

          // Remote address (optional — enables automatic LAN/WAN switching)
          VStack(alignment: .leading, spacing: 6) {
            Text("REMOTE ADDRESS (OPTIONAL)")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.dsTextMuted)

            HStack(spacing: 12) {
              Image(systemName: "network")
                .foregroundStyle(Color.dsTextMuted)
                .frame(width: 20)
              TextField("e.g. myserver.example.com or QuickConnect ID", text: $remoteAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .keyboardType(.URL)
                .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("When set, the app automatically switches between your local and remote address based on your network.")
              .font(.caption)
              .foregroundStyle(Color.dsTextMuted)
          }

          // Credentials
          VStack(spacing: 0) {
            HStack(spacing: 12) {
              Image(systemName: "person.fill")
                .foregroundStyle(Color.dsTextMuted)
                .frame(width: 20)
              TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)

            Divider().background(Color.dsBorderSubtle)

            HStack(spacing: 12) {
              Image(systemName: "lock.fill")
                .foregroundStyle(Color.dsTextMuted)
                .frame(width: 20)
              if showPassword {
                TextField("Password", text: $password)
                  .textContentType(.password)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
              } else {
                SecureField("Password", text: $password)
                  .textContentType(.password)
              }
              Button {
                showPassword.toggle()
              } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                  .foregroundStyle(Color.dsTextMuted)
                  .frame(width: 36, height: 44)
              }
              .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)

            // Inline error
            if let connectError {
              Divider().background(Color.dsBorderSubtle)
              HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                  .foregroundStyle(Color.dsError)
                  .font(.footnote)
                Text(connectError)
                  .font(.footnote)
                  .foregroundStyle(Color.dsError)
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
            }
          }
          .background(Color.dsSurface)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .privacySensitive()

          // Options
          VStack(spacing: 0) {
            Toggle(isOn: $useHTTPS) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Use HTTPS")
                  .font(.subheadline)
                  .foregroundStyle(.white)
                if !useHTTPS {
                  Text("Credentials sent without encryption")
                    .font(.caption)
                    .foregroundStyle(Color.dsWarning)
                }
              }
            }
            .tint(Color.dsAccent)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)

            Divider().background(Color.dsBorderSubtle)

            Toggle(isOn: $rememberMe) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Remember this server")
                  .font(.subheadline)
                  .foregroundStyle(.white)
                Text("Address and credentials saved for next time")
                  .font(.caption)
                  .foregroundStyle(Color.dsTextMuted)
              }
            }
            .tint(Color.dsAccent)
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
          }
          .background(Color.dsSurface)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

          // Connect button
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
        }
        .padding(24)
      }
    }
    .navigationTitle(isReturningUser ? "Welcome Back" : "Sign In")
    .inlineNavTitle()
    .onAppear {
      // TASK-805: navigation completed — clear the discovered-server selection guard so
      // backing out and choosing a different server works again.
      flow.isSelectingServer = false
      // Pre-fill from AppState for returning users
      if !appState.username.isEmpty {
        username = appState.username
        isReturningUser = true
      }
      if !appState.savedPassword.isEmpty {
        password = appState.savedPassword
      }
      useHTTPS = flow.isHTTPS || appState.useHTTPS
      rememberMe = appState.rememberMe
      // Use saved address if flow didn't set one (returning user skip)
      if flow.resolvedAddress.isEmpty && !appState.baseURL.isEmpty &&
         appState.baseURL != "http://localhost:5000" {
        connectedAddress = appState.baseURL
      }
      // Pre-fill remote address for returning users who already configured dual addressing
      let savedLAN = appState.lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
      let savedWAN = appState.wanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
      let primary = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
      if !savedLAN.isEmpty && !savedWAN.isEmpty {
        remoteAddress = savedLAN == primary ? savedWAN : savedLAN
      }
    }
  }

  private func connect() async {
    guard canConnect else { return }
    isConnecting = true
    connectError = nil
    defer { isConnecting = false }

    let addr = effectiveAddress.trimmingCharacters(in: .whitespaces)
    let secondary = remoteAddress.trimmingCharacters(in: .whitespaces)

    appState.baseURL = addr
    appState.username = username
    appState.setPassword(password)
    appState.useHTTPS = useHTTPS
    appState.rememberMe = rememberMe

    // Classify primary as LAN or WAN, set both on AppState for automatic switching
    if !secondary.isEmpty {
      if isLikelyLAN(addr) {
        appState.lanAddress = addr
        appState.wanAddress = secondary
      } else {
        appState.wanAddress = addr
        appState.lanAddress = secondary
      }
    } else {
      // Single address — clear whichever slot isn't being used
      if isLikelyLAN(addr) {
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
    // On success, appState.sessionToken is set — the root view transitions automatically
  }

  /// Heuristic: private IP ranges and .local mDNS names are LAN; everything else is WAN.
  private func isLikelyLAN(_ address: String) -> Bool {
    let lower = address.lowercased()
    if lower.hasSuffix(".local") { return true }
    // Strip scheme for IP check
    let stripped = lower
      .replacingOccurrences(of: "https://", with: "")
      .replacingOccurrences(of: "http://", with: "")
    let host = stripped.components(separatedBy: "/").first?
                       .components(separatedBy: ":").first ?? stripped
    if host.hasPrefix("192.168.") { return true }
    if host.hasPrefix("10.") { return true }
    if host.hasPrefix("172.") {
      let parts = host.components(separatedBy: ".")
      if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
    }
    return false
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
      return "Secure connection failed. If your server has no HTTPS certificate, turn HTTPS off."
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
