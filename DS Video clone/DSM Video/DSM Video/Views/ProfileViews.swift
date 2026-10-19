import SwiftUI

// MARK: - Profile screens (FRD-002 §8: FR-260, FR-263, FR-266; AC-002-40/40a/41/43/46)
//
// One set of screens for both platforms, sized per platform. Every Button here carries a
// .focused() binding (the tvOS focus rule; scripts/check-tvos-focus.sh guards the flat
// enums below). Dynamic rows (profiles, avatars, tiers) bind String/Int focus values.
//
// Actions go through AppState only (AppState+Profiles.swift); wording comes from ProfileText.

// MARK: - Avatars

/// The apps' built-in avatar set (FR-203: a key from a fixed set, no uploads). A key the
/// app does not know (another app version's, or none) renders as the name's initial.
nonisolated enum ProfileAvatar: String, CaseIterable, Identifiable, Sendable {
  case cat, dog, hare, bird, fish, tortoise, ladybug, lizard, leaf, star, bolt, moon

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .cat: return "cat.fill"
    case .dog: return "dog.fill"
    case .hare: return "hare.fill"
    case .bird: return "bird.fill"
    case .fish: return "fish.fill"
    case .tortoise: return "tortoise.fill"
    case .ladybug: return "ladybug.fill"
    case .lizard: return "lizard.fill"
    case .leaf: return "leaf.fill"
    case .star: return "star.fill"
    case .bolt: return "bolt.fill"
    case .moon: return "moon.stars.fill"
    }
  }

  /// Display name for VoiceOver ("Cat avatar").
  var spokenName: String { rawValue.capitalized }

  /// Hue in degrees; each avatar gets its own colour so tiles read apart at a glance.
  var hue: Double {
    switch self {
    case .cat: return 18
    case .dog: return 38
    case .hare: return 330
    case .bird: return 200
    case .fish: return 185
    case .tortoise: return 140
    case .ladybug: return 0
    case .lizard: return 95
    case .leaf: return 120
    case .star: return 48
    case .bolt: return 265
    case .moon: return 228
    }
  }
}

struct ProfileAvatarView: View {
  let avatar: String
  let name: String
  var size: CGFloat

  private var known: ProfileAvatar? { ProfileAvatar(rawValue: avatar) }

  private var hue: Double {
    if let known { return known.hue }
    // Unknown key: a stable colour from the name, so the same profile always looks the same.
    let sum = name.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 360 }
    return Double(sum)
  }

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)  // literal: avatar corner scales with size (16%), so it cannot be a fixed token
      .fill(LinearGradient(
        colors: [Color(hue: hue / 360, saturation: 0.62, brightness: 0.78),
                 Color(hue: hue / 360, saturation: 0.78, brightness: 0.42)],
        startPoint: .topLeading, endPoint: .bottomTrailing))
      .frame(width: size, height: size)
      .overlay {
        if let known {
          Image(systemName: known.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
        } else {
          Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            // Deliberately outside the theme type scale (TASK-951): the initial is sized as a
            // proportion of the avatar, so it scales with the avatar, not with a text role.
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.95))
        }
      }
      .accessibilityHidden(true)
  }
}

// MARK: - Platform metrics

// tvOS type comes from the theme's TVTypeScale (TASK-1039), not hard-coded point sizes, so a
// theme change reaches the profile screens. The profile screens ran 30/60/28/44 before; they
// now sit on the nearest scale roles (28/48/24/48). Computed, not stored, so each read sees
// the current theme.
@MainActor
enum ProfileMetrics {
  #if os(tvOS)
  static let tile: CGFloat = 230
  static var tileName: Font { .dsTVSectionTitle }
  static var title: Font { .dsTVLargeTitle }
  static var body: Font { .dsTVBodyLarge }
  static let spacing: CGFloat = 56
  static let key: CGFloat = 112
  static var keyFont: Font { .dsTVLargeTitle }
  static let dot: CGFloat = 26
  #else
  static let tile: CGFloat = 112
  static let tileName: Font = .system(size: 17, weight: .semibold)
  static let title: Font = .system(size: 30, weight: .bold)
  static let body: Font = .system(size: 16, weight: .regular)
  static let spacing: CGFloat = 28
  static let key: CGFloat = 76
  static let keyFont: Font = .system(size: 32, weight: .medium, design: .rounded)
  static let dot: CGFloat = 16
  #endif
}

/// The picker/management tile: avatar lifts and gains a white ring when focused (tvOS) or
/// pressed (iOS). A custom style rather than `.plain` so tvOS draws OUR focus treatment.
private struct ProfileTileButtonStyle: ButtonStyle {
  /// false for tiles drawn by `ProfileTileLabel`, which lifts only its artwork: scaling the
  /// whole label pushed the focused tile's name and PIN caption below its neighbours'.
  var scalesLabel = true

  func makeBody(configuration: Configuration) -> some View {
    TileBody(configuration: configuration, scalesLabel: scalesLabel)
  }

  private struct TileBody: View {
    let configuration: Configuration
    let scalesLabel: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      let lifted = ProfileControlLook.isLit(isFocused: isFocused, isPressed: configuration.isPressed,
                                            isEnabled: isEnabled)
      let scale: CGFloat = !isEnabled ? 1 : (isFocused ? 1.08 : (configuration.isPressed ? 0.96 : 1))
      configuration.label
        .scaleEffect(scalesLabel ? scale : 1)
        .environment(\.profileTileLifted, lifted)
        .environment(\.profileTileScale, scale)
        .opacity(ProfileControlLook.opacity(isEnabled: isEnabled))
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
  }
}

private struct ProfileTileLiftedKey: EnvironmentKey { static let defaultValue = false }
private struct ProfileTileScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private extension EnvironmentValues {
  var profileTileLifted: Bool {
    get { self[ProfileTileLiftedKey.self] }
    set { self[ProfileTileLiftedKey.self] = newValue }
  }
  var profileTileScale: CGFloat {
    get { self[ProfileTileScaleKey.self] }
    set { self[ProfileTileScaleKey.self] = newValue }
  }
}

/// Avatar + name + optional caption, as used in every tile grid.
private struct ProfileTileLabel<Art: View>: View {
  let title: String
  var caption: String?
  var captionSymbol: String?
  @ViewBuilder let art: () -> Art
  @Environment(\.profileTileLifted) private var lifted
  @Environment(\.profileTileScale) private var scale

  var body: some View {
    VStack(spacing: 18) {
      art()
        .overlay(
          RoundedRectangle(cornerRadius: ProfileMetrics.tile * 0.16, style: .continuous)  // literal: tile corner scales with the tile size (16%), like the avatar
            .strokeBorder(.white, lineWidth: lifted ? ProfileMetrics.tile * 0.03 : 0))
        .shadow(color: .black.opacity(lifted ? 0.6 : 0), radius: 24, y: 12)
        .scaleEffect(scale)
      Text(title)
        .font(ProfileMetrics.tileName)
        .foregroundStyle(lifted ? Color.white : Color.dsTextSecondary)
        .lineLimit(1)
      Group {
        if let caption {
          Label(caption, systemImage: captionSymbol ?? "lock.fill")
            .labelStyle(.titleAndIcon)
        } else {
          Text(" ")
        }
      }
      .font(ProfileMetrics.body.weight(.medium))
      .foregroundStyle(Color.dsTextTertiary)
    }
    .frame(width: ProfileMetrics.tile + 24)
  }
}

private struct AddTileArt: View {
  var body: some View {
    RoundedRectangle(cornerRadius: ProfileMetrics.tile * 0.16, style: .continuous)  // literal: tile corner scales with the tile size (16%), like the avatar
      .strokeBorder(Color.dsTextTertiary, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
      .frame(width: ProfileMetrics.tile, height: ProfileMetrics.tile)
      .overlay(
        Image(systemName: "plus")
          .font(.system(size: ProfileMetrics.tile * 0.3, weight: .light))
          .foregroundStyle(Color.dsTextSecondary))
  }
}

private struct ProfileBackdrop: View {
  var body: some View {
    ZStack {
      Color.dsBackground
      RadialGradient(colors: [Color.dsSurfaceHigh, Color.dsBackground], center: .top,
                     startRadius: 40, endRadius: 1100)
    }
    .ignoresSafeArea()
  }
}

// MARK: - Picker (FR-260, FR-263)

struct ProfilePickerView: View {
  @Environment(AppState.self) private var appState

  enum PickerControl: Hashable { case manage }

  @State private var pinTarget: Profile?
  @State private var offlineNotice: String?
  @State private var management: ManagementEntry?
  @FocusState private var focusedProfile: String?
  @FocusState private var focusedControl: PickerControl?

  private static let addTileID = "__add__"

  var body: some View {
    let profiles = Array(appState.profiles.prefix(appState.maxProfiles))
    ZStack {
      ProfileBackdrop()
      VStack(spacing: ProfileMetrics.spacing) {
        Spacer(minLength: 0)
        Text("Who's watching?")
          .font(ProfileMetrics.title)
          .foregroundStyle(.white)
          .accessibilityAddTraits(.isHeader)

        tiles(profiles)

        if let offlineNotice {
          Label(offlineNotice, systemImage: "wifi.exclamationmark")
            .font(ProfileMetrics.body)
            .foregroundStyle(Color.dsWarning)
            .multilineTextAlignment(.center)
            .transition(.opacity)
        }

        Button {
          management = .manage
        } label: {
          Label("Manage Profiles", systemImage: "pencil")
            .font(ProfileMetrics.body.weight(.semibold))
            #if os(iOS)
            .padding(.horizontal, .dsSpaceXL).padding(.vertical, 10)
            #endif
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .focused($focusedControl, equals: .manage)
        .accessibilityHint("Requires the owner's PIN")
        .accessibilityIdentifier(A11y.Profile.Picker.manageButton)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, .dsSpaceTitleSafe)
    }
    .task { await appState.refreshProfiles() }
    .onAppear {
      if focusedProfile == nil {
        focusedProfile = appState.activeProfile?.id ?? profiles.first?.id
      }
    }
    .fullScreenCover(item: $pinTarget) { profile in
      ProfilePinEntryView(profile: profile) { pinTarget = nil }
        .environment(appState)
    }
    .fullScreenCover(item: $management) { entry in
      ProfileManagementView(startWithAdd: entry == .add) { management = nil }
        .environment(appState)
    }
  }

  @ViewBuilder
  private func tiles(_ profiles: [Profile]) -> some View {
    let content = ForEach(profiles) { profile in
      Button { choose(profile) } label: {
        ProfileTileLabel(
          title: profile.name,
          caption: profile.hasPin ? "PIN" : nil) {
            ProfileAvatarView(avatar: profile.avatar, name: profile.name,
                              size: ProfileMetrics.tile)
        }
      }
      .buttonStyle(ProfileTileButtonStyle(scalesLabel: false))
      .focused($focusedProfile, equals: profile.id)
      .accessibilityLabel(profile.name)
      .accessibilityHint(profile.hasPin ? "Protected by a PIN" : "Opens this profile")
      .accessibilityIdentifier(A11y.Profile.Picker.profileTile(named: profile.name))
    }
    let add = Group {
      if appState.canAddProfile {
        Button { management = .add } label: {
          ProfileTileLabel(title: "Add Profile") { AddTileArt() }
        }
        .buttonStyle(ProfileTileButtonStyle(scalesLabel: false))
        .focused($focusedProfile, equals: Self.addTileID)
        .accessibilityHint("Requires the owner's PIN")
        .accessibilityIdentifier(A11y.Profile.Picker.addButton)
      }
    }
    #if os(tvOS)
    HStack(alignment: .top, spacing: .dsSpaceGiant) { content; add }
      .focusSection()
    #else
    LazyVGrid(columns: [GridItem(.adaptive(minimum: ProfileMetrics.tile + 24), spacing: .dsSpaceXXL)],
              spacing: 28) { content; add }
      .frame(maxWidth: 560)
    #endif
  }

  private func choose(_ profile: Profile) {
    guard profile.hasPin else {
      offlineNotice = nil
      Task { await appState.switchProfile(to: profile) }
      return
    }
    // FR-263: a PIN can only be checked by the NAS. Say so instead of offering a pad that
    // can only fail.
    if appState.isOffline {
      withAnimation { offlineNotice = ProfileText.pinNeedsNAS }
      return
    }
    offlineNotice = nil
    pinTarget = profile
  }
}

enum ManagementEntry: String, Identifiable {
  case manage, add
  var id: String { rawValue }
}

// MARK: - PIN pad

/// What the caller decided about an entered PIN.
enum PinPadOutcome: Equatable {
  case accept
  /// Shown under the dots; the digits clear for another try.
  case reject(String)
}

/// A 4-digit pad driven by the Siri Remote on tvOS and by touch on iOS. Submits itself on
/// the 4th digit; the caller verifies (always on the server, FR-213).
struct PinPadView<Header: View>: View {
  let title: String
  var message: String?
  /// An error to show from the first frame, for a pad that was rebuilt because of the very
  /// failure it should report (NewPinView returns to its first step on a reject). The next
  /// digit clears it, like any error the pad raised itself.
  var initialError: String? = nil
  let submit: (String) async -> PinPadOutcome
  let cancel: () -> Void
  @ViewBuilder let header: () -> Header
  /// Offers "Forgot PIN?" below the keys when set. Only the owner's pad has a way back from a
  /// forgotten PIN (the DSM password, FR-216); any other profile's PIN is reset by the owner.
  var forgot: (() -> Void)? = nil

  enum PinPadKey: Hashable { case k0, k1, k2, k3, k4, k5, k6, k7, k8, k9, delete, cancel, forgot }

  @State private var digits = ""
  @State private var error: String?
  @State private var busy = false
  @FocusState private var focusedKey: PinPadKey?

  var body: some View {
    ZStack {
      ProfileBackdrop()
      VStack(spacing: ProfileMetrics.spacing * 0.6) {
        header()
        Text(title)
          .font(ProfileMetrics.title.weight(.semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
        dots
        Group {
          if let error {
            Text(error).foregroundStyle(Color.dsError)
          } else if let message {
            Text(message).foregroundStyle(Color.dsTextSecondary)
          } else {
            Text(" ")
          }
        }
        .font(ProfileMetrics.body)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 900)
        .accessibilityIdentifier(A11y.Profile.PinPad.message)
        keypad
      }
      .padding(.dsSpaceJumbo)
    }
    // Over the top edge rather than in the column: the pad already fills a TV's height and a
    // small iPhone's, so one more row would push the keys off screen.
    .overlay(alignment: .top) { forgotBar }
    .onAppear {
      focusedKey = .k1
      if error == nil { error = initialError }
    }
    #if os(tvOS)
    .onExitCommand { cancel() }
    #endif
  }

  @ViewBuilder
  private var forgotBar: some View {
    if let forgot {
      HStack {
        Spacer(minLength: 0)
        Button("Forgot PIN?", action: forgot)
          .font(ProfileMetrics.body.weight(.semibold))
          .buttonStyle(.bordered)
          .disabled(busy)
          .focused($focusedKey, equals: .forgot)
          .accessibilityIdentifier(A11y.Profile.PinPad.forgotButton)
      }
      .padding(.horizontal, ProfileMetrics.spacing)
      .padding(.top, ProfileMetrics.spacing * 0.5)
      // tvOS: a full-width section, so Up from any key in the top row lands on the button
      // even though it sits at the right edge, not directly above.
      #if os(tvOS)
      .frame(maxWidth: .infinity)
      .focusSection()
      #endif
    }
  }

  private var dots: some View {
    HStack(spacing: ProfileMetrics.dot * 1.2) {
      ForEach(0..<4, id: \.self) { i in
        Circle()
          .fill(i < digits.count ? Color.white : Color.clear)
          .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 2))
          .frame(width: ProfileMetrics.dot, height: ProfileMetrics.dot)
      }
    }
    .overlay { if busy { ProgressView().offset(y: ProfileMetrics.dot * 2) } }
    .accessibilityElement()
    .accessibilityLabel("\(digits.count) of 4 digits entered")
  }

  private var keypad: some View {
    VStack(spacing: 18) {
      HStack(spacing: 18) {
        key("1").focused($focusedKey, equals: .k1)
        key("2").focused($focusedKey, equals: .k2)
        key("3").focused($focusedKey, equals: .k3)
      }
      HStack(spacing: 18) {
        key("4").focused($focusedKey, equals: .k4)
        key("5").focused($focusedKey, equals: .k5)
        key("6").focused($focusedKey, equals: .k6)
      }
      HStack(spacing: 18) {
        key("7").focused($focusedKey, equals: .k7)
        key("8").focused($focusedKey, equals: .k8)
        key("9").focused($focusedKey, equals: .k9)
      }
      HStack(spacing: 18) {
        command("Cancel", symbol: nil, action: cancel)
          .focused($focusedKey, equals: .cancel)
          .accessibilityIdentifier(A11y.Profile.PinPad.cancelButton)
        key("0").focused($focusedKey, equals: .k0)
        command("Delete", symbol: "delete.left", action: deleteLast)
          .focused($focusedKey, equals: .delete)
          .accessibilityIdentifier(A11y.Profile.PinPad.deleteButton)
      }
    }
    .disabled(busy)
    #if os(tvOS)
    .focusSection()
    #endif
  }

  private func key(_ digit: String) -> some View {
    // focus-exempt: every caller in keypad binds it with .focused($focusedKey, equals:)
    Button { append(digit) } label: {
      Text(digit).font(ProfileMetrics.keyFont)
        .frame(width: ProfileMetrics.key, height: ProfileMetrics.key)
    }
    .buttonStyle(PinKeyStyle())
    .accessibilityIdentifier(A11y.Profile.PinPad.key(digit))
  }

  private func command(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
    // focus-exempt: every caller in keypad binds it with .focused($focusedKey, equals:)
    Button(action: action) {
      Group {
        if let symbol {
          Image(systemName: symbol).font(ProfileMetrics.keyFont.weight(.regular))
        } else {
          Text(title).font(ProfileMetrics.body.weight(.semibold))
        }
      }
      .frame(width: ProfileMetrics.key, height: ProfileMetrics.key)
    }
    .buttonStyle(PinKeyStyle(outlined: false))
    .accessibilityLabel(title)
  }

  private func append(_ digit: String) {
    guard !busy, digits.count < 4 else { return }
    digits += digit
    error = nil
    guard digits.count == 4 else { return }
    let entered = digits
    busy = true
    Task {
      let outcome = await submit(entered)
      busy = false
      switch outcome {
      case .accept:
        digits = ""
      case .reject(let message):
        error = message
        digits = ""
        focusedKey = .k1
      }
    }
  }

  private func deleteLast() {
    guard !digits.isEmpty else { return }
    digits.removeLast()
  }
}

private struct PinKeyStyle: ButtonStyle {
  var outlined = true
  func makeBody(configuration: Configuration) -> some View {
    KeyBody(configuration: configuration, outlined: outlined)
  }

  private struct KeyBody: View {
    let configuration: Configuration
    let outlined: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      let lit = ProfileControlLook.isLit(isFocused: isFocused, isPressed: configuration.isPressed,
                                         isEnabled: isEnabled)
      configuration.label
        .foregroundStyle(lit ? Color.dsBackground : Color.dsTextPrimary)
        .background(Circle().fill(lit ? Color.dsTextPrimary
                                      : Color.dsTextPrimary.opacity(outlined ? 0.1 : 0)))
        .scaleEffect(ProfileControlLook.keyScale(isFocused: isFocused, isEnabled: isEnabled))
        .opacity(ProfileControlLook.opacity(isEnabled: isEnabled))
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
    }
  }
}

/// Entering a PIN-protected profile (FR-213, AC-002-41): the server checks it every time.
struct ProfilePinEntryView: View {
  @Environment(AppState.self) private var appState
  let profile: Profile
  let dismiss: () -> Void

  var body: some View {
    PinPadView(title: "Enter the PIN for \(profile.name)") { pin in
      switch await appState.verifyProfilePin(profile, pin: pin) {
      case .success:
        dismiss()
        await appState.switchProfile(to: profile)
        return .accept
      case .failure(let error):
        return .reject(ProfileText.pinFailure(error))
      }
    } cancel: {
      dismiss()
    } header: {
      ProfileAvatarView(avatar: profile.avatar, name: profile.name, size: ProfileMetrics.tile * 0.6)
    }
  }
}

/// The two steps of choosing a PIN, as a plain value so the transitions are testable without a
/// UI runner. A rejected confirm returns to the first step and carries the reason with it:
/// `NewPinView` rebuilds the pad when the step changes, which would otherwise discard the very
/// message the reject was about to show (TASK-1063).
nonisolated struct NewPinFlow: Equatable {
  /// The first entry, held until the confirmation; nil while choosing.
  private(set) var firstPin: String?
  /// Why the flow went back to the first step; shown on the pad that replaces the old one.
  private(set) var notice: String?

  var isConfirming: Bool { firstPin != nil }

  enum Step: Equatable {
    /// First entry taken; ask for it again.
    case confirm
    /// The confirmation differs; the flow is already back at the first step.
    case reject(String)
    /// The two entries match; hand the PIN to the caller to save.
    case save(String)
  }

  mutating func enter(_ pin: String) -> Step {
    guard let firstPin else {
      firstPin = pin
      notice = nil
      return .confirm
    }
    guard firstPin == pin else {
      return rejected(ProfileText.pinMismatch)
    }
    return .save(pin)
  }

  /// The caller could not keep the PIN: back to the first step, saying why.
  mutating func saveFailed(_ message: String) {
    _ = rejected(message)
  }

  private mutating func rejected(_ message: String) -> Step {
    firstPin = nil
    notice = message
    return .reject(message)
  }
}

/// Choosing a new PIN: enter it, then enter it again. Hands the PIN to `chosen`, which
/// returns nil when it was accepted or the reason it was not.
struct NewPinView: View {
  let title: String
  let chosen: (String) async -> String?
  let cancel: () -> Void

  @State private var flow = NewPinFlow()

  var body: some View {
    PinPadView(
      title: flow.isConfirming ? "Enter it again" : title,
      message: flow.isConfirming ? "To make sure it's right." : "Choose 4 digits.",
      initialError: flow.notice
    ) { pin in
      switch flow.enter(pin) {
      case .confirm:
        return .accept
      case .reject(let reason):
        return .reject(reason)
      case .save(let pin):
        if let failure = await chosen(pin) {
          flow.saveFailed(failure)
          return .reject(failure)
        }
        return .accept
      }
    } cancel: {
      cancel()
    } header: {
      Image(systemName: "lock.fill")
        .font(.system(size: ProfileMetrics.tile * 0.25))
        .foregroundStyle(Color.dsTextSecondary)
    }
    .id(flow.isConfirming ? "confirm" : "first")
  }
}

// MARK: - Management (FR-211, FR-212, FR-266)

struct ProfileManagementView: View {
  @Environment(AppState.self) private var appState
  let startWithAdd: Bool
  let close: () -> Void

  enum ManageControl: Hashable { case done }

  /// The owner PIN for this management session only. Sent with each change because the
  /// server requires it every time (FR-211); dropped when the screen closes.
  @State private var ownerPin: String?
  @State private var editing: EditorTarget?
  /// Fixed when the screen opens, so setting the owner's first PIN (which flips `hasPin`
  /// as the list refreshes) does not swap the pad for another one mid-flow.
  @State private var ownerHadPin: Bool?
  /// The owner chose "Forgot PIN?" on the owner pad (FR-216).
  @State private var resettingPin = false
  @FocusState private var focusedProfile: String?
  @FocusState private var focusedControl: ManageControl?

  private static let addTileID = "__add__"

  private var owner: Profile? { appState.profiles.first(where: \.isOwner) }

  var body: some View {
    Group {
      if let ownerPin {
        list(ownerPin: ownerPin)
      } else if let owner, resettingPin {
        OwnerPinResetView(owner: owner) { newPin in
          resettingPin = false
          unlock(with: newPin)
        } cancel: {
          resettingPin = false
        }
      } else if let owner, ownerHadPin ?? owner.hasPin {
        PinPadView(title: "Enter the owner's PIN",
                   message: "Changing profiles needs \(owner.name)'s PIN.") { pin in
          switch await appState.verifyProfilePin(owner, pin: pin) {
          case .success:
            unlock(with: pin)
            return .accept
          case .failure(let error):
            return .reject(ProfileText.pinFailure(error))
          }
        } cancel: {
          close()
        } header: {
          ProfileAvatarView(avatar: owner.avatar, name: owner.name, size: ProfileMetrics.tile * 0.6)
        } forgot: {
          resettingPin = true
        }
      } else if let owner {
        // FR-212: the owner sets a PIN before any other profile can exist. The first PIN
        // needs no prior one, because only the account holder has a session here.
        NewPinView(title: "Set a PIN for \(owner.name)") { pin in
          switch await appState.updateProfile(id: owner.id, UpdateProfileRequest(ownerPin: nil, pin: .set(pin))) {
          case .success:
            unlock(with: pin)
            return nil
          case .failure(let error):
            return ProfileText.saveFailure(error)
          }
        } cancel: {
          close()
        }
      } else {
        unavailable
      }
    }
    .onAppear { if ownerHadPin == nil, let owner { ownerHadPin = owner.hasPin } }
    .fullScreenCover(item: $editing) { target in
      ProfileEditorView(target: target, ownerPin: ownerPin ?? "") { editing = nil }
        .environment(appState)
    }
  }

  private func unlock(with pin: String) {
    ownerPin = pin
    if startWithAdd, appState.canAddProfile {
      editing = .create
    }
  }

  private var unavailable: some View {
    ZStack {
      ProfileBackdrop()
      VStack(spacing: .dsSpaceXXXL) {
        Text("Profiles couldn't be loaded.")
          .font(ProfileMetrics.title).foregroundStyle(.white)
        Text(ProfileText.saveNeedsNAS)
          .font(ProfileMetrics.body).foregroundStyle(Color.dsTextSecondary)
        Button("Close", action: close)
          .buttonStyle(.bordered)
          .focused($focusedControl, equals: .done)
      }
    }
    .task { await appState.refreshProfiles() }
  }

  private func list(ownerPin: String) -> some View {
    let profiles = appState.profiles
    return ZStack {
      ProfileBackdrop()
      VStack(spacing: ProfileMetrics.spacing) {
        Spacer(minLength: 0)
        Text("Manage Profiles")
          .font(ProfileMetrics.title)
          .foregroundStyle(.white)
          .accessibilityAddTraits(.isHeader)
        let tiles = Group {
          ForEach(profiles) { profile in
            Button { editing = .edit(profile) } label: {
              ProfileTileLabel(title: profile.name,
                               caption: appState.ageLevelLabel(profile.maxAgeLevel),
                               captionSymbol: profile.hasPin ? "lock.fill" : "person.fill") {
                ProfileAvatarView(avatar: profile.avatar, name: profile.name, size: ProfileMetrics.tile)
                  .overlay {
                    Image(systemName: "pencil")
                      .font(.system(size: ProfileMetrics.tile * 0.22, weight: .semibold))
                      .foregroundStyle(.white)
                      .frame(width: ProfileMetrics.tile, height: ProfileMetrics.tile)
                      .background(.black.opacity(0.45),
                                  in: RoundedRectangle(cornerRadius: ProfileMetrics.tile * 0.16, style: .continuous))  // literal: tile corner scales with the tile size (16%), like the avatar
                  }
              }
            }
            .buttonStyle(ProfileTileButtonStyle(scalesLabel: false))
            .focused($focusedProfile, equals: profile.id)
            .accessibilityLabel("Edit \(profile.name)")
            .accessibilityIdentifier(A11y.Profile.Manage.profileRow(named: profile.name))
          }
          if appState.canAddProfile {
            Button { editing = .create } label: {
              ProfileTileLabel(title: "Add Profile") { AddTileArt() }
            }
            .buttonStyle(ProfileTileButtonStyle(scalesLabel: false))
            .focused($focusedProfile, equals: Self.addTileID)
            .accessibilityIdentifier(A11y.Profile.Manage.addButton)
          }
        }
        #if os(tvOS)
        HStack(alignment: .top, spacing: .dsSpaceGiant) { tiles }.focusSection()
        #else
        LazyVGrid(columns: [GridItem(.adaptive(minimum: ProfileMetrics.tile + 24), spacing: .dsSpaceXXL)],
                  spacing: 28) { tiles }
          .frame(maxWidth: 560)
        #endif
        // The quiet action under the tiles: dsSecondaryButton (TASK-1050). It was a white-on-black
        // system fill (introduced with the screens in TASK-917; no spec records why), now the
        // shared secondary look so it is one component, not a one-off.
        Button("Done", action: close)
          .dsSecondaryButton(minWidth: 200)
          .focused($focusedControl, equals: .done)
          .accessibilityIdentifier(A11y.Profile.Manage.doneButton)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, .dsSpaceTitleSafe)
    }
    .onAppear { if focusedProfile == nil { focusedProfile = profiles.first?.id } }
    #if os(tvOS)
    .onExitCommand { close() }
    #endif
  }
}

// MARK: - Owner PIN reset (FR-216, TASK-1016)

/// What the owner-PIN reset sends and what it shows, held apart from the view so both can be
/// tested without rendering it. DSM checks the password on the server; the words for a refusal
/// come from ProfileText, the one home for the profile screens' errors.
struct OwnerPinReset {
  /// Sent as typed, never trimmed: a DSM password may begin or end with a space.
  var password = ""
  /// The DSM verification code. Blank for an account without two-factor sign-in.
  var code = ""
  /// The new 4-digit PIN, once chosen (and confirmed) on the PIN pad.
  var newPin: String?

  enum Outcome: Equatable {
    /// The owner's PIN is now this one.
    case reset(String)
    /// Nothing changed; show this.
    case refused(String)
    /// No password or no new PIN yet: nothing was sent.
    case incomplete
  }

  /// The code as sent: spaces dropped (codes are often typed or pasted as "123 456"); nil
  /// when blank, so an account without two-factor sign-in sends no code.
  var otp: String? {
    let digits = code.filter { !$0.isWhitespace }
    return digits.isEmpty ? nil : digits
  }

  var canSubmit: Bool { !password.isEmpty && newPin != nil }

  @MainActor
  func perform(on appState: AppState) async -> Outcome {
    guard let newPin, canSubmit else { return .incomplete }
    switch await appState.resetOwnerPin(password: password, otp: otp, newPin: newPin) {
    case .success: return .reset(newPin)
    case .failure(let error): return .refused(ProfileText.saveFailure(error))
    }
  }
}

/// "Forgot PIN?" on the owner pad (FR-216): the account's DSM password, its verification code
/// when it has two-factor sign-in, and a new PIN chosen twice on the pad. A refusal is shown
/// here, beside the fields that fix it, and keeps what was typed.
struct OwnerPinResetView: View {
  @Environment(AppState.self) private var appState
  let owner: Profile
  let done: (String) -> Void
  let cancel: () -> Void

  enum OwnerPinResetControl: Hashable { case password, code, choosePin, reset, cancel }

  @State private var form = OwnerPinReset()
  @State private var choosingPin = false
  @State private var sending = false
  @State private var error: String?
  @FocusState private var focusedField: OwnerPinResetControl?

  var body: some View {
    ZStack {
      ProfileBackdrop()
      ScrollView {
        VStack(alignment: .leading, spacing: ProfileMetrics.spacing * 0.6) {
          HStack(spacing: ProfileMetrics.spacing * 0.6) {
            ProfileAvatarView(avatar: owner.avatar, name: owner.name, size: ProfileMetrics.tile * 0.5)
            Text("Reset the Owner's PIN")
              .font(ProfileMetrics.title)
              .foregroundStyle(.white)
              .accessibilityAddTraits(.isHeader)
          }
          Text(ProfileText.ownerPinResetIntro(name: owner.name))
            .font(ProfileMetrics.body)
            .foregroundStyle(Color.dsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900, alignment: .leading)

          SecureField("DSM password", text: $form.password)
            .textContentType(.password)
            .focused($focusedField, equals: .password)
            #if os(iOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .frame(maxWidth: 700)
            .accessibilityIdentifier(A11y.Profile.OwnerPinReset.passwordField)
          TextField("Verification code (two-factor sign-in only)", text: $form.code)
            .textContentType(.oneTimeCode)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
            #endif
            .focused($focusedField, equals: .code)
            .frame(maxWidth: 700)
            .accessibilityIdentifier(A11y.Profile.OwnerPinReset.codeField)

          // tvOS: full-width focus sections, as in the editor, so Down always finds the row.
          #if os(tvOS)
          pinRow
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
          #else
          pinRow
          #endif

          if let error {
            Text(error)
              .font(ProfileMetrics.body)
              .foregroundStyle(Color.dsError)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier(A11y.Profile.OwnerPinReset.error)
          }

          HStack(spacing: 28) {
            Button {
              Task { await send() }
            } label: {
              Text(sending ? "Resetting…" : "Reset PIN")
            }
            .dsPrimaryButton(.card, minWidth: 160)
            .disabled(!form.canSubmit || sending)
            .focused($focusedField, equals: .reset)
            .accessibilityIdentifier(A11y.Profile.OwnerPinReset.resetButton)

            Button("Cancel", action: cancel)
              .buttonStyle(.bordered)
              .focused($focusedField, equals: .cancel)
              .accessibilityIdentifier(A11y.Profile.OwnerPinReset.cancelButton)
          }
          .font(ProfileMetrics.body.weight(.semibold))
          #if os(tvOS)
          .frame(maxWidth: .infinity, alignment: .leading)
          .focusSection()
          #endif
        }
        .padding(.horizontal, ProfileMetrics.spacing * 1.4)
        .padding(.vertical, ProfileMetrics.spacing)
      }
    }
    .fullScreenCover(isPresented: $choosingPin) {
      NewPinView(title: "New PIN for \(owner.name)") { pin in
        form.newPin = pin
        error = nil
        choosingPin = false
        return nil
      } cancel: {
        choosingPin = false
      }
    }
    #if os(tvOS)
    .onExitCommand { cancel() }
    #endif
  }

  private var pinRow: some View {
    HStack(spacing: 24) {
      Text(form.newPin == nil ? "New PIN: not chosen" : "New PIN: chosen")
        .font(ProfileMetrics.body)
        .foregroundStyle(.white)
      Button(form.newPin == nil ? "Choose New PIN" : "Change New PIN") { choosingPin = true }
        .buttonStyle(.bordered)
        .focused($focusedField, equals: .choosePin)
        .accessibilityIdentifier(A11y.Profile.OwnerPinReset.choosePin)
    }
    .font(ProfileMetrics.body.weight(.semibold))
  }

  private func send() async {
    sending = true
    defer { sending = false }
    switch await form.perform(on: appState) {
    case .reset(let pin): done(pin)
    case .refused(let message): error = message
    case .incomplete: break
    }
  }
}

enum EditorTarget: Identifiable, Equatable {
  case create
  case edit(Profile)
  var id: String {
    switch self {
    case .create: return "create"
    case .edit(let p): return p.id
    }
  }
}

// MARK: - Editor

struct ProfileEditorView: View {
  @Environment(AppState.self) private var appState
  let target: EditorTarget
  let ownerPin: String
  let close: () -> Void

  enum EditorControl: Hashable { case name, pinSet, pinRemove, save, delete, cancel }
  private static let bottomAnchor = "profileEditor.bottom"

  /// The form's side inset. 80pt is a 10-foot margin; on a 402pt phone it left the form 242pt,
  /// too narrow for Save and Cancel to share a row (TASK-1066), so a phone gets the screen-edge
  /// gutter. Read by ProfileEditorLayoutTests, which sizes the action rows to the width it leaves.
  static var sideInset: CGFloat {
    #if os(tvOS)
    .dsSpaceColossal
    #else
    .dsSpaceGutter
    #endif
  }

  @State private var name = ""
  @State private var avatar = ProfileAvatar.cat.rawValue
  @State private var level = 1
  /// nil = leave as is (edit) / no PIN (create).
  @State private var pinChange: PinChange?
  @State private var choosingPin = false
  @State private var confirmingDelete = false
  @State private var saving = false
  @State private var error: String?
  @FocusState private var focusedControl: EditorControl?
  @FocusState private var focusedAvatar: String?
  @FocusState private var focusedLevel: Int?

  private var existing: Profile? {
    if case .edit(let p) = target { return p }
    return nil
  }
  private var isOwner: Bool { existing?.isOwner ?? false }
  private var trimmedName: String { ProfileNameRules.trimmed(name) }
  private var nameValid: Bool { ProfileNameRules.isValid(name) }

  /// Whether the profile will have a PIN after saving.
  private var willHavePin: Bool {
    switch pinChange {
    case .set?: return true
    case .clear?: return false
    case nil: return existing?.hasPin ?? false
    }
  }

  var body: some View {
    ZStack {
      ProfileBackdrop()
      ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: ProfileMetrics.spacing * 0.7) {
          Text(existing == nil ? "Add Profile" : "Edit Profile")
            .font(ProfileMetrics.title)
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)

          HStack(alignment: .center, spacing: .dsSpaceJumbo) {
            ProfileAvatarView(avatar: avatar, name: trimmedName.isEmpty ? "?" : trimmedName,
                              size: ProfileMetrics.tile * 0.8)
            VStack(alignment: .leading, spacing: 10) {
              sectionLabel("Name")
              TextField("Name", text: $name)
                .textContentType(.name)
                .autocorrectionDisabled()
                .focused($focusedControl, equals: .name)
                #if os(iOS)
                .textFieldStyle(.roundedBorder)
                #endif
                .frame(maxWidth: 700)
                .accessibilityIdentifier(A11y.Profile.Editor.nameField)
              nameFeedback
            }
          }

          sectionLabel("Avatar")
          avatarRow

          sectionLabel("Age rating")
          if isOwner {
            Text("\(appState.ageLevelLabel(ProfileScope.unrestrictedLevel) ?? "Adult"). The owner profile sees every title, so it can manage them all.")
              .font(ProfileMetrics.body).foregroundStyle(Color.dsTextSecondary)
          } else {
            levelRow
          }

          sectionLabel("PIN")
          // tvOS: the focus engine moves only to a control directly below the current one.
          // The level row ends at the right and the PIN and action rows start at the left, so
          // without full-width focus sections Down stalled on the last level and Save, Cancel
          // and Delete were unreachable (TVProfileEditorReachabilityTests).
          #if os(tvOS)
          pinControls
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
          #else
          pinControls
          #endif

          if let error {
            Text(error)
              .font(ProfileMetrics.body)
              .foregroundStyle(Color.dsError)
              .accessibilityIdentifier(A11y.Profile.Editor.error)
          }

          ProfileEditorActions(
            saveTitle: saving ? "Saving…" : "Save",
            canSave: nameValid && !saving,
            showsDelete: existing.map { !$0.isOwner } ?? false,
            focus: $focusedControl,
            onSave: { Task { await save() } },
            onCancel: close,
            onDelete: { confirmingDelete = true })
          Color.clear.frame(height: 1).id(Self.bottomAnchor)
        }
        .padding(.horizontal, Self.sideInset)
        .padding(.vertical, .dsSpaceTitleSafe)
      }
      #if DEBUG
      // QA hook (-UITestProfileEditorScroll bottom): the bottom of the form, for screenshots.
      .task {
        guard ProfileScreenPreview.editorScrollsToBottom else { return }
        try? await Task.sleep(for: .milliseconds(600))
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
      }
      #endif
      }
    }
    .onAppear(perform: load)
    .task { await appState.loadAgeLevelsIfNeeded() }
    .fullScreenCover(isPresented: $choosingPin) {
      NewPinView(title: existing.map { "New PIN for \($0.name)" } ?? "Choose a PIN") { pin in
        pinChange = .set(pin)
        choosingPin = false
        return nil
      } cancel: {
        choosingPin = false
      }
    }
    .alert(ProfileDeleteConfirmation(profile: existing).title,
           isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) { Task { await resolveDelete(.delete) } }
      Button("Cancel", role: .cancel) { Task { await resolveDelete(.cancel) } }
    } message: {
      Text(ProfileDeleteConfirmation(profile: existing).message)
    }
    #if os(tvOS)
    .onExitCommand { close() }
    #endif
  }

  /// The count against the limit, and the reason Save is off while the name is empty or too long
  /// (TASK-952). Without it the button just greyed out.
  private var nameFeedback: some View {
    let reason = ProfileNameRules.reason(for: name)
    let over = !nameValid && !trimmedName.isEmpty
    return HStack(alignment: .firstTextBaseline, spacing: .dsSpaceLG) {
      if let reason {
        Text(reason)
          .foregroundStyle(over ? Color.dsError : Color.dsTextSecondary)
          .accessibilityIdentifier(A11y.Profile.Editor.nameReason)
      }
      Spacer(minLength: 0)
      Text(ProfileNameRules.counter(for: name))
        .monospacedDigit()
        .foregroundStyle(over ? Color.dsError : Color.dsTextTertiary)
        .accessibilityIdentifier(A11y.Profile.Editor.nameCounter)
    }
    .font(ProfileMetrics.body)
    .frame(maxWidth: 700)
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(ProfileMetrics.body.weight(.semibold))
      .tracking(1.5)
      .foregroundStyle(Color.dsTextTertiary)
  }

  private var avatarRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 28) {
        ForEach(ProfileAvatar.allCases) { choice in
          Button { avatar = choice.rawValue } label: {
            ProfileAvatarView(avatar: choice.rawValue, name: name, size: ProfileMetrics.tile * 0.5)
              .overlay(
                RoundedRectangle(cornerRadius: ProfileMetrics.tile * 0.08, style: .continuous)  // literal: tile corner scales with the tile size (8%)
                  .strokeBorder(.white, lineWidth: avatar == choice.rawValue ? 4 : 0))
              .padding(.dsSpaceSM)
          }
          .buttonStyle(ProfileTileButtonStyle())
          .focused($focusedAvatar, equals: choice.rawValue)
          .accessibilityLabel("\(choice.spokenName) avatar")
          .accessibilityAddTraits(avatar == choice.rawValue ? .isSelected : [])
        }
      }
      .padding(.vertical, .dsSpaceXL)
      .padding(.horizontal, .dsSpaceSM)
    }
    #if os(tvOS)
    .focusSection()
    #endif
  }

  @ViewBuilder
  private var levelRow: some View {
    #if os(tvOS)
    HStack(spacing: .dsSpaceXL) {
      ForEach(1...ProfileScope.unrestrictedLevel, id: \.self) { value in
        Button { level = value } label: {
          Text(appState.ageLevelLabel(value) ?? "Level \(value)")
            .font(ProfileMetrics.body.weight(.semibold))
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(Capsule().fill(level == value ? Color.white : Color.white.opacity(0.1)))
            .foregroundStyle(level == value ? Color.black : Color.white)
        }
        .buttonStyle(ProfileTileButtonStyle())
        .focused($focusedLevel, equals: value)
        .accessibilityAddTraits(level == value ? .isSelected : [])
        .accessibilityIdentifier(A11y.Profile.Editor.level(value))
      }
    }
    .focusSection()
    // Four capsules fit across a TV, their certifications don't: name the ratings of the
    // level under focus (else the chosen one) on one line below the row.
    if let ratings = appState.ageLevelRatings(focusedLevel ?? level) {
      Text(ratings.unbreakableRatings)
        .font(ProfileMetrics.body)
        .foregroundStyle(Color.dsTextSecondary)
    }
    #else
    // A vertical list on iPhone: four capsules side by side left each label too narrow to
    // draw, so the row showed four blank bars. Each row names the ratings it allows.
    VStack(spacing: 10) {
      ForEach(1...ProfileScope.unrestrictedLevel, id: \.self) { value in
        let selected = level == value
        Button { level = value } label: {
          HStack(spacing: .dsSpaceMD) {
            VStack(alignment: .leading, spacing: .dsSpaceXXS) {
              Text(appState.ageLevelLabel(value) ?? "Level \(value)")
                .font(ProfileMetrics.body.weight(.semibold))
              if let ratings = appState.ageLevelRatings(value) {
                Text(ratings.unbreakableRatings)
                  .font(.footnote)
                  .foregroundStyle(selected ? Color.black.opacity(0.6) : Color.dsTextSecondary)
              }
            }
            Spacer(minLength: 0)
            if selected {
              Image(systemName: "checkmark").font(.body.weight(.semibold))
            }
          }
          .padding(.horizontal, 18).padding(.vertical, .dsSpaceMD)
          .frame(maxWidth: 520, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: .dsRadiusMd)
            .fill(selected ? Color.white : Color.white.opacity(0.1)))
          .foregroundStyle(selected ? Color.black : Color.white)
          .contentShape(RoundedRectangle(cornerRadius: .dsRadiusMd))
        }
        .buttonStyle(ProfileTileButtonStyle())
        .focused($focusedLevel, equals: value)
        .accessibilityAddTraits(level == value ? .isSelected : [])
        .accessibilityIdentifier(A11y.Profile.Editor.level(value))
      }
    }
    #endif
  }

  @ViewBuilder
  private var pinControls: some View {
    let ownerKeepsPin = isOwner && appState.profiles.count > 1
    ProfilePinRow(
      hasPin: willHavePin,
      showsRemove: willHavePin && !ownerKeepsPin,
      focus: $focusedControl,
      onSetOrChange: { choosingPin = true },
      onRemove: { pinChange = existing?.hasPin == true ? .clear : nil })
    if ownerKeepsPin {
      Text("The owner's PIN protects profile changes, so it stays while other profiles exist.")
        .font(ProfileMetrics.body).foregroundStyle(Color.dsTextTertiary)
    }
  }

  private func load() {
    guard let existing else {
      let taken = Set(appState.profiles.map(\.avatar))
      avatar = (ProfileAvatar.allCases.first { !taken.contains($0.rawValue) } ?? .cat).rawValue
      level = 1
      return
    }
    name = existing.name
    avatar = existing.avatar
    level = existing.maxAgeLevel
  }

  private func save() async {
    saving = true
    defer { saving = false }
    let result: Result<Profile, Error>
    if let existing {
      var change = UpdateProfileRequest(ownerPin: ownerPin)
      if trimmedName != existing.name { change.name = trimmedName }
      if avatar != existing.avatar { change.avatar = avatar }
      if !existing.isOwner, level != existing.maxAgeLevel { change.maxAgeLevel = level }
      change.pin = pinChange
      result = await appState.updateProfile(id: existing.id, change)
    } else {
      var newPin: String?
      if case .set(let pin)? = pinChange { newPin = pin }
      result = await appState.createProfile(ownerPin: ownerPin, name: trimmedName, avatar: avatar,
                                            maxAgeLevel: level, pin: newPin)
    }
    switch result {
    case .success: close()
    case .failure(let failure): error = ProfileText.saveFailure(failure)
    }
  }

  private func resolveDelete(_ choice: ProfileDeleteConfirmation.Choice) async {
    if choice == .delete { saving = true }
    defer { saving = false }
    switch await ProfileDeleteConfirmation(profile: existing)
      .perform(choice, on: appState, ownerPin: ownerPin) {
    case nil: break
    case .success?: close()
    case .failure(let failure)?: error = ProfileText.saveFailure(failure)
    }
  }
}

// MARK: - Delete confirmation (FR-206, FR-266, AC-002-46, OC-2040)

/// What the delete confirmation says and what each of its two buttons does, held apart from
/// the view so both can be tested without rendering it. Cancel must never reach the server.
struct ProfileDeleteConfirmation {
  let profile: Profile?

  enum Choice { case delete, cancel }

  var title: String { profile.map { "Delete \($0.name)?" } ?? "Delete profile?" }
  var message: String { ProfileText.deleteConfirmation(name: profile?.name ?? "This profile") }

  /// Runs the chosen button. `.cancel` returns nil without any request; `.delete` deletes
  /// the profile (the destructive call, FR-206) and returns the server's answer.
  @MainActor
  func perform(_ choice: Choice, on appState: AppState, ownerPin: String) async -> Result<Void, Error>? {
    switch choice {
    case .cancel:
      return nil
    case .delete:
      guard let profile else { return nil }
      return await appState.deleteProfile(id: profile.id, ownerPin: ownerPin)
    }
  }
}

// MARK: - Home badge

/// The active profile's avatar on home; selecting it opens the picker (FR-260 "Switch
/// profile"). Hidden for single-profile accounts, which behave as before (FR-205).
struct ActiveProfileBadge: View {
  @Environment(AppState.self) private var appState
  var size: CGFloat
  @FocusState private var focused: Bool

  init(size: CGFloat) { self.size = size }

  var body: some View {
    if appState.profiles.count > 1, let profile = appState.activeProfile {
      Button {
        appState.notePickerTrigger(.switchRequested)
      } label: {
        ProfileAvatarView(avatar: profile.avatar, name: profile.name, size: size)
          #if os(iOS)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
          #endif
      }
      .focused($focused)
      .accessibilityLabel("Profile: \(profile.name)")
      .accessibilityHint("Switch profile")
      .accessibilityIdentifier(A11y.Profile.activeProfileChip)
    }
  }
}

// MARK: - Settings entry (FR-205, FR-211, FR-266)

/// The Settings row that opens profile management. Present whenever the account's owner is
/// known, including a single-profile account (`AppState.canManageProfiles`): that account has
/// no picker, so this is its only way to "Add Profile". The owner's PIN is asked first (or set
/// first, FR-212) by `ProfileManagementView` itself. Shared by iOS and tvOS Settings.
struct ManageProfilesSettingsRow: View {
  @Environment(AppState.self) private var appState
  @State private var management: ManagementEntry?
  @FocusState private var focused: Bool

  var body: some View {
    if appState.canManageProfiles {
      Button {
        management = .manage
      } label: {
        Label("Manage Profiles", systemImage: "person.crop.circle.badge.plus")
      }
      .focused($focused)
      .accessibilityHint("Add, edit or remove profiles. Requires the owner's PIN")
      .accessibilityIdentifier(A11y.Profile.manageProfilesRow)
      .fullScreenCover(item: $management) { entry in
        ProfileManagementView(startWithAdd: entry == .add) { management = nil }
          .environment(appState)
      }
    }
  }
}

// MARK: - Restricted empty state (FR-265, AC-002-47)

/// Shown instead of "no videos" when the active profile has an age limit. Names the level so
/// it reads apart from an empty library and from a load failure.
struct RestrictedEmptyState: View {
  @Environment(AppState.self) private var appState
  let profile: Profile
  let place: String

  init(profile: Profile, place: String) {
    self.profile = profile
    self.place = place
  }

  var body: some View {
    DSContentUnavailable(
      title: "Nothing at This Age Rating",
      systemImage: "figure.and.child.holdinghands",
      description: ProfileText.restrictedEmpty(
        levelLabel: appState.ageLevelLabel(profile.maxAgeLevel), place: place))
    .task { await appState.loadAgeLevelsIfNeeded() }
    .accessibilityIdentifier(A11y.Profile.restrictedEmptyState)
  }
}

#if DEBUG
// MARK: - QA hook

/// `-UITestProfileScreen picker|pin|editor`: renders that screen with fixture profiles and no
/// session, so the screens can be walked and captured on a simulator without a NAS that has
/// several profiles. DEBUG builds only. With no session every server call fails as
/// "unreachable", which is itself one of the states to check (FR-263).
enum ProfileScreenPreview: String {
  case picker, pin, editor

  static var requested: ProfileScreenPreview? {
    let args = ProcessInfo.processInfo.arguments
    guard let flag = args.firstIndex(of: "-UITestProfileScreen"),
          args.index(after: flag) < args.endIndex else { return nil }
    return ProfileScreenPreview(rawValue: args[args.index(after: flag)])
  }

  /// `-UITestProfileEditorScroll bottom`: opens the editor scrolled to its action row.
  static var editorScrollsToBottom: Bool {
    let args = ProcessInfo.processInfo.arguments
    guard let flag = args.firstIndex(of: "-UITestProfileEditorScroll"),
          args.index(after: flag) < args.endIndex else { return false }
    return args[args.index(after: flag)] == "bottom"
  }

  static let fixtures: [Profile] = [
    Profile(id: "pf_owner", name: "Ryan", avatar: "moon", maxAgeLevel: 4, hasPin: true, isOwner: true),
    Profile(id: "pf_maya", name: "Maya", avatar: "cat", maxAgeLevel: 2, hasPin: false, isOwner: false),
    Profile(id: "pf_leo", name: "Leo", avatar: "bolt", maxAgeLevel: 3, hasPin: true, isOwner: false),
  ]

  static let levels: [AgeLevelsResponse.Level] = [
    .init(level: 1, key: "littleKids", label: "Little Kids", movie: ["G"], tv: ["TV-Y", "TV-G"]),
    .init(level: 2, key: "olderKids", label: "Older Kids", movie: ["PG"], tv: ["TV-Y7", "TV-PG"]),
    .init(level: 3, key: "teens", label: "Teens", movie: ["PG-13"], tv: ["TV-14"]),
    .init(level: 4, key: "adult", label: "Adult", movie: ["R", "NC-17"], tv: ["TV-MA"]),
  ]
}

struct ProfileScreenPreviewHost: View {
  @Environment(AppState.self) private var appState
  let screen: ProfileScreenPreview

  init(screen: ProfileScreenPreview) {
    self.screen = screen
    ActiveProfileStore.shared.setCachedProfiles(ProfileScreenPreview.fixtures)
  }

  var body: some View {
    Group {
      switch screen {
      case .picker:
        ProfilePickerView()
      case .pin:
        ProfilePinEntryView(profile: ProfileScreenPreview.fixtures[2]) {}
      case .editor:
        ProfileEditorView(target: .edit(ProfileScreenPreview.fixtures[1]), ownerPin: "") {}
      }
    }
    .onAppear { appState.seedAgeLevelsForPreview(ProfileScreenPreview.levels) }
  }
}
#endif

extension String {
  /// Display only: keeps "TV-Y7" and "8\u{2013}12" in one piece when a large Dynamic Type size
  /// wraps an age-rating subtitle, so it breaks between the " · " / ", " separated tokens and
  /// never inside one (TASK-1066). The model string itself (`AppState.ageLevelRatings`) is
  /// untouched: tests, accessibility and the server mapping read that.
  var unbreakableRatings: String {
    replacingOccurrences(of: "-", with: "\u{2011}")
      .replacingOccurrences(of: "\u{2013}", with: "\u{2060}\u{2013}\u{2060}")
  }
}
