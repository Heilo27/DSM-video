import XCTest

/// The Debug build carries BOTH halves of the deep-link flow.
///
/// TASK-861 recorded that the `dsvideo://` path could not be exercised at all, because the
/// two things needed were mutually exclusive by construction: demo content existed only in
/// Debug, and CFBundleURLTypes reached the bundle only in Release. A Debug build had a
/// library and no URL scheme; a Release build had the scheme and booted to an empty pairing
/// screen. Neither build could do both.
///
/// TASK-860 removed that: the tvOS target now sets GENERATE_INFOPLIST_FILE = NO and points
/// at a checked-in Info.plist in BOTH configurations, so a Debug build registers the scheme
/// and honours the demo hook together.
///
/// What is asserted here is deliberately narrow — the two halves coexisting — because that
/// is the defect. Navigation ITSELF is not asserted: the handler clears
/// `pendingDeepLinkItemID` as soon as it routes (TVMainView.swift:395-408), so the state a
/// test could read is gone by the time it could read it. A test that pretended to verify
/// the navigation would be asserting nothing while looking like it asserted something,
/// which is the failure mode the rest of this suite exists to avoid.
///
/// Note on what was NOT changed: the demo bootstrap stays behind `#if DEBUG`. TASK-861
/// suggested a build-setting flag instead, but a demo-content hook compiled into a Release
/// build is a genuine hazard and a launch-argument check is not a substitute for the
/// compile-time gate. The mutual exclusion was the defect; the gating was never the problem.
final class TVDeepLinkTests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// The running build declares the `dsvideo` URL scheme.
  ///
  /// Read from the LAUNCHED APP's own bundle, not from the project file — the project file
  /// is exactly what was wrong before (Debug auto-generated its Info.plist and dropped the
  /// key), so trusting it here would re-assert the bug rather than catch it.
  func testTheRunningBuildRegistersTheDSVideoScheme() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the tvOS app did not launch")

    // Locate the INSTALLED app, not a path derived from the test bundle: a UI test bundle
    // lives inside the runner's PlugIns, so walking up from it lands nowhere near the app.
    // The runner's own container is a sibling of the app's under the simulator's
    // Bundle/Application directory, so search from there for the real .app.
    let runner = Bundle(for: type(of: self)).bundleURL
    let applicationsRoot = runner
      .deletingLastPathComponent()  // .../<uuid>/DSM Video tvOSUITests-Runner.app/PlugIns
      .deletingLastPathComponent()  // .../<uuid>/DSM Video tvOSUITests-Runner.app
      .deletingLastPathComponent()  // .../<uuid>
      .deletingLastPathComponent()  // .../Bundle/Application

    let fm = FileManager.default
    var appPlistURL: URL?
    if let containers = try? fm.contentsOfDirectory(
      at: applicationsRoot, includingPropertiesForKeys: nil
    ) {
      for container in containers {
        // The tvOS product is "DSM Video tvOS.app" — the iOS one is "DSM Video.app", and
        // matching that name here finds nothing (they install to different simulators).
        let candidate = container.appendingPathComponent("DSM Video tvOS.app/Info.plist")
        if fm.fileExists(atPath: candidate.path) {
          appPlistURL = candidate
          break
        }
      }
    }

    guard let appPlistURL, let plist = NSDictionary(contentsOf: appPlistURL) else {
      XCTFail("Could not locate the installed tvOS app's Info.plist under \(applicationsRoot.path)")
      return
    }

    guard let urlTypes = plist["CFBundleURLTypes"] as? [[String: Any]] else {
      XCTFail(
        "The built tvOS app declares NO CFBundleURLTypes. dsvideo:// is unregistered, so "
          + "Top Shelf's deep links fail with LS error 115 — the TASK-860 defect."
      )
      return
    }

    let schemes = urlTypes.compactMap { $0["CFBundleURLSchemes"] as? [String] }.flatMap { $0 }
    XCTAssertTrue(
      schemes.contains("dsvideo"),
      "CFBundleURLTypes is present but does not declare `dsvideo`. Found: \(schemes)"
    )
  }

  /// The same build that registers the scheme also produces demo content.
  ///
  /// This is the other half of TASK-861's mutual exclusion. The old Release-build symptom
  /// was booting to "Pair iOS Device" with no library, so a deep link had nowhere to land
  /// even when the scheme resolved.
  func testTheSameBuildAlsoProducesDemoContent() {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestDemoMode"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the tvOS app did not launch")

    XCTAssertTrue(
      app.buttons.firstMatch.waitForExistence(timeout: 30),
      "The build that registers dsvideo:// booted with no controls. Demo mode is compiled "
        + "out or the app is sitting on the pairing screen — either way the mutual "
        + "exclusion TASK-861 describes has returned and the deep-link flow is untestable."
    )

    // Something must be focusable too: on tvOS a screen with content but no focus cannot be
    // operated by a remote, so a deep link landing there would still be a dead end.
    let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
    XCTAssertGreaterThan(focused.count, 0, "Demo content rendered but nothing can be focused.")
  }
}
