import SwiftUI

/// On-screen diagnostic log, reachable from Settings.
///
/// DESIGNED TO BE PHOTOGRAPHED. That constraint drives the layout:
///
///   * Monospaced digits so timestamps form a straight column the eye can scan.
///   * High contrast, no thin greys — a phone camera pointed at a TV loses low-contrast text.
///   * Newest at the top, so the interesting event is in frame without scrolling.
///   * Errors carry a red glyph AND a symbol, because a photo may be colour-shifted.
///   * A header line stating build and server, so a cropped photo is still self-describing.
///   * Wide line-limit rather than truncation — a clipped message is a message that has to
///     be asked about a second time.
struct DiagnosticLogView: View {
  @Environment(AppState.self) private var appState
  @State private var entries: [DiagnosticLog.Entry] = []
  @State private var filter: DiagnosticLog.Category?
  @State private var errorsOnly = false

  private var visible: [DiagnosticLog.Entry] {
    entries.filter { e in
      (filter == nil || e.category == filter) && (!errorsOnly || e.level != .info)
    }
  }

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      if visible.isEmpty {
        ContentUnavailableView(
          "No log entries",
          systemImage: "doc.text.magnifyingglass",
          description: Text(errorsOnly
                            ? "No warnings or errors recorded."
                            : "Use the app, then return here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(visible) { entry in
              row(entry)
            }
          }
          .padding(.horizontal)
          .padding(.vertical, 12)
        }
      }
    }
    .background(Color.black)
    .navigationTitle("Diagnostic Log")
    .onAppear { entries = DiagnosticLog.shared.entries }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh") { entries = DiagnosticLog.shared.entries }
      }
    }
    #if !os(tvOS)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        ShareLink(item: DiagnosticLog.shared.exportText()) {
          Image(systemName: "square.and.arrow.up")
        }
      }
    }
    #endif
  }

  // MARK: - Header

  /// Build + server identity. A photo of the log is often cropped to the interesting lines,
  /// so this has to be terse enough to survive at the top of the frame.
  private var header: some View {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return VStack(alignment: .leading, spacing: 4) {
      Text("v\(v) (\(b))  •  \(appState.baseURL)")
        .font(.system(.headline, design: .monospaced))
        .foregroundStyle(.white)
      HStack(spacing: 12) {
        // Plain Button rather than Toggle(.button): the .button toggle style does not exist
        // on tvOS. A Button reads its state in the label, works with the focus engine, and
        // behaves identically on both platforms.
        // VoiceOver: the checkmark glyph and the mutating filter label are meaningless
        // read aloud ("Errors only checkmark"), so state and behaviour are spelled out.
        Button(errorsOnly ? "Errors only ✓" : "Errors only") { errorsOnly.toggle() }
          .accessibilityLabel("Errors only")
          .accessibilityValue(errorsOnly ? "On" : "Off")
          .accessibilityHint("Shows only error entries")
        Button(filter == nil ? "All" : filter!.rawValue) { cycleFilter() }
          .accessibilityLabel("Category filter")
          .accessibilityValue(filter?.rawValue ?? "All")
          .accessibilityHint("Cycles through log categories")
        Button("Clear") {
          DiagnosticLog.shared.clear()
          entries = []
        }
        .accessibilityLabel("Clear log")
        .accessibilityHint("Deletes all diagnostic entries")
      }
      .font(.system(.caption, design: .monospaced))
      Text("\(visible.count) entries — newest first")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal)
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  private func cycleFilter() {
    let all = DiagnosticLog.Category.allCases
    guard let current = filter, let idx = all.firstIndex(of: current) else {
      filter = all.first
      return
    }
    filter = idx + 1 < all.count ? all[idx + 1] : nil
  }

  // MARK: - Row

  private func row(_ entry: DiagnosticLog.Entry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(Self.timeFormatter.string(from: entry.date))
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)

      Text(entry.level.symbol)
        .font(.system(.caption, design: .monospaced).bold())
        .foregroundStyle(color(for: entry.level))

      Text(entry.category.rawValue)
        .font(.system(.caption2, design: .monospaced).bold())
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 62, alignment: .leading)

      Text(entry.message)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(entry.level == .info ? .white : color(for: entry.level))
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
  }

  private func color(for level: DiagnosticLog.Level) -> Color {
    switch level {
    case .info: return .white
    case .warn: return .yellow
    case .error: return .red
    }
  }
}
