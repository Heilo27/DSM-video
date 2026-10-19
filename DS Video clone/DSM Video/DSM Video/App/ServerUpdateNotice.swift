import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// MARK: - FR-149 · suggest a server update when the connected server is older than this app expects
//
// This file is the ONE home for: the server version the app recommends, how server versions
// compare, whether the notice shows, what it says, and how a dismissal is remembered. The
// views (iOS card, tvOS card) and AppState only call into it.

/// The server this build of the app recommends, and where to get it.
nonisolated enum RecommendedServer {
  /// The SPK version (`MAJOR.MINOR.PATCH-BUILD`) of the newest server this app is built for.
  /// RAISE THIS whenever `version` in spk/DSVideoServer/INFO is raised; `ServerUpdateNoticeTests`
  /// fails when the two differ, so a release cannot ship with the notice pointing at an old build.
  static let version = "0.3.9-0005"

  /// The product page that carries the download. Not a GitHub release URL: those change with
  /// every release, the page does not.
  static let downloadURL = URL(string: "https://heiloprojects.com/dsmvideo/")!
  /// The same address as people type it (Apple TV cannot open it; the card shows it and a QR code).
  static let displayURL = "heiloprojects.com/dsmvideo"
}

/// A server version in the SPK format `MAJOR.MINOR.PATCH-BUILD`, e.g. `0.3.9-0002`.
/// Compared field by field as numbers, so `0.3.10-0001` is newer than `0.3.9-0002`.
nonisolated struct SPKVersion: Comparable, Equatable, Sendable {
  let major: Int
  let minor: Int
  let patch: Int
  let build: Int

  /// Nil for anything that is not exactly four numbers in that shape: "dev" (an unstamped
  /// build), an empty string, a version with no build suffix, extra segments, signs, spaces
  /// inside. An unreadable version must never read as "old" (that would nag a dev server).
  init?(_ raw: String?) {
    guard let raw else { return nil }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let halves = text.split(separator: "-", omittingEmptySubsequences: false)
    guard halves.count == 2 else { return nil }
    let core = halves[0].split(separator: ".", omittingEmptySubsequences: false)
    guard core.count == 3,
          let major = Self.number(core[0]), let minor = Self.number(core[1]),
          let patch = Self.number(core[2]), let build = Self.number(halves[1])
    else { return nil }
    self.major = major
    self.minor = minor
    self.patch = patch
    self.build = build
  }

  /// ASCII digits only; `Int("+3")` and `Int("-3")` would otherwise parse.
  private static func number(_ part: Substring) -> Int? {
    guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    return Int(part)
  }

  static func < (lhs: SPKVersion, rhs: SPKVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch, lhs.build) < (rhs.major, rhs.minor, rhs.patch, rhs.build)
  }
}

/// What the user is told: the server's version and the one the app recommends.
nonisolated struct ServerUpdateNotice: Equatable, Sendable {
  /// The version the server reported, as it reported it.
  let serverVersion: String
  /// `RecommendedServer.version` at the time of the check; the key a dismissal is remembered under.
  let recommendedVersion: String

  var title: String { "A newer DSVideo server is available" }

  /// Names both versions and why it matters. Wording is for anyone who opens the app, admin or
  /// not: the app does not know whether this account is an admin on a server this old.
  var message: String {
    "Your server is on \(serverVersion). This app works best with \(recommendedVersion), "
      + "which has fixes and new features. If you don't manage the NAS, pass this on to whoever does."
  }

  /// The steps, in order, without numbering (the views number them).
  var steps: [String] {
    [
      "Download the server package from \(RecommendedServer.displayURL).",
      "On the NAS, open Package Center and choose Manual Install.",
      "Pick the downloaded file and follow the prompts.",
    ]
  }

  var downloadButtonTitle: String { "Download Update" }
  var dismissButtonTitle: String { "Not Now" }
}

/// Whether to show the notice. Pure: everything it needs is passed in.
nonisolated enum ServerUpdatePolicy {
  /// A notice only when the server reported a readable version OLDER than `recommended`, and
  /// the user has not already dismissed the notice for this `recommended`. Equal, newer, "dev",
  /// empty and a missing version all return nil. A dismissal for an OLDER recommendation does
  /// not count: it comes back when the app recommends something newer.
  static func notice(
    serverVersion: String?,
    recommended: String = RecommendedServer.version,
    dismissedFor: String?
  ) -> ServerUpdateNotice? {
    guard let serverVersion,
          let server = SPKVersion(serverVersion),
          let target = SPKVersion(recommended),
          server < target
    else { return nil }
    if dismissedFor == recommended { return nil }
    return ServerUpdateNotice(
      serverVersion: serverVersion.trimmingCharacters(in: .whitespacesAndNewlines),
      recommendedVersion: recommended)
  }
}

/// Remembers which recommended version the user dismissed the notice for, on this device.
nonisolated struct ServerUpdateDismissal {
  static let defaultsKey = "dsReel.serverUpdateDismissedFor"

  let defaults: UserDefaults

  /// The recommended version the notice was last dismissed for; nil if never.
  var dismissedFor: String? { defaults.string(forKey: Self.defaultsKey) }

  func dismiss(recommendedVersion: String) {
    defaults.set(recommendedVersion, forKey: Self.defaultsKey)
  }
}

/// A QR code drawn on the device (CoreImage), so the Apple TV card can show a code to scan
/// with a phone. No assets and no dependencies.
nonisolated enum QRCode {
  /// A square bitmap of `message`, about `side` pixels wide. Nil only if
  /// CoreImage fails to render it. Draw it with `.interpolation(.none)` to keep it sharp.
  static func image(for message: String, side: Int = 480) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(message.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let extent = output.extent.integral
    guard extent.width > 0 else { return nil }
    // Whole-number scale so every module is the same number of pixels (a fractional scale blurs it).
    let scale = max(1, floor(CGFloat(side) / extent.width))
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return CIContext().createCGImage(scaled, from: scaled.extent)
  }
}
