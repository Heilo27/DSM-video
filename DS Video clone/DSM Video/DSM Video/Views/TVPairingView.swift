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
                .foregroundStyle(.white)
            )

          Text("Pair iOS Device")
            .font(.system(size: 42, weight: .bold))
            .foregroundStyle(.white)

          Text("Enter this code in DSM Video on your iPhone or iPad.")
            .font(.system(size: 20))
            .foregroundStyle(Color.dsTextSecondary)
            .multilineTextAlignment(.center)
        }
        .padding(.bottom, 56)

        // Content
        if isGenerating && pairingCode == nil {
          ProgressView()
            .tint(.white)
            .scaleEffect(2.0)
            .padding(.vertical, 40)
        } else if let code = pairingCode {
          VStack(spacing: 32) {
            // Code display
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

            // Countdown
            if countdown > 0 {
              HStack(spacing: 8) {
                Image(systemName: "clock")
                  .font(.system(size: 17))
                  .foregroundStyle(Color.dsTextMuted)
                Text("Expires in \(countdown)s")
                  .font(.system(size: 19))
                  .foregroundStyle(Color.dsTextSecondary)
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


        // Manual login fallback
        Button("Sign in manually") {
          showManualLogin = true
        }
        .buttonStyle(.plain)
        .font(.system(size: 19))
        .foregroundStyle(Color.dsTextSecondary)
        .padding(.top, 40)
      }
      .padding(60)
    }
    .fullScreenCover(isPresented: $showManualLogin) {
      TVLoginView()
        .environment(appState)
    }
    .onAppear {
      // Only auto-generate if we have a session — generatePairingCode requires auth
      if pairingCode == nil && !isGenerating && appState.sessionToken != nil {
        Task { await generate() }
      }
    }
    .onDisappear {
      countdownTask?.cancel()
    }
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
          guard !Task.isCancelled else { return }
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          guard !Task.isCancelled else { return }
          countdown -= 1
        }
        pairingCode = nil
      }
    } else {
      error = appState.pairingError ?? "Failed to generate code."
    }
  }
}

#Preview {
  TVPairingView()
    .environment(AppState())
}

#endif
