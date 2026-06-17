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
}

// MARK: - Root

struct ServerSetupView: View {
  @Environment(AppState.self) private var appState
  @State private var flow = SetupFlowState()

  var body: some View {
    NavigationStack {
      SetupWelcomeScreen()
        .navigationDestination(for: SetupRoute.self) { route in
          switch route {
          case .lanScan:
            SetupLANScanScreen()
          case .lanManual:
            SetupLANManualScreen()
          case .wanMethods:
            SetupWANMethodsScreen()
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
  case lanScan, lanManual
  case wanMethods, wanTailscale, wanDirect, wanQuickConnect
  case credentials
}

// MARK: - Welcome

private struct SetupWelcomeScreen: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      // ScrollView so the centered hero + cards can't clip vertically at the
      // largest Dynamic Type sizes. GeometryReader gives the inner VStack a
      // minHeight equal to the viewport so the Spacers still center content at
      // normal sizes; when content grows past the viewport it scrolls instead.
      GeometryReader { geo in
        ScrollView {
          VStack(spacing: 0) {
            Spacer(minLength: 0)

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

              Text("Let's get you connected.")
                .font(.footnote)
                .foregroundStyle(Color.dsTextMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }

            Spacer().frame(height: 40)

            VStack(spacing: 12) {
              NavigationLink(value: SetupRoute.lanScan) {
                SetupModeCard(
                  icon: "wifi",
                  title: "On your home network",
                  subtitle: "I'm on the same WiFi as my NAS"
                )
              }

              NavigationLink(value: SetupRoute.wanMethods) {
                SetupModeCard(
                  icon: "globe",
                  title: "Away from home",
                  subtitle: "I'm on mobile data or a different network"
                )
              }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            #if !os(tvOS)
            Button {
              // Skip wizard — go straight to manual credentials for power users
            } label: {
              Text("Already have a server address?")
                .font(.footnote)
                .foregroundStyle(Color.dsTextMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)

            NavigationLink(value: SetupRoute.credentials) {
              Text("Enter it manually")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.dsAccent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
            }
            .padding(.bottom, 24)
            #endif
          }
          .frame(minHeight: geo.size.height)
        }
      }
    }
    .navigationBarHidden(true)
  }
}

private struct SetupModeCard: View {
  let icon: String
  let title: String
  let subtitle: String

  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: icon)
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(Color.dsAccent)
        .frame(width: 44)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(Color.dsTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Image(systemName: "chevron.right")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.dsTextMuted)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 18)
    .background(Color.dsSurface)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

// MARK: - LAN Scan

private struct SetupLANScanScreen: View {
  @Environment(SetupFlowState.self) private var flow
  @State private var discovery = BonjourDiscovery()
  @State private var timedOut = false
  @State private var path: [SetupRoute] = []

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      if timedOut && discovery.servers.isEmpty {
        SetupLANManualScreen()
      } else if !discovery.servers.isEmpty {
        SetupLANFoundScreen(servers: discovery.servers, onNotFound: {
          timedOut = true
        })
      } else {
        VStack(spacing: 20) {
          Spacer()
          ProgressView()
            .scaleEffect(1.4)
            .tint(.white)
          Text("Looking for servers on your network…")
            .font(.headline)
            .foregroundStyle(.white)
          Text("This usually takes just a moment.")
            .font(.subheadline)
            .foregroundStyle(Color.dsTextSecondary)
          Spacer()
        }
        .padding()
      }
    }
    .navigationTitle("Find Server")
    .inlineNavTitle()
    .onAppear { discovery.startScan() }
    .onDisappear { discovery.stopScan() }
    .task {
      try? await Task.sleep(for: .seconds(8))
      if discovery.servers.isEmpty { timedOut = true }
    }
  }
}

private struct SetupLANFoundScreen: View {
  @Environment(SetupFlowState.self) private var flow
  let servers: [BonjourDiscovery.DiscoveredServer]
  let onNotFound: () -> Void

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        Text("FOUND ON YOUR NETWORK")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.dsTextMuted)
          .padding(.horizontal, 24)
          .padding(.top, 24)
          .padding(.bottom, 12)

        ScrollView {
          VStack(spacing: 10) {
            ForEach(servers) { server in
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
                flow.resolvedAddress = server.baseURL
                flow.isHTTPS = false
              })
            }
          }
          .padding(.horizontal, 24)
        }

        Divider()
          .background(Color.dsBorderSubtle)
          .padding(.top, 8)

        Button(action: onNotFound) {
          Text("Don't see your server?")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.dsAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.plain)
      }
    }
    .navigationTitle("Select Server")
    .inlineNavTitle()
  }
}

// MARK: - LAN Manual

private struct SetupLANManualScreen: View {
  @Environment(SetupFlowState.self) private var flow
  @State private var address: String = "192.168."
  @State private var isProbing = false
  @State private var probeError: String?

  private var canContinue: Bool {
    let trimmed = address.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && trimmed != "192.168." && trimmed.count > 9
  }

  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Status block
          HStack(alignment: .top, spacing: 16) {
            Image(systemName: "exclamationmark.wifi")
              .font(.system(size: 28))
              .foregroundStyle(Color.dsTextMuted)
            VStack(alignment: .leading, spacing: 6) {
              Text("Couldn't find a server automatically")
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
              Text("Make sure your NAS is powered on and connected to the same WiFi network as this device.")
                .font(.subheadline)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(16)
          .background(Color.dsSurface)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

          // Address field
          VStack(alignment: .leading, spacing: 8) {
            Text("SERVER ADDRESS")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.dsTextMuted)

            VStack(spacing: 0) {
              TextField("192.168.1.100 or hostname", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 16)
                .frame(minHeight: 48)

              if let probeError {
                Divider().background(Color.dsBorderSubtle)
                Text(probeError)
                  .font(.footnote)
                  .foregroundStyle(Color.dsError)
                  .padding(.horizontal, 16)
                  .padding(.vertical, 10)
              }
            }
            .background(Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Include a port if needed — e.g., 192.168.1.100:5001")
              .font(.caption)
              .foregroundStyle(Color.dsTextMuted)
          }

          // Actions
          VStack(spacing: 10) {
            NavigationLink(value: SetupRoute.credentials) {
              ZStack {
                if isProbing {
                  ProgressView().tint(Color.dsAccentOn)
                } else {
                  Text("Connect")
                    .font(.headline)
                    .foregroundStyle(canContinue ? Color.dsAccentOn : Color.dsTextMuted)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(canContinue ? Color.dsAccent : Color.dsSurface)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!canContinue || isProbing)
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
              guard canContinue else { return }
              flow.resolvedAddress = address.trimmingCharacters(in: .whitespaces)
              probeError = nil
            })

            NavigationLink(value: SetupRoute.lanScan) {
              Text("Scan Again")
                .font(.headline)
                .foregroundStyle(Color.dsTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.dsSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(24)
      }
    }
    .navigationTitle("Enter Address")
    .inlineNavTitle()
    .onChange(of: address) { _, _ in probeError = nil }
  }
}

// MARK: - WAN Methods

private struct SetupWANMethodsScreen: View {
  var body: some View {
    ZStack {
      Color.dsBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Choose how you connect to your NAS from outside your home network.")
            .font(.subheadline)
            .foregroundStyle(Color.dsTextSecondary)
            .padding(.top, 8)

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
        }
        .padding(24)
      }
    }
    .navigationTitle("Remote Connection")
    .inlineNavTitle()
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
            Text("Use this if you've already set up DDNS, a static IP, or port forwarding on your router.")
              .font(.subheadline)
              .foregroundStyle(Color.dsTextSecondary)
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

  private func friendlyError(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("401") || lower.contains("unauthori") || lower.contains("password") || lower.contains("credentials") {
      return "Incorrect username or password."
    }
    if lower.contains("certificate") || lower.contains("ssl") || lower.contains("tls") {
      return "Certificate error. Try disabling HTTPS if your server doesn't have a certificate."
    }
    if lower.contains("timed out") || lower.contains("timeout") {
      return "The server didn't respond. Check the address and that DSVideoServer is running."
    }
    if lower.contains("refused") {
      return "Connection refused. Check the port number."
    }
    if lower.contains("dns") || lower.contains("host") || lower.contains("couldn't find") {
      return "Couldn't resolve that address. Double-check the hostname."
    }
    return raw
  }
}
