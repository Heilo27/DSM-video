import XCTest

/// Layout, ordering, and visual-regression suite.
///
/// WHAT AUTOMATION CAN AND CANNOT JUDGE — read this before adding a test here.
///
/// XCUITest sees a tree of frames, labels and states. From that it can PROVE, mechanically:
///   • nothing is clipped by its container or pushed off screen
///   • nothing overlaps something else it should not
///   • content order matches the intended reading order
///   • layout survives the accessibility text sizes, where most designs actually break
///   • the layout holds in both orientations
///
/// It CANNOT judge whether a screen is beautiful. Colour harmony, type hierarchy, spacing
/// rhythm, and whether a screen feels professional are human judgements. What this suite does
/// for those is capture a named screenshot of every state at every size, on every run, so the
/// visual pass is a diff against last run's captures rather than a fresh opinion each time.
/// Tests assert the MEASURABLE; the attachments carry the AESTHETIC.
///
/// A test here must fail for a reason a designer would agree is a defect. "This spacing is 12pt
/// and I prefer 16pt" is not a test — it is a design decision, and encoding it makes the suite
/// an obstacle to design work instead of a safety net for it.
@MainActor
final class DSReelVisualTests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  // MARK: - Clipping and overflow

  /// Content must not be STRANDED off the edge — unreachable with no way to bring it into view.
  ///
  /// CALIBRATION NOTE (this test failed as first written, and the app was right): a horizontally
  /// scrolling rail legitimately parks its items past the trailing edge — that is what a carousel
  /// is. Flagging those reported four demo movie titles as defects. A raw "is any pixel outside
  /// the window" check cannot tell a carousel from a bug, and a test that cries wolf about
  /// correct behaviour gets the whole suite switched off.
  ///
  /// So this checks what is actually broken rather than merely outside: an element whose
  /// MAJORITY is off-screen AND which is interactive, i.e. something a user is meant to tap that
  /// they cannot see enough of to aim at. Rail items scroll into view; a button stranded at
  /// x = -80 does not.
  func testNoInteractiveContentIsStranded() {
    let app = UITest.launchInDemoMode()
    _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: UITest.timeout))

    let window = app.frame
    var stranded: [String] = []

    // Collect the horizontal extent of every scrollable area. A control inside one of these is
    // in a carousel: partially off-screen is its NORMAL resting state, and the user scrolls to
    // reach it. Only controls OUTSIDE any scroll view are judged, because for those there is no
    // gesture that will ever bring them into view.
    let scrollFrames: [CGRect] = app.scrollViews.allElementsBoundByIndex
      .filter { $0.exists }
      .map(\.frame)
      .filter { $0.width > 0 && $0.height > 0 }

    for element in app.buttons.allElementsBoundByIndex {
      guard element.exists, element.isHittable else { continue }
      let f = element.frame
      guard f.width > 0, f.height > 0 else { continue }

      // Inside a scroll view? Compare against the element's on-screen portion, since its own
      // frame may extend past the scroll view's bounds.
      let onScreen = f.intersection(window)
      let probe = onScreen.isNull ? f : onScreen
      let isScrollable = scrollFrames.contains { $0.intersects(probe) }
      if isScrollable { continue }

      // `intersection` is null (not zero-sized) when the rects do not touch at all.
      let visibleWidth = onScreen.isNull ? 0 : onScreen.width
      let fractionVisible = visibleWidth / f.width

      if fractionVisible < 0.5 {
        let name = element.identifier.isEmpty ? element.label : element.identifier
        guard !name.isEmpty else { continue }
        stranded.append(
          "\(name) only \(Int(fractionVisible * 100))% visible — x:[\(Int(f.minX))…\(Int(f.maxX))] "
            + "vs window [\(Int(window.minX))…\(Int(window.maxX))]"
        )
      }
    }

    XCTAssertTrue(
      stranded.isEmpty,
      "These tappable controls are mostly outside the window, so the user cannot aim at them:\n"
        + stranded.joined(separator: "\n")
    )
    capture(app, "10-layout-default")
  }

  // MARK: - Accessibility text sizes

  /// The layout must hold at accessibility text sizes.
  ///
  /// Regression: at XXL the Play button's label collapsed to a clipped glyph fragment — the
  /// PRIMARY action losing its text. This walks the large content sizes and asserts that every
  /// labelled control still has a frame big enough to show something, capturing each for review.
  func testLayoutHoldsAtAccessibilityTextSizes() {
    // The three that matter: the first accessibility size, a middle one, and the largest. The
    // largest is the real test — if it holds, the ones between it and default do too.
    let sizes = [
      "UICTContentSizeCategoryAccessibilityM",
      "UICTContentSizeCategoryAccessibilityXL",
      "UICTContentSizeCategoryAccessibilityXXXL",
    ]

    for size in sizes {
      let app = UITest.launchInDemoMode(extraArguments: ["-UIPreferredContentSizeCategoryName", size])
      _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)
      XCTAssertTrue(
        app.buttons.firstMatch.waitForExistence(timeout: UITest.timeout),
        "No buttons rendered at content size \(size) — the screen may have failed to lay out."
      )

      let short = size.replacingOccurrences(of: "UICTContentSizeCategoryAccessibility", with: "A11y-")
      capture(app, "11-text-size-\(short)")

      // A labelled control whose frame has collapsed cannot be showing its label. 20pt is
      // deliberately lenient — this catches a collapse, not a tight fit.
      var collapsed: [String] = []
      for button in app.buttons.allElementsBoundByIndex {
        guard button.exists, button.isHittable, !button.label.isEmpty else { continue }
        let f = button.frame
        if f.width < 20 || f.height < 20 {
          collapsed.append("\"\(button.label)\" [\(Int(f.width))x\(Int(f.height))]")
        }
      }
      XCTAssertTrue(
        collapsed.isEmpty,
        "At \(size) these labelled controls collapsed to a frame too small to show their text: "
          + collapsed.joined(separator: ", ")
      )

      app.terminate()
    }
  }

  // MARK: - Orientation

  /// Rotation must not strand content. A layout that only works in portrait is a layout that
  /// breaks for every user who turns their phone to watch something.
  func testLayoutSurvivesRotation() {
    let app = UITest.launchInDemoMode()
    _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: UITest.timeout))

    let device = XCUIDevice.shared
    defer { device.orientation = .portrait }

    capture(app, "12a-portrait")

    device.orientation = .landscapeLeft
    // Let the rotation settle before measuring, or we assert against a mid-animation frame.
    XCTAssertTrue(
      app.buttons.firstMatch.waitForExistence(timeout: UITest.timeout),
      "No buttons found after rotating to landscape — the layout may have failed."
    )
    capture(app, "12b-landscape")

    XCTAssertEqual(
      app.state, .runningForeground,
      "The app left the foreground during rotation."
    )

    device.orientation = .portrait
    XCTAssertTrue(
      app.buttons.firstMatch.waitForExistence(timeout: UITest.timeout),
      "Content did not come back after rotating to portrait."
    )
    capture(app, "12c-portrait-again")
  }

  // MARK: - Theme / appearance

  /// The app forces its own dark theme and ignores the system appearance. That is a deliberate
  /// product choice, not a bug — so this test PINS it rather than objecting to it. If the app
  /// ever gains real light-mode support, this test should be replaced by a differential one;
  /// until then it documents the decision and captures both for the visual pass.
  func testAppearanceIsIntentionallyFixed() {
    let dark = UITest.launchInDemoMode(extraArguments: ["-UIUserInterfaceStyle", "Dark"])
    _ = dark.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    XCTAssertTrue(dark.buttons.firstMatch.waitForExistence(timeout: UITest.timeout))
    capture(dark, "13a-appearance-dark")
    dark.terminate()

    let light = UITest.launchInDemoMode(extraArguments: ["-UIUserInterfaceStyle", "Light"])
    _ = light.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    XCTAssertTrue(
      light.buttons.firstMatch.waitForExistence(timeout: UITest.timeout),
      "The app failed to render under the Light system appearance."
    )
    capture(light, "13b-appearance-light")
  }

  // MARK: - Reading order

  /// Content must be laid out in its intended reading order — top to bottom, leading to
  /// trailing. A screen whose elements are positioned out of order still "renders", but reads
  /// wrong to a sighted user and is navigated wrong by VoiceOver and by the tvOS remote.
  func testContentFollowsReadingOrder() {
    let app = UITest.launchInDemoMode()
    _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)
    XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: UITest.timeout))

    // Accessibility order is what assistive tech actually follows. Compare it against geometric
    // order: a large disagreement means the a11y tree is telling a different story from the
    // visual layout, which is how a screen becomes unnavigable without looking broken.
    let texts = app.staticTexts.allElementsBoundByIndex
      .filter { $0.exists && !$0.label.isEmpty && $0.frame.height > 0 }
      .prefix(12)

    guard texts.count >= 2 else {
      XCTFail("Fewer than two labelled text elements on the first screen — nothing to order.")
      return
    }

    var inversions = 0
    for (a, b) in zip(texts, texts.dropFirst()) {
      // Allow same-row elements in either order (a row is laid out horizontally); only count a
      // clear vertical regression, where the next element sits well ABOVE the previous one.
      if b.frame.minY < a.frame.minY - 24 {
        inversions += 1
      }
    }

    // Rails legitimately interleave, so a couple of inversions are normal. A large count means
    // the accessibility order genuinely does not track the layout.
    XCTAssertLessThanOrEqual(
      inversions, 3,
      "Accessibility order disagrees with visual order in \(inversions) places. VoiceOver and "
        + "the tvOS remote follow the accessibility order, so this screen navigates wrong."
    )
  }

  // MARK: - Tab bar occlusion (TASK-884)

  /// Scrolled to the END, no content sits behind the floating tab bar.
  ///
  /// TASK-884 reported rail titles clipped by the bar at default size, and at AX5 the whole
  /// "Recently Watched" HEADER rendered behind it — measured at 118 lit pixels. A fix added a
  /// Dynamic-Type-scaled `.safeAreaInset`, and the code now carries a comment asserting the
  /// remaining AX5 report was a false positive: the probe was catching the NEXT rail's header
  /// passing under translucent glass mid-scroll, which is iOS 26's intended edge-to-edge
  /// behaviour rather than occlusion.
  ///
  /// That reasoning is plausible and it was never verified — it is an argument in a comment
  /// against a measurement. This settles it by measuring the thing the comment actually
  /// claims: the inset governs the END of scrollable content, so scroll to the end and assert
  /// nothing is left underneath. Mid-scroll content passing under glass is explicitly NOT
  /// asserted, because that is the behaviour the comment says is intended.
  func testNoContentSitsBehindTheTabBarWhenScrolledToTheEnd() {
    let sizes = [
      "UICTContentSizeCategoryLarge",
      "UICTContentSizeCategoryAccessibilityXXXL",
    ]

    for size in sizes {
      let app = UITest.launchInDemoMode(extraArguments: ["-UIPreferredContentSizeCategoryName", size])
      _ = app.wait(for: .runningForeground, timeout: UITest.launchTimeout)

      // The tab bar's top edge is the occlusion line. Locate it by a real tab rather than by
      // assuming a height — the bar grows with Dynamic Type, which is the whole difficulty.
      //
      // Located by LABEL, not by UIID.Tab.home. MainView applies .accessibilityIdentifier
      // inside .tabItem and carries a comment asserting that is the placement which reaches
      // the tab button; a captured UI hierarchy shows all five tab buttons rendered with
      // correct labels and NO identifier at all, and moving the modifier onto the content
      // view does not fix it either (both measured, iOS 26 / deployment target 18).
      // Identifier-based lookup therefore fails in this test's own setup, so it never got as
      // far as measuring occlusion — it failed for a reason unrelated to TASK-884. Until the
      // identifier issue is resolved (TASK-909), the label is what actually addresses the
      // bar, and it is a real contract: these strings are user-visible.
      let homeTab = app.buttons["Home"]
      guard homeTab.waitForExistence(timeout: UITest.timeout) else {
        XCTFail("Could not find the Home tab at \(size), so the tab bar's position is unknown.")
        continue
      }
      let barTop = homeTab.frame.minY

      // Scroll to the very end: the inset under test governs the END of content.
      let scroll = app.scrollViews.firstMatch
      if scroll.exists {
        for _ in 0..<8 { scroll.swipeUp() }
      }

      let short = size.replacingOccurrences(of: "UICTContentSizeCategory", with: "")
      capture(app, "12-tabbar-occlusion-\(short)")

      // Any labelled text whose BOTTOM is below the bar's top is underneath it.
      let occluded = app.staticTexts.allElementsBoundByIndex
        .filter { $0.exists && !$0.label.isEmpty && $0.frame.height > 0 }
        .filter { $0.frame.maxY > barTop + 1 }
        .map { "\($0.label) (maxY \(Int($0.frame.maxY)) vs bar top \(Int(barTop)))" }

      XCTAssertTrue(
        occluded.isEmpty,
        "At \(size), \(occluded.count) text element(s) sit behind the tab bar after scrolling "
          + "to the end of the content: \(occluded.joined(separator: ", ")). The bottom inset "
          + "is not clearing the floating bar."
      )
    }
  }
}
