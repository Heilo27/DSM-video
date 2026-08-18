import SwiftUI

#if os(tvOS)

struct TVPairingView: View {
  @Environment(AppState.self) private var appState
  @State private var pairingCode: String?
  @State private var isGenerating: Bool = false
  @State private var error: String?
  @State private var countdown: Int = 0
  @State private var countdownTask: Task<Void, Never>?
  @State private var showManualLogin: Bool = false
  /// Secondary route: network discovery + manual sign-in, off the main screen so the code
  /// field is the only thing competing for the remote's first Select press.
  @State private var showOtherWays: Bool = false
  /// Code typed on THIS device to redeem a pairing code generated on an already-signed-in
  /// phone. This is the direction a first-time Apple TV must use — see the header comment.
  @State private var enteredCode: String = ""
  @State private var isRedeeming: Bool = false
  @State private var redeemError: String?
  @FocusState private var codeFieldFocused: Bool

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      // Subtle radial depth
      RadialGradient(
        colors: [Color(white: 0.07), Color.black],
        center: .center,
        startRadius: 50,
        endRadius: 700
      )
      .ignoresSafeArea()

      VStack(spacing: 0) {
        // Header
        VStack(spacing: 16) {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.dsAccent)
            .frame(width: 64, height: 64)
            .overlay(
              Image(systemName: "iphone.and.arrow.right.inward")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.dsAccentOn)
            )
            .accessibilityHidden(true)

          Text(appState.sessionToken == nil ? "Connect This Apple TV" : "Pair iOS Device")
            .font(.system(size: 42, weight: .bold))
            .foregroundStyle(.white)

          // WHERE THE CODE COMES FROM. This is the one thing a first-time user cannot
          // guess, and the old copy buried it in a single run-on sentence that also failed
          // to state the prerequisite: the phone must ALREADY be signed in. /auth/pairing/
          // generate requires a bearer token, so a phone that has never connected cannot
          // mint a code either, and the user would follow the instructions to a button that
          // is not there. Say the prerequisite first, then the path, then the action.
          if appState.sessionToken == nil {
            VStack(spacing: 14) {
              Text("Get a code from your iPhone or iPad")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)

              Text("On a device that's already signed in to \(AppInfo.displayName), open **Settings → Apple TV → Pair Apple TV**. It shows a 6-digit code — type it below.")
                .font(.system(size: 20))
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)

              Text("No signed-in device? Use Other ways to connect at the bottom.")
                .font(.system(size: 17))
                .foregroundStyle(Color.dsTextMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            }
            .accessibilityElement(children: .combine)
          } else {
            Text("Enter this code in \(AppInfo.displayName) on your iPhone or iPad.")
              .font(.system(size: 20))
              .foregroundStyle(Color.dsTextSecondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 900)
          }
        }
        .padding(.bottom, 56)

        // Content
        //
        // THE PAIRING DIRECTION MATTERS. /auth/pairing/generate REQUIRES a bearer token;
        // /auth/pairing/exchange does NOT. A first-time Apple TV has no token, so it cannot
        // generate anything — it must ENTER a code produced by an already-signed-in phone.
        //
        // This screen used to offer only "Generate Pairing Code", which tripped
        // `guard sessionToken != nil` in generatePairingCode() and showed
        // "Must be logged in to generate pairing code." on the sign-in screen. The only
        // escape was the on-screen keyboard. Worse, the redeem path was compiled out of the
        // TV app entirely, so a virgin Apple TV could not pair at all. The code field below
        // is that redeem path; SettingsView on iOS is where the code is minted.
        if appState.sessionToken == nil {
          codeEntry
        } else if isGenerating && pairingCode == nil {
          ProgressView("Generating pairing code")
            .tint(.white)
            .scaleEffect(2.0)
            .padding(.vertical, 40)
        } else if let code = pairingCode {
          VStack(spacing: 32) {
            // Code + countdown grouped for VoiceOver
            VStack(spacing: 16) {
              Text(code)
                .font(.system(size: 80, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(8)
                .padding(.horizontal, 72)
                .padding(.vertical, 40)
                .background(Color(white: 0.1))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.dsBorderStrong, lineWidth: 1)
                )
                .speechSpellsOutCharacters(true)
                .privacySensitive()
                .accessibilityLabel("Pairing code: \(code.map { String($0) }.joined(separator: " "))")

              if countdown > 0 {
                HStack(spacing: 8) {
                  Image(systemName: "clock")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.dsTextMuted)
                    .accessibilityHidden(true)
                  Text("Expires in \(countdown)s")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.dsTextSecondary)
                }
              }
            }
            .accessibilityElement(children: .combine)
            .onChange(of: countdown) { _, newValue in
              if newValue == 60 || newValue == 30 || newValue == 10 {
                AccessibilityNotification.Announcement("Code expires in \(newValue) seconds").post()
              }
            }

            Button {
              Task { await generate() }
            } label: {
              Text("Generate New Code")
                .font(.system(size: 19, weight: .medium))
                .padding(.horizontal, 40)
                .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(white: 0.18))
          }
        } else if let error {
          VStack(spacing: 24) {
            Image(systemName: "exclamationmark.circle")
              .font(.system(size: 48))
              .foregroundStyle(Color.dsError)

            Text(error)
              .font(.system(size: 20))
              .foregroundStyle(Color.dsTextSecondary)
              .multilineTextAlignment(.center)

            Button {
              Task { await generate() }
            } label: {
              Text("Try Again")
                .font(.system(size: 19, weight: .medium))
                .padding(.horizontal, 40)
                .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.dsAccent)
          }
        } else {
          Button {
            Task { await generate() }
          } label: {
            Text("Generate Pairing Code")
              .font(.system(size: 22, weight: .semibold))
              .padding(.horizontal, 64)
              .padding(.vertical, 24)
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.dsAccent)
        }


        // ONE primary path, one secondary route.
        //
        // This screen used to render three competing entry points at once: the code field,
        // a live Bonjour server list, and a "Sign in manually" button. On a remote-driven
        // screen that is three focus targets fighting for the first Select press, and two of
        // them lead somewhere strictly worse — TVLoginView asks you to type a server
        // address, a username AND a password with the on-screen keyboard.
        //
        // Pairing is the better answer and is now the whole screen: a signed-in phone
        // already knows the address, the credentials and the winning scheme, and six digits
        // transfers all of it. Discovery and manual sign-in still exist for the case where
        // no phone is to hand — behind one clearly secondary button.
        if appState.sessionToken == nil {
          Button {
            showOtherWays = true
          } label: {
            Text("Other ways to connect")
              .font(.system(size: 19))
              .foregroundStyle(Color.dsTextSecondary)
          }
          .buttonStyle(.bordered)
          .padding(.top, 40)
          .accessibilityHint("Connect by choosing a server on your network, or by typing your server address and password")
        }
      }
      .padding(60)
    }
    .privacySensitive()
    .fullScreenCover(isPresented: $showManualLogin) {
      TVLoginView()
        .environment(appState)
    }
    .fullScreenCover(isPresented: $showOtherWays) {
      TVOtherWaysView(onManualLogin: {
        showOtherWays = false
        showManualLogin = true
      })
      .environment(appState)
    }
    .onAppear {
      if appState.sessionToken == nil {
        // Signed out: this device REDEEMS a code. Put focus on the field so the remote's
        // first Select opens the keyboard instead of landing on a button that cannot work.
        codeFieldFocused = true
      } else if pairingCode == nil && !isGenerating {
        // Signed in: this device can hand a code to another device.
        Task { await generate() }
      }
    }
    .onDisappear {
      countdownTask?.cancel()
    }
    .onChange(of: pairingCode) { _, newCode in
      // TASK-406: stop the countdown whenever pairingCode is cleared (e.g. from outside)
      if newCode == nil {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = 0
      }
    }
    .onChange(of: appState.pairingCode) { _, appCode in
      // Keep local state in sync: if AppState clears pairingCode (e.g. logout),
      // clear the local display and stop the countdown.
      if appCode == nil && pairingCode != nil {
        pairingCode = nil
      }
    }
  }

  @MainActor
  /// Code ENTRY — the path a first-time Apple TV must take.
  ///
  /// tvOS renders a TextField as a full-screen keyboard when focused and activated, so this
  /// is drivable with the remote alone. `.oneTimeCode` gives the numeric keypad layout.
  @ViewBuilder
  private var codeEntry: some View {
    VStack(spacing: 28) {
      TextField("000000", text: $enteredCode)
        .textContentType(.oneTimeCode)
        .keyboardType(.numberPad)
        .font(.system(size: 56, weight: .bold, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
        .focused($codeFieldFocused)
        .privacySensitive()
        .accessibilityLabel("Pairing code")
        .accessibilityHint("Enter the 6-digit code shown on your iPhone or iPad")
        .onChange(of: enteredCode) { _, newValue in
          // Keep it to 6 digits; auto-submit on the sixth so the user never has to hunt
          // for a Connect button with the remote.
          let digits = newValue.filter(\.isNumber)
          if digits != newValue { enteredCode = String(digits.prefix(6)); return }
          if digits.count > 6 { enteredCode = String(digits.prefix(6)); return }
          if digits.count == 6 { Task { await redeem() } }
        }

      if isRedeeming {
        HStack(spacing: 12) {
          ProgressView().tint(.white)
          Text("Connecting…")
            .font(.system(size: 19))
            .foregroundStyle(Color.dsTextSecondary)
        }
      } else if let redeemError {
        Text(redeemError)
          .font(.system(size: 19))
          .foregroundStyle(Color.dsError)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 700)
      }

      Button {
        Task { await redeem() }
      } label: {
        Text("Connect")
          .font(.system(size: 22, weight: .semibold))
          .padding(.horizontal, 64)
          .padding(.vertical, 24)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.dsAccent)
      .disabled(enteredCode.count != 6 || isRedeeming)
    }
  }

  /// Redeems a code generated on a signed-in phone. Never requires a token on this device —
  /// that is the whole point of the exchange endpoint.
  private func redeem() async {
    let code = enteredCode.filter(\.isNumber)
    guard code.count == 6, !isRedeeming else { return }
    isRedeeming = true
    defer { isRedeeming = false }   // defer, so a cancelled task cannot latch this flag
    redeemError = nil
    await appState.exchangePairingCode(code)
    if appState.sessionToken == nil {
      redeemError = appState.loginError ?? "That code didn't work. Check it and try again."
      enteredCode = ""
    }
    // On success TVMainView swaps to TVHomeView, and its .task(id: sessionToken) loads the rails.
  }

  private func generate() async {
    error = nil
    isGenerating = true
    defer { isGenerating = false }

    countdownTask?.cancel()
    countdownTask = nil

    if appState.isDemoMode {
      pairingCode = "DEMO-1234"
      countdown = 600
      return
    }

    await appState.generatePairingCode()

    if let code = appState.pairingCode {
      pairingCode = code
      countdown = appState.pairingCodeExpiresInSeconds
      countdownTask = Task { @MainActor in
        while countdown > 0 {
          do {
            try await Task.sleep(for: .seconds(1))
          } catch {
            return // Task cancelled — exit cleanly
          }
          countdown -= 1
        }
        pairingCode = nil
      }
    } else {
      error = appState.pairingError ?? "Failed to generate code."
    }
  }
}

// MARK: - Other Ways To Connect
//
// The fallback for when no signed-in phone is available. Discovery lives here rather than on
// the pairing screen so it is not a third focus target competing with the code field.

private struct TVOtherWaysView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  let onManualLogin: () -> Void

  @State private var discovery = BonjourDiscovery()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      RadialGradient(
        colors: [Color(white: 0.07), Color.black],
        center: .center,
        startRadius: 50,
        endRadius: 700
      )
      .ignoresSafeArea()

      VStack(spacing: 40) {
        VStack(spacing: 12) {
          Text("Other Ways To Connect")
            .font(.system(size: 42, weight: .bold))
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)

          Text("Pairing from your iPhone is quicker — but if you don't have it to hand, pick your server below or sign in by hand.")
            .font(.system(size: 20))
            .foregroundStyle(Color.dsTextSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 900)
        }

        if !discovery.servers.isEmpty {
          VStack(spacing: 16) {
            Text("Found on your network")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(Color.dsTextSecondary)

            VStack(spacing: 12) {
              ForEach(discovery.servers) { server in
                Button {
                  appState.baseURL = server.baseURL
                  onManualLogin()
                } label: {
                  HStack(spacing: 16) {
                    Image(systemName: "server.rack")
                      .font(.system(size: 22))
                      .foregroundStyle(Color.dsAccent)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(server.name)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                      Text(server.baseURL)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.dsTextMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                      .foregroundStyle(Color.dsTextMuted)
                      .accessibilityHidden(true)
                  }
                  .padding(.horizontal, 32)
                  .padding(.vertical, 18)
                  .background(Color(white: 0.1))
                  .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                      .stroke(Color.dsBorderStrong, lineWidth: 1)
                  )
                }
                .buttonStyle(.card)
                .frame(maxWidth: 600)
                .accessibilityLabel("\(server.name), \(server.baseURL)")
              }
            }
            .focusSection()
          }
        } else if discovery.isScanning {
          HStack(spacing: 12) {
            ProgressView().tint(Color.dsTextMuted)
            Text("Scanning network…")
              .font(.system(size: 18))
              .foregroundStyle(Color.dsTextMuted)
          }
        } else {
          Text("No servers found on your network.")
            .font(.system(size: 18))
            .foregroundStyle(Color.dsTextMuted)
        }

        // Always focusable, whatever discovery returns — a tvOS screen with no focusable
        // element cannot be escaped with the remote.
        VStack(spacing: 20) {
          Button {
            onManualLogin()
          } label: {
            Text("Enter server address manually")
              .font(.system(size: 20, weight: .semibold))
              .padding(.horizontal, 48)
              .padding(.vertical, 20)
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.dsAccent)

          Button("Back") { dismiss() }
            .buttonStyle(.bordered)
            .font(.system(size: 19))
            .foregroundStyle(Color.dsTextSecondary)
        }
      }
      .padding(60)
    }
    .onAppear { discovery.startScan() }
    .onDisappear { discovery.stopScan() }
  }
}

#Preview {
  TVPairingView()
    .environment(AppState())
}

#endif
