import SwiftUI

#if os(tvOS)

struct TVPairingView: View {
  @Environment(AppState.self) private var appState
  @State private var pairingCode: String?
  @State private var isGenerating: Bool = false
  @State private var error: String?
  @State private var countdown: Int = 0
  @State private var countdownTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      DSReelBrandColor.background
        .ignoresSafeArea()

      VStack(spacing: 40) {
        Text("DS Reel")
          .font(.system(size: 60, weight: .semibold))
          .foregroundStyle(.white)

        if isGenerating && pairingCode == nil {
          ProgressView()
            .tint(.white)
            .scaleEffect(1.5)
        } else if let code = pairingCode {
          VStack(spacing: 30) {
            Text("Pairing Code")
              .font(.title2)
              .foregroundStyle(.white.opacity(0.9))

            Text(code)
              .font(.system(size: 80, weight: .bold, design: .monospaced))
              .foregroundStyle(.white)
              .padding(.horizontal, 60)
              .padding(.vertical, 40)
              .background(.white.opacity(0.15))
              .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            if countdown > 0 {
              Text("Expires in \(countdown) seconds")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            }

            Button {
              Task { await generate() }
            } label: {
              Text("Generate New Code")
                .font(.headline)
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.3))
          }
        } else if let error {
          VStack(spacing: 20) {
            Text("Error")
              .font(.title2)
              .foregroundStyle(.white)
            Text(error)
              .foregroundStyle(.white.opacity(0.8))
            Button {
              Task { await generate() }
            } label: {
              Text("Retry")
            }
            .buttonStyle(.borderedProminent)
          }
        } else {
          Button {
            Task { await generate() }
          } label: {
            Text("Generate Pairing Code")
              .font(.title2)
              .padding(.horizontal, 60)
              .padding(.vertical, 24)
          }
          .buttonStyle(.borderedProminent)
          .tint(.white.opacity(0.3))
        }
      }
    }
    .onAppear {
      if pairingCode == nil && !isGenerating {
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

    // Cancel any existing countdown before starting a new one
    countdownTask?.cancel()
    countdownTask = nil

    await appState.generatePairingCode()
    if let code = appState.pairingCode {
      pairingCode = code
      countdown = 600 // 10 minutes
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
