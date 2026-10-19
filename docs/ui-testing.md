# UI Testing — DSReel

How the UI suite works, what it can and cannot prove, and the rules for adding to it.

## Why this exists

Until 2026-09-11 the UI-test target was Xcode's generated template: `testExample()` launched the
app and then held a comment where an assertion belonged. It was also **unrunnable**, for two
independent reasons nobody had noticed:

- `TEST_TARGET_NAME` still read `"DS Video clone"`, a target renamed long ago, so `xcodebuild`
  refused it with `UITargetAppPath should be provided`.
- The UITest target was not listed in the `DSM Video` scheme's `<Testables>` block at all.

So the project looked tested and had zero UI coverage. Two P0s shipped through that gap and were
found by a Level 1 diagnostic on the eve of a submission:

| Defect | Why no test caught it |
|---|---|
| Every download wrote a 22-byte HTTP error body to disk as `{id}.mp4` and marked the item downloaded | Nothing ever tapped Download and asserted the result |
| The player's "Playback Failed" screen was inescapable — Retry, Dismiss and swipe all inert | Nothing ever tapped a button and asserted that something happened |

Both are trivially catchable by tapping a control and asserting an outcome. That is the entire
premise of this suite.

## Running it

```bash
# Everything (unit + UI)
cd "DS Video clone" && fastlane test

# UI only, on a specific simulator
fastlane test ui_only:true device:"iPhone 17"

# The tvOS focus guard (static, no simulator needed)
fastlane check_focus
```

**Pre-boot the simulator.** `xcodebuild test` intermittently hangs on simulator acquisition
— idle, no booted device, no runner, no output. It is not the tests. Boot first and target by
UDID:

```bash
xcrun simctl boot <udid>
xcodebuild test -destination 'platform=iOS Simulator,id=<udid>' ...
```

## Architecture

| File | Role |
|---|---|
| `DSM Video/App/AccessibilityIDs.swift` | The identifier registry, in the **app** target |
| `DS Video cloneUITests/UITestSupport.swift` | Launch helpers, failing assertions, the `UIID` mirror |
| `DS Video cloneUITests/StubServer.swift` | Loopback HTTP server with canned routes and a request log; `stop()` simulates an unreachable NAS |
| `DS Video cloneUITests/ProfileOracleUITests.swift` | Profile picker, PIN copy, first-PIN save errors, restricted empty state, Siri/deep link opens detail and never plays |
| `DS Video cloneUITests/SuggestedRailUITests.swift` | The Suggested rail renders with its genre, and is absent when the server has no suggestion |
| `DS Video cloneUITests/DSReelUITests.swift` | Behaviour: launch, login, dead-control sweeps, a11y |
| `DS Video cloneUITests/DSReelVisualTests.swift` | Layout, text sizes, rotation, reading order, screenshots |
| `DS Video cloneUITests/DS_Video_cloneUITests.swift` | Cold-launch budget + launch metric |
| `DS Video cloneUITests/DS_Video_cloneUITestsLaunchTests.swift` | Per-configuration launch screenshots |

### The identifier mirror

UI tests drive the app as a black box and link nothing from it, so the app's `A11y` enum is not
visible to the test target. `UIID` in `UITestSupport.swift` mirrors it by hand.

**The two must agree.** A silent divergence makes every query miss — and a missing element is
indistinguishable from a broken feature, so the suite would go quiet instead of red.
`testIdentifierMirrorIsComplete` asserts the setup identifiers resolve against a real launched
build, which is what catches drift.

### Launch hooks (DEBUG-only, inert without the argument)

| Argument | Effect |
|---|---|
| `-UITestDemoMode` | Signs in with deterministic demo content, no network |
| `-UITestResetState` | Clears `dsReel.`-prefixed defaults, the two Keychain entries, the app-group profile state (`ActiveProfileStore.clearAll`) and the `dsreel.db`, `-wal`, `-shm` files |
| `-QALiveToken` / `-QALiveServer` | Boots into a real session against a server. Tests point it at the loopback `StubServer` (`UITest.launchAgainst`), never at a real NAS |

Tests use demo mode or the loopback `StubServer`. **Never make a test depend on the live NAS** — its reachability would make
the suite flaky, and a flaky suite gets disabled, at which point it protects nothing.

## The rules

1. **Never skip.** `XCTSkip` is banned. A test that skips when its element is missing reports
   success at the exact moment the feature broke. If a precondition is absent, FAIL and name what
   was missing.
2. **Query by identifier, never by visible copy.** Identifiers are API — never rename one to
   match new UI copy.
3. **Assert on identity and count, never position.** `cells.firstMatch` after a deletion
   re-resolves to the next row, which still exists: an assertion that cannot fail.
4. **Assert the text, not just its presence.** "An error appeared" passes for a *wrong* error.
   Project rule: user-facing error text names the real cause. A failed download once reported
   itself as an unsupported format and sent users off to re-encode healthy files.
5. **`exists` is not `isHittable`.** The player's buttons existed the entire time they were
   unreachable — a transparent full-frame gesture layer above them swallowed every tap. Use
   `requireHittable` for anything a user taps.
6. **Add the identifier in the same commit as the control.** A control without one cannot be
   asserted on, which is how a dead control survives review.

## What automation cannot judge

XCUITest sees frames, labels and states. It can prove, mechanically: nothing clipped or pushed
off screen, nothing overlapping, content order matching reading order, layout surviving
accessibility text sizes and rotation, controls meeting 44pt, interactive elements labelled.

It **cannot** judge whether a screen is beautiful. Colour harmony, type hierarchy, spacing
rhythm, and whether a screen feels professional are human judgements.

What the suite does for those is capture a named screenshot of every state at every size on every
run (`capture(app, "11-text-size-A11y-XXXL")`). The visual pass is then a **diff against the
previous run's captures** rather than a fresh opinion each time — which is the difference between
catching a regression and rediscovering an opinion.

A test here must fail for a reason a designer would agree is a defect. "This spacing is 12pt and
I prefer 16pt" is not a test — it is a design decision, and encoding it makes the suite an
obstacle to design work instead of a safety net for it.

## Not automatable (and why)

Each row is a deliberate decision, not a backlog item. A row leaves this table only when the
reason stops being true.

| Area | Criteria | Why it is not a UI test |
|---|---|---|
| tvOS-only behaviour | OC-2059, OC-2162 to 2164, OC-2170 | The simulator cannot reproduce Siri Remote focus movement reliably; `scripts/check-tvos-focus.sh` guards the focus enums statically instead |
| Player | OC-1056 to OC-1078 | Needs decoded video, real audio sessions, AirPlay/PiP and background audio; the simulator cannot judge any of them. Covered by unit tests of the playback logic and by device checks |
| Live network | OC-0008, OC-0010 to OC-0013, OC-0126 | These are about a real NAS, QuickConnect relay and WAN latency. A stub proves nothing about them, and a live dependency would make the suite flaky (see launch hooks) |
| Play resume | position survives exit and reopen | **Deferred, not refused.** The stub has no Range / binary support, so a player cannot open a stream from it. Unblock by teaching `StubServer` a ranged binary response |

## Coverage gaps — honest list

These are **not** covered yet, and each needs either a live server or a real device:

- **Download completes and produces a playable file.** The highest-value missing test, and the
  one that would have caught the 22-byte-file P0 directly. Needs a served fixture — worth a
  stub HTTP server in the test target.
- **Player error screen dismisses.** Requires inducing a playback failure; a deliberately
  unplayable URL via a launch hook would do it.
- **Resume position survives exit and reopen.** Needs the store plus playback.
- **tvOS focus traversal.** The simulator cannot reproduce the focus bug reliably, which is why
  `scripts/check-tvos-focus.sh` exists as a static guard instead. It now covers every focus enum
  in every tvOS-facing view, not just the player's — the blind spot that let the bug recur a
  fifth time.
- **Locked-device writes.** The file-protection bug (writes failing while the screen is locked
  during background audio) cannot be reproduced on a simulator at all.
