import SwiftUI

// MARK: - FR-149 · the "update your server" notice
//
// The wording, the decision and the dismissal live in App/ServerUpdateNotice.swift. These views
// only draw a ServerUpdateNotice and report two taps: download (iPhone/iPad) and not now.

/// The numbered steps, shared by the iPhone card and the Apple TV card so the order cannot differ.
private struct ServerUpdateSteps: View {
  let steps: [String]
  let font: Font

  var body: some View {
    VStack(alignment: .leading, spacing: .dsSpaceXS) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        Text("\(index + 1). \(step)")
          .font(font)
          .foregroundStyle(Color.dsTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: iPhone and iPad

/// The card over the top of the iPhone/iPad app. Never blocks: the app underneath keeps working.
/// "Download Update" opens the product page in the browser; "Not Now" hides it until the app
/// recommends a newer server.
struct ServerUpdateCard: View {
  let notice: ServerUpdateNotice
  let onDismiss: () -> Void

  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: .dsSpaceSM) {
      Text(notice.title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.dsTextPrimary)
        .accessibilityIdentifier(A11y.Shared.serverUpdateTitle)
      Text(notice.message)
        .font(.footnote)
        .foregroundStyle(Color.dsTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      ServerUpdateSteps(steps: notice.steps, font: .footnote)
      HStack(spacing: .dsSpaceMD) {
        // focus-exempt: iOS-only card; ContentView builds only TVMainView on tvOS (this one is drawn by MainView).
        Button(notice.downloadButtonTitle) { openURL(RecommendedServer.downloadURL) }
          .dsPrimaryButton(.card)
          .accessibilityIdentifier(A11y.Shared.serverUpdateDownload)
        Button(notice.dismissButtonTitle, action: onDismiss)
          // focus-exempt: iOS-only card; ContentView builds only TVMainView on tvOS (this one is drawn by MainView).
          .dsSecondaryButton()
          .accessibilityIdentifier(A11y.Shared.serverUpdateDismiss)
      }
      .padding(.top, .dsSpaceXS)
    }
    .padding(.dsSpaceLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.dsSurfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .padding(.horizontal, .dsSpaceLG)
    .padding(.top, .dsSpaceSM)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(A11y.Shared.serverUpdateCard)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}

// MARK: Apple TV

#if os(tvOS)

/// Focus targets for the Apple TV card's button (`fastlane check_focus` reads this enum).
private enum ServerUpdateControl: Hashable {
  case dismiss
}

/// The Apple TV card. A TV cannot open a web page, so it shows the short address, the steps and
/// a QR code to scan with a phone. "Not Now" is the one control; it is bound with `.focused`.
struct TVServerUpdateCard: View {
  let notice: ServerUpdateNotice
  let onDismiss: () -> Void

  @FocusState private var control: ServerUpdateControl?

  var body: some View {
    HStack(alignment: .top, spacing: .dsSpaceHuge) {
      VStack(alignment: .leading, spacing: .dsSpaceLG) {
        Text(notice.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(Color.dsTextPrimary)
          .accessibilityIdentifier(A11y.Shared.serverUpdateTitle)
        Text(notice.message)
          .font(.callout)
          .foregroundStyle(Color.dsTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        ServerUpdateSteps(steps: notice.steps, font: .callout)
        Button(notice.dismissButtonTitle, action: onDismiss)
          .dsSecondaryButton(minWidth: 280)
          .focused($control, equals: .dismiss)
          .accessibilityIdentifier(A11y.Shared.serverUpdateDismiss)
      }
      VStack(spacing: .dsSpaceSM) {
        if let code = QRCode.image(for: RecommendedServer.downloadURL.absoluteString) {
          Image(decorative: code, scale: 1)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 220, height: 220)
            .padding(.dsSpaceMD)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        Text(RecommendedServer.displayURL)
          .font(.callout.weight(.semibold))
          .foregroundStyle(Color.dsTextPrimary)
      }
      .accessibilityElement(children: .combine)
    }
    .padding(.dsSpaceXXL)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.dsSurfaceRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .padding(.horizontal, .dsSpaceTitleSafe)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(A11y.Shared.serverUpdateCard)
  }
}

#endif
