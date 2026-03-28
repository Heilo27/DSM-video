//
//  ContentView.swift
//  DS Video clone
//
//  Created by Ryan on 1/7/26.
//

import SwiftUI

// MARK: - Root

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var launchDone = false

    var body: some View {
        ZStack {
            // Main app content — hidden until launch completes
            Group {
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
            .opacity(launchDone ? 1 : 0)

            // Launch screen — sits on top, removes itself after animation
            if !launchDone {
                LaunchAnimationView {
                    withAnimation(.easeIn(duration: 0.25)) {
                        launchDone = true
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
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

    // Each ring gap size (degrees) and start angle
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
        .onAppear { startSequence() }
    }

    private func startSequence() {
        // Phase 1: All three rings spin continuously for ~1.2s
        // Ring 1 (inner): clockwise, fast
        // Ring 2 (middle): counter-clockwise, medium
        // Ring 3 (outer): clockwise, slow

        withAnimation(.linear(duration: 1.2)) {
            ring1Rotation = 360 * 2.5    // clockwise, faster
            ring2Rotation = -(360 * 1.8) // counter-clockwise
            ring3Rotation = 360 * 1.3    // clockwise, slower
        }

        // Phase 2–4: Snap each ring so its gap aligns to the right (0° = 3 o'clock in SwiftUI).
        // RingArc is drawn with the gap at the right at rest, so target = 0 (mod 360).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            withAnimation(.easeOut(duration: 0.18)) {
                ring1Rotation = snapToGapAngle(current: ring1Rotation, target: 0)
                ring1Aligned = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.48) {
            withAnimation(.easeOut(duration: 0.15)) {
                ring2Rotation = snapToGapAngle(current: ring2Rotation, target: 0)
                ring2Aligned = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) {
            withAnimation(.easeOut(duration: 0.15)) {
                ring3Rotation = snapToGapAngle(current: ring3Rotation, target: 0)
                ring3Aligned = true
            }
        }

        // Phase 5: Laser fires — no withAnimation wrapper; LaserView drives its own beam animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) {
            laserVisible = true
        }

        // Phase 6: Flash
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) {
            withAnimation(.easeIn(duration: 0.08)) {
                flashIntensity = 1.0
            }
        }

        // Phase 7: Complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.18) {
            onComplete()
        }
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
