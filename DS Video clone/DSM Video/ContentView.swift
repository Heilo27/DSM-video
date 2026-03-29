//
//  ContentView.swift
//  DS Video clone
//
//  Created by Ryan on 1/7/26.
//

import SwiftUI
import os.log

// Debug logger — filter by subsystem "com.dsm.launch" or "com.dsm.orientation" in Console.app
private let launchLog = Logger(subsystem: "com.dsm.launch", category: "animation")
private let orientLog = Logger(subsystem: "com.dsm.orientation", category: "lock")

// MARK: - Root

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // launchDone gates app content insertion (prevents .task{} network calls during animation).
    // launchVisible controls whether the launch overlay is in the view tree.
    // They're set separately so the app content is inserted first, then the overlay fades out.
    @State private var launchDone = false
    @State private var launchVisible = true

    var body: some View {
        ZStack {
            // App content — inserted only after animation finishes so network tasks
            // don't run concurrently with the launch animation sequence.
            if launchDone {
                #if os(tvOS)
                TVMainView()
                #else
                if appState.sessionToken == nil {
                    LoginView()
                } else {
                    MainView(layout: (horizontalSizeClass ?? .regular) == .regular ? .split : .tabs)
                }
                #endif
            }

            // Launch overlay — kept in tree until fade-out completes so the
            // animation Task owns its @State for its full lifetime.
            if launchVisible {
                LaunchAnimationView {
                    // Step 1: Insert app content (still hidden under overlay)
                    launchDone = true
                    // Step 2: Fade out overlay, then remove from tree
                    withAnimation(.easeIn(duration: 0.25)) {
                        launchVisible = false
                    }
                }
                .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Launch Animation

private struct LaunchAnimationView: View {
    let onComplete: () -> Void

    // Ring animation state
    @State private var ring1Rotation: Double = 0
    @State private var ring2Rotation: Double = 0
    @State private var ring3Rotation: Double = 0

    // Sequence state
    @State private var ring1Aligned = false
    @State private var ring2Aligned = false
    @State private var ring3Aligned = false
    @State private var laserVisible = false
    @State private var flashIntensity: Double = 0

    // Each ring gap size (degrees)
    private let gapDegrees: Double = 14

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    ZStack {
                        // Outer ring (ring 3) — spins clockwise
                        RingArc(gapDegrees: gapDegrees, radius: 96, lineWidth: 4)
                            .foregroundStyle(Color.white.opacity(0.5))
                            .rotationEffect(.degrees(ring3Rotation))

                        // Middle ring (ring 2) — spins counter-clockwise
                        RingArc(gapDegrees: gapDegrees, radius: 72, lineWidth: 4)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .rotationEffect(.degrees(ring2Rotation))

                        // Inner ring (ring 1) — spins clockwise
                        RingArc(gapDegrees: gapDegrees, radius: 50, lineWidth: 4)
                            .foregroundStyle(Color.white.opacity(0.9))
                            .rotationEffect(.degrees(ring1Rotation))

                        // Logo: red circle + play triangle
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 64, height: 64)
                            Image(systemName: "play.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        }
                    }
                    .frame(width: 220, height: 220)

                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // Laser beam: fires right from center once rings align
                if laserVisible {
                    LaserView(screenWidth: geo.size.width, screenHeight: geo.size.height)
                }

                // White flash overlay
                Color.white
                    .opacity(flashIntensity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        // .task is used instead of onAppear + Task{} because SwiftUI ties .task
        // lifetime to the view — it cancels automatically if the view is removed,
        // preventing state mutations on a deallocated view node.
        .task {
            launchLog.info("LaunchAnimationView appeared — starting sequence")
            await runSequence()
        }
        .accessibilityHidden(true)
    }

    /// Animation sequence using structured concurrency so sleep intervals are
    /// relative to the *previous step finishing*, not wall-clock launch time.
    /// DispatchQueue.asyncAfter was unreliable — when the main thread was busy
    /// at launch (keychain reads, URL init, etc.) all deadlines fired at once,
    /// compressing or skipping the entire sequence.
    @MainActor
    private func runSequence() async {
        launchLog.info("Phase 1: rings spinning")
        withAnimation(.linear(duration: 1.2)) {
            ring1Rotation = 360 * 2.5    // inner: clockwise fast
            ring2Rotation = -(360 * 1.8) // middle: counter-clockwise
            ring3Rotation = 360 * 1.3    // outer: clockwise slow
        }

        try? await Task.sleep(for: .milliseconds(1250))
        launchLog.info("Phase 2: snapping ring 1 (inner)")
        withAnimation(.easeOut(duration: 0.18)) {
            ring1Rotation = snapToGapAngle(current: ring1Rotation, target: 0)
            ring1Aligned = true
        }

        try? await Task.sleep(for: .milliseconds(230))
        launchLog.info("Phase 3: snapping ring 2 (middle)")
        withAnimation(.easeOut(duration: 0.15)) {
            ring2Rotation = snapToGapAngle(current: ring2Rotation, target: 0)
            ring2Aligned = true
        }

        try? await Task.sleep(for: .milliseconds(170))
        launchLog.info("Phase 4: snapping ring 3 (outer)")
        withAnimation(.easeOut(duration: 0.15)) {
            ring3Rotation = snapToGapAngle(current: ring3Rotation, target: 0)
            ring3Aligned = true
        }

        try? await Task.sleep(for: .milliseconds(200))
        launchLog.info("Phase 5: laser firing")
        laserVisible = true

        try? await Task.sleep(for: .milliseconds(200))
        launchLog.info("Phase 6: white flash")
        withAnimation(.easeIn(duration: 0.08)) {
            flashIntensity = 1.0
        }

        try? await Task.sleep(for: .milliseconds(130))
        launchLog.info("Phase 7: sequence complete — handing off to app")
        onComplete()
    }

    /// Returns a rotation angle that puts the gap at `target` degrees,
    /// preserving full rotations already done so the animation feels continuous.
    private func snapToGapAngle(current: Double, target: Double) -> Double {
        let fullRotations = (current / 360).rounded(.towardZero) * 360
        let currentMod = current.truncatingRemainder(dividingBy: 360)
        var diff = target - currentMod
        if diff > 180  { diff -= 360 }
        if diff < -180 { diff += 360 }
        return fullRotations + currentMod + diff
    }
}

// MARK: - Ring Arc Shape

/// A circle with a gap. The gap is centered at 3 o'clock (the right side) at rest,
/// which is SwiftUI's native 0° for Circle().trim. Rotating the view by N degrees
/// moves the gap N degrees clockwise from the right — so a rotation of 0 = gap right,
/// which is exactly where the laser beam travels.
private struct RingArc: View {
    let gapDegrees: Double
    let radius: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        // SwiftUI Circle().trim: 0.0 = 3 o'clock, goes clockwise.
        // We want the gap centered at 3 o'clock, so the arc runs from
        // just past 3 o'clock (clockwise) all the way around back to just before 3 o'clock.
        let halfGapFraction = (gapDegrees / 2) / 360.0
        Circle()
            .trim(from: halfGapFraction, to: 1.0 - halfGapFraction)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: radius * 2, height: radius * 2)
    }
}

// MARK: - Laser View

private struct LaserView: View {
    let screenWidth: CGFloat
    let screenHeight: CGFloat

    @State private var beamWidth: CGFloat = 0
    @State private var impactVisible = false

    var body: some View {
        ZStack {
            // Laser beam — grows from center to right edge
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: screenWidth / 2)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.red.opacity(0.9), Color.red.opacity(0.2)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: beamWidth, height: 3)
            }
            .frame(maxHeight: .infinity)

            // Impact flash at right edge
            if impactVisible {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: 12, height: 40)
                        .blur(radius: 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.14)) {
                beamWidth = screenWidth / 2
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeIn(duration: 0.06)) {
                    impactVisible = true
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
