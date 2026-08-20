import AVKit
import Combine
import SwiftUI
import os.log

extension Notification.Name {
    static let playerDidDismiss = Notification.Name("com.dsm.dsvideo.playerDidDismiss")
}

#if os(iOS) || os(tvOS)
import MediaPlayer
import UIKit
#endif

// nonisolated: os.Logger is Sendable and stateless, but a file-level `let` inherits the
// project's default @MainActor isolation, so reading it from the Task.detached teardown block
// (cleanup(), ~:1496) was an isolation violation — "main actor-isolated let 'orientLog' cannot
// be accessed from outside of the actor; this is an error in the Swift 6 language mode."
// Same class as the PlaybackProgress isolation errors that failed Xcode Cloud build 7 in
// Release; currently only a warning here, and fixed before it becomes a build failure.
private nonisolated let orientLog = Logger(subsystem: "com.dsm.orientation", category: "player")

/// A custom video player with gesture-based controls:
/// - Horizontal swipe/pan to scrub through video
/// - Vertical swipe on left side to adjust brightness (iOS only)
/// - Vertical swipe on right side to adjust volume
/// - Double-tap left side to skip back 10 seconds
/// - Double-tap right side to skip forward 10 seconds
/// - Single tap to show/hide controls
struct GestureVideoPlayer: View {
    let url: URL
    let title: String
    var resumePosition: Double = 0
    /// Authoritative full runtime from the server (scan-time probe). A live-window HLS
    /// playlist only reports the duration transcoded so far, so playerItem.duration is
    /// too short while transcoding and the scrubber pins to the end. When this is set
    /// and larger than playerItem.duration, the player uses it instead. 0 = unknown.
    var serverDuration: Double = 0
    var chapters: [Chapter] = []
    // TASK-828: server-supplied subtitle semantics (full/forced/image + autoEnable).
    // Empty for offline downloads and older servers; the player then falls back to
    // plain AVFoundation behaviour (all subs off, manual selection only).
    var subtitles: [Subtitle] = []
    var itemID: String = ""
    var itemTitle: String = ""
    var itemYear: Int? = nil
    // TASK-740: base URL for the trick-play VTT/sprite endpoints (nil = no preview).
    var trickplayBaseURL: URL? = nil
    var authToken: String? = nil
    // FIX-5: When true, HLS segments are fetched with Cookie: type=tunnel for QC relay mode.
    var usesTunnelCookie: Bool = false
    var onDismiss: (() -> Void)?
    var onProgressUpdate: ((Double, Double) -> Void)?
    /// Called when AVPlayer reports a fatal playback error. The caller can use
    /// this to reset state and re-fetch a fresh playback URL (e.g. stale session).
    var onPlaybackFailed: (() -> Void)?
    /// Called when the current item plays to the end of its timeline.
    var onPlaybackFinished: (() -> Void)?
    /// Called when the user changes the subtitle offset. The caller should restart
    /// playback with the new offset so the server can bake it into the HLS stream.
    var onSubtitleOffsetChange: ((Double) -> Void)?
    /// Called when the user taps "Go to Show" in the controls overlay.
    /// Only set for TV episode playback.
    var onGoToShow: (() -> Void)?
    /// When true, d-pad left/right does not seek (used when an overlay captures focus).
    var blockDpadSeek: Bool = false

    @State private var player: AVPlayer?
    #if os(iOS)
    @State private var pipController: AVPictureInPictureController?
    @State private var pipDelegate: PictureInPictureDelegate?
    @State private var isPiPActive: Bool = false
    #endif
    @State private var isPlaying: Bool = false
    @State private var showControls: Bool = true
    @State private var controlsInteractive: Bool = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    // TASK-738: persist playback speed across sessions (was resetting to 1× each launch).
    @State private var playbackRate: Float = {
        let stored = UserDefaults.standard.float(forKey: "dsReel.playbackRate")
        return stored > 0 ? stored : 1.0
    }()
    @State private var isBuffering: Bool = true
    @State private var playerError: String?

    // Gesture states
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @State private var scrubStartTime: Double = 0
    @State private var showScrubPreview: Bool = false
    // TASK-663: tvOS interactive scrub. D-pad left/right moves a preview position
    // (scrubTime) without seeking; the seek commits once after a brief idle or on
    // Select. Consecutive presses within the window accelerate the step.
    @State private var scrubCommitTask: Task<Void, Never>?
    @State private var lastScrubPressAt: Date = .distantPast
    @State private var scrubStepRepeat: Int = 0

    // TASK: coalesced seeking. AVPlayer cancels an in-flight seek when a new one
    // arrives; with ±2s tolerance on transcoded HLS, rapid skip-button taps each
    // land back near the same segment boundary and playback thrashes instead of
    // advancing. Serialise seeks: while one is running, only remember the LATEST
    // requested target and fire it once the current seek completes.
    @State private var isSeekInProgress: Bool = false
    @State private var pendingSeekTarget: Double? = nil
    @State private var pendingSeekTight: Bool = false

    @State private var isAdjustingVolume: Bool = false
    @State private var volumeLevel: Float = 0.5
    @State private var volumeStartLevel: Float = 0.5
    @State private var showVolumeIndicator: Bool = false


    @State private var showSkipIndicator: SkipDirection? = nil

    enum VideoFillMode {
        case fill  // edge-to-edge, resizeAspectFill — may be under Dynamic Island
        case fit   // respects safe area, resizeAspect — letterboxed but clean
    }
    @State private var videoFillMode: VideoFillMode = UserDefaults.standard.bool(forKey: "dsReel.videoFitMode") ? .fit : .fill

    @State private var hideControlsTask: Task<Void, Never>?
    @State private var hideVolumeIndicatorTask: Task<Void, Never>?
    @State private var skipHideTask: Task<Void, Never>?
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var timeObserver: Any?
    // MARK: ACKNOWLEDGED (TASK-199): Set<AnyCancellable> in @State is a known pattern limitation
    // for struct-based SwiftUI views. The subscriptions established in setupPlayer() are stored
    // here and manually cleared in cleanup(). Moving to @StateObject would require a class wrapper
    // and is deferred — the current lifecycle (onAppear/onDisappear) is correct.
    @State private var cancellables = Set<AnyCancellable>()
    @State private var hasResumedPosition: Bool = false
    // TASK-828: guard so the forced/translation track is auto-enabled exactly once per
    // item load. readyToPlay can fire more than once (e.g. after a stall), and we must
    // not re-assert the selection after the user has changed it themselves.
    @State private var didApplyForcedSubtitle: Bool = false
    @State private var showCaptionsPicker: Bool = false
    @State private var didSetupPlayer: Bool = false
    @State private var subtitleOffsetSeconds: Double = 0
    // TASK-740: loaded trick-play sprite + cue table for scrub previews.
    @State private var trickplay: Trickplay?

    private let skipForwardSeconds: Double = 15
    private let skipBackwardSeconds: Double = 15
    // TASK-734: d-pad left/right seek step on tvOS. Kept symmetric and small for
    // fine-scrubbing; named so it sits alongside the skip-button constants.
    private let tvDpadSeekSeconds: Double = 10

    enum SkipDirection {
        case backward, forward
    }

    #if os(tvOS)
    @FocusState private var focusedControl: TVFocusField?
    enum TVFocusField { case playPause, captions, speed, hidden }
    #endif

    @Environment(\.scenePhase) private var scenePhase

    private var introChapter: Chapter? {
        guard !chapters.isEmpty else { return nil }
        let introKeywords = ["intro", "opening", "cold open"]
        return chapters.first { ch in
            let lower = ch.title.lowercased()
            let matchesKeyword = introKeywords.contains(where: { lower.contains($0) })
                || lower == "op"
                || lower.hasPrefix("op ")
                || lower.hasSuffix(" op")
            return matchesKeyword && ch.startSecs < 300
        }
    }

    var body: some View {
        playerContent
            .onAppear {
                setupPlayer()
                setupVolumeObserver()
                #if os(iOS)
                lockLandscape()
                loadTrickplay()
                #endif
            }
            .onDisappear {
                cleanup()
                // Ensure portrait is restored if the player was dismissed via
                // any path other than the explicit back button (e.g. system back
                // gesture, app backgrounded mid-play).
                #if os(iOS)
                if AppDelegate.orientationLock != .portrait {
                    unlockOrientation()
                }
                #endif
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    #if os(iOS)
                    // Don't pause if PiP is active — the player must keep running.
                    guard !isPiPActive else { return }
                    #endif
                    // Pause playback when backgrounded. Progress sync is handled by
                    // the parent PlayerSheet's own scenePhase handler to avoid a double write.
                    player?.pause()
                }
            }
            #if os(iOS)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onKeyPress(.space) {
                togglePlayPause()
                return .handled
            }
            #elseif os(macOS)
            .onKeyPress(.space) {
                togglePlayPause()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                skipBackward()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                skipForward()
                return .handled
            }
            #endif
    }

    private var playerContent: some View {
        let base = GeometryReader { geometry in
            playerZStack(geometry: geometry)
        }
        .onChange(of: showControls) { _, newValue in
            if newValue {
                controlsInteractive = true
                #if os(tvOS)
                focusedControl = .playPause
                #endif
            } else {
                controlsHideTask?.cancel()
                controlsHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    controlsInteractive = false
                    #if os(tvOS)
                    focusedControl = .hidden
                    #endif
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Play/Pause") { togglePlayPause() }
        .accessibilityAction(named: "Skip forward \(Int(skipForwardSeconds)) seconds") { skipForward() }
        .accessibilityAction(named: "Skip backward \(Int(skipBackwardSeconds)) seconds") { skipBackward() }
        #if os(iOS)
        return base
            .accessibilityAction(named: "Increase volume") {
                volumeLevel = min(1, volumeLevel + 0.1)
                setSystemVolume(volumeLevel)
            }
            .accessibilityAction(named: "Decrease volume") {
                volumeLevel = max(0, volumeLevel - 0.1)
                setSystemVolume(volumeLevel)
            }
            .accessibilityAction(named: "Increase brightness") {
                if let screen = currentScreen {
                    screen.brightness = min(1, screen.brightness + 0.1)
                }
            }
            .accessibilityAction(named: "Decrease brightness") {
                if let screen = currentScreen {
                    screen.brightness = max(0, screen.brightness - 0.1)
                }
            }
            .sheet(isPresented: $showCaptionsPicker) {
                if let player {
                    SubtitleAudioPickerView(
                        player: player,
                        chapters: chapters,
                        subtitles: subtitles,
                        itemTitle: itemTitle,
                        itemYear: itemYear,
                        onOffsetChange: { offset in subtitleOffsetSeconds = offset; onSubtitleOffsetChange?(offset) },
                        onSeekToChapter: { t in seek(to: t) }
                    )
                }
            }
        #elseif os(macOS)
        return base
            .sheet(isPresented: $showCaptionsPicker) {
                if let player {
                    SubtitleAudioPickerView(
                        player: player,
                        chapters: chapters,
                        subtitles: subtitles,
                        itemTitle: itemTitle,
                        itemYear: itemYear,
                        onOffsetChange: { offset in subtitleOffsetSeconds = offset; onSubtitleOffsetChange?(offset) },
                        onSeekToChapter: { t in seek(to: t) }
                    )
                }
            }
        #else
        return base
            .sheet(isPresented: $showCaptionsPicker) {
                if let player {
                    SubtitleAudioPickerView(
                        player: player,
                        chapters: chapters,
                        subtitles: subtitles,
                        itemTitle: itemTitle,
                        itemYear: itemYear,
                        onOffsetChange: { offset in subtitleOffsetSeconds = offset; onSubtitleOffsetChange?(offset) },
                        onSeekToChapter: { t in seek(to: t) }
                    )
                }
            }
            #if os(tvOS)
            .onPlayPauseCommand { togglePlayPause() }
            .onMoveCommand { direction in handleTVMoveCommand(direction: direction) }
            #endif
        #endif
    }

    // MARK: - Player ZStack

    @ViewBuilder
    private func playerZStack(geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video layer
            if let player {
                if videoFillMode == .fill {
                    #if os(iOS)
                    VideoPlayerLayer(player: player, gravity: .resizeAspectFill, onLayerReady: setupPiP)
                        .ignoresSafeArea()
                    #elseif os(tvOS)
                    // tvOS: always use resizeAspect regardless of fill mode to prevent edge cropping.
                    VideoPlayerLayer(player: player, gravity: .resizeAspect)
                        .ignoresSafeArea()
                    #else
                    VideoPlayerLayer(player: player, gravity: .resizeAspectFill)
                        .ignoresSafeArea()
                    #endif
                } else {
                    #if os(iOS)
                    VideoPlayerLayer(player: player, gravity: .resizeAspect, onLayerReady: setupPiP)
                    #else
                    VideoPlayerLayer(player: player, gravity: .resizeAspect)
                    #endif
                }
            }

            // Gesture overlay
            gestureOverlay(geometry: geometry)

            #if os(tvOS)
            // Zero-size focus sink: holds focus when controls are hidden so Select
            // press reliably fires. Offset off-screen so tvOS never renders a highlight.
            Button { handleTVSelectPress() } label: { Color.clear.frame(width: 0, height: 0) }
                .frame(width: 0, height: 0)
                .focused($focusedControl, equals: .hidden)
                .buttonStyle(.plain)
                .clipShape(Rectangle())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            #endif

            // Controls overlay
            controlsOverlay(geometry: geometry)
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(controlsInteractive)
                .accessibilityHidden(!showControls)

            // Scrub preview
            if showScrubPreview {
                scrubPreviewOverlay
            }

            // Volume indicator
            if showVolumeIndicator {
                volumeIndicatorOverlay
            }

            // Skip indicator
            if let direction = showSkipIndicator {
                skipIndicatorOverlay(direction: direction)
            }

            // Buffering indicator
            if isBuffering && !showScrubPreview && playerError == nil {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                    .accessibilityLabel("Buffering")
            }

            // Player error overlay
            if let err = playerError {
                errorOverlay(err: err)
            }
        }
    }

    @ViewBuilder
    private func errorOverlay(err: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.8))
            Text("Playback Failed")
                .font(.headline)
                .foregroundStyle(.white)
            Text(err)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                // TASK-848: hide Retry when the failure was an expired session. Retrying
                // re-fetches with the same dead token and fails identically every time —
                // offering the button just invites the user to loop. The session has
                // already been torn down by handlePlaybackFailure, so Dismiss returns them
                // to the login screen, which is the only action that can actually help.
                if onPlaybackFailed != nil, !err.localizedCaseInsensitiveContains("session expired") {
                    Button("Retry") {
                        playerError = nil
                        onPlaybackFailed?()
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.dsAccent.opacity(0.8), in: Capsule())
                }
                Button("Dismiss") {
                    #if os(iOS)
                    unlockOrientation()
                    #endif
                    onDismiss?()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.2), in: Capsule())
            }
        }
    }

    // MARK: - Gesture Overlay

    @ViewBuilder
    private func gestureOverlay(geometry: GeometryProxy) -> some View {
        let width = geometry.size.width

        Color.clear
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            #if os(iOS)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        handleDrag(value: value, geometry: geometry)
                    }
                    .onEnded { value in
                        handleDragEnd(value: value, geometry: geometry)
                    }
            )
            #endif
            // Use an exclusive gesture so double-tap wins and single-tap never fires
            // on the same interaction. SpatialTapGesture provides tap location for
            // left/right zone detection without needing a separate overlay.
            #if !os(tvOS)
            .gesture(
                SpatialTapGesture(count: 2)
                    .exclusively(before: SpatialTapGesture(count: 1))
                    .onEnded { value in handleTap(value: value, width: width) }
            )
            #endif
    }

    #if !os(tvOS)
    private func handleTap(value: ExclusiveGesture<SpatialTapGesture, SpatialTapGesture>.Value, width: CGFloat) {
        switch value {
        case .first(let tap):
            let x = tap.location.x
            if x < width * 0.3 {
                skipBackward()
            } else if x > width * 0.7 {
                skipForward()
            } else {
                togglePlayPause()
                scheduleHideControls()
            }
        case .second:
            if showControls {
                // Tap on empty space — dismiss HUD
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
                hideControlsTask?.cancel()
            } else {
                // HUD hidden — show it
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = true
                }
                scheduleHideControls()
            }
        }
    }
    #endif


    // MARK: - Controls Overlay

    @ViewBuilder
    private func controlsOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            // Top bar with gradient background
            HStack {
                Button {
                    onProgressUpdate?(currentTime, duration)
                    // Set the orientation lock flag first (synchronous, no UIKit work),
                    // then dismiss — the deferred requestGeometryUpdate inside
                    // unlockOrientation fires after the sheet animation completes.
                    #if os(iOS)
                    unlockOrientation()
                    #endif
                    onDismiss?()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .padding(12)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Close")

                if let goToShow = onGoToShow {
                    Button {
                        onProgressUpdate?(currentTime, duration)
                        #if os(iOS)
                        unlockOrientation()
                        #endif
                        onDismiss?()
                        // Delay the NavigationLink pop until the fullScreenCover dismiss
                        // animation completes — firing both dismisses synchronously on the
                        // same runloop pass corrupts SwiftUI navigation state, leaving the
                        // show's NavigationLink stuck until other links are pushed/popped.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            goToShow()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tv")
                                .font(.caption.weight(.semibold))
                            Text("Show")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .accessibilityLabel("Go to TV show")
                }

                Spacer()

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                // Right actions: AirPlay + PiP + fill mode + speed selector
                HStack(spacing: 16) {
                    // AirPlay button (iOS only)
                    #if os(iOS)
                    AirPlayButton()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")

                    // Picture-in-Picture button (iOS only)
                    if AVPictureInPictureController.isPictureInPictureSupported(), pipController != nil {
                        Button {
                            if isPiPActive {
                                pipController?.stopPictureInPicture()
                            } else {
                                pipController?.startPictureInPicture()
                            }
                        } label: {
                            Image(systemName: isPiPActive ? "pip.exit" : "pip.enter")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(isPiPActive ? "Exit Picture in Picture" : "Enter Picture in Picture")
                        .accessibilityHint(isPiPActive ? "Returns video to full screen" : "Floats video in a small window")
                    }
                    #endif

                    // Captions / subtitle picker
                    Button {
                        showCaptionsPicker = true
                        hideControlsTask?.cancel()
                    } label: {
                        Image(systemName: "captions.bubble")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Subtitles and Audio")
                    #if os(tvOS)
                    .buttonStyle(.plain)
                    .focused($focusedControl, equals: .captions)
                    #endif

                    // Fill mode toggle (iOS only — Dynamic Island concern)
                    #if os(iOS)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            videoFillMode = videoFillMode == .fill ? .fit : .fill
                            UserDefaults.standard.set(videoFillMode == .fit, forKey: "dsReel.videoFitMode")
                        }
                    } label: {
                        Image(systemName: videoFillMode == .fill
                              ? "rectangle.arrowtriangle.2.inward"
                              : "rectangle.arrowtriangle.2.outward")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(videoFillMode == .fill ? "Switch to fit mode" : "Switch to full screen")
                    #endif

                    // Playback speed button
                    #if os(tvOS)
                    Button {
                        let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                        let currentIdx = speeds.firstIndex(where: { abs($0 - playbackRate) < 0.01 }) ?? 2
                        let nextRate = speeds[(currentIdx + 1) % speeds.count]
                        setPlaybackRate(nextRate)
                    } label: {
                        Text(playbackRate == 1.0 ? "1×" : String(format: "%.2g×", playbackRate))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Playback speed: \(playbackRate == 1.0 ? "normal" : "\(playbackRate, specifier: "%.2g") times")")
                    .buttonStyle(.plain)
                    .focused($focusedControl, equals: .speed)
                    #else
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Button {
                                setPlaybackRate(Float(speed))
                            } label: {
                                HStack {
                                    Text(speed == 1.0 ? "Normal" : "\(speed, specifier: "%.2g")x")
                                    if abs(playbackRate - Float(speed)) < 0.01 {
                                        Image(systemName: "checkmark")
                                            .accessibilityLabel("Selected")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "gear")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Playback speed, \(playbackRate == 1.0 ? "normal" : "\(playbackRate, specifier: "%.2g") times")")
                    #endif
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
            // Same title-safe fix as the bottom transport row: tvOS needs 60pt
            // horizontally. The trailing controls in this bar were sitting in the
            // overscan region on a real TV for the same reason.
            .padding(.horizontal, {
                #if os(tvOS)
                return 60.0
                #else
                return 20.0
                #endif
            }())
            .padding(.top, {
                #if os(tvOS)
                return 40.0
                #else
                return videoFillMode == .fill ? max(geometry.safeAreaInsets.top, 8) : 8
                #endif
            }())
            .padding(.bottom, 16)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Center transport controls — play/pause + skip buttons float in the middle
            Spacer()
            HStack(spacing: 28) {
                // Skip to start
                Button {
                    seek(to: 0, tight: true)
                    currentTime = 0
                    if isPlaying { scheduleHideControls() }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip to start")
                .accessibilityAddTraits(.isButton)

                // Rewind 15s
                Button {
                    let t = max(0, currentTime - skipBackwardSeconds)
                    seek(to: t)
                    currentTime = t
                    showSkipAnimation(direction: .backward)
                    if isPlaying { scheduleHideControls() }
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 35))
                        .foregroundStyle(.white)
                        .frame(minWidth: 55, minHeight: 55)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewind \(Int(skipBackwardSeconds)) seconds")
                .accessibilityAddTraits(.isButton)

                // Play / Pause
                Button {
                    togglePlayPause()
                    scheduleHideControls()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.15), in: Circle())
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .accessibilityAddTraits(.isButton)
                #if os(tvOS)
                .focused($focusedControl, equals: .playPause)
                #endif

                // Forward 15s
                Button {
                    let t = min(duration, currentTime + skipForwardSeconds)
                    seek(to: t)
                    currentTime = t
                    showSkipAnimation(direction: .forward)
                    if isPlaying { scheduleHideControls() }
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 35))
                        .foregroundStyle(.white)
                        .frame(minWidth: 55, minHeight: 55)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Forward \(Int(skipForwardSeconds)) seconds")
                .accessibilityAddTraits(.isButton)

                // Skip to end
                Button {
                    let t = max(0, duration - 3)
                    seek(to: t, tight: true)
                    currentTime = t
                    if isPlaying { scheduleHideControls() }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip to end")
                .accessibilityAddTraits(.isButton)
            }
            #if os(tvOS)
            .focusSection()
            #endif
            Spacer()

            // Bottom controls — scrub bar only
            // contentShape(Rectangle()) ensures taps on gradient background/dead-zone
            // are consumed here and don't bleed through to the gesture overlay below.
            VStack(spacing: 4) {
                // Skip intro button — shown when inside intro chapter bounds
                let showSkipIntro: Bool = {
                    guard let intro = introChapter else { return false }
                    let t = isScrubbing ? scrubTime : currentTime
                    return t >= intro.startSecs && t < intro.endSecs
                }()
                if showSkipIntro, let intro = introChapter {
                    HStack {
                        Spacer()
                        Button {
                            Haptics.play(.medium)
                            seek(to: intro.endSecs, tight: true)
                        } label: {
                            Text("Skip Intro")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(Color.black.opacity(0.65), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skip intro")
                        .accessibilityAddTraits(.isButton)
                        .padding(.trailing, 4)
                    }
                }

                // Progress / scrub bar
                HStack(spacing: 12) {
                    Text(formatTime(isScrubbing ? scrubTime : currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        // .fixedSize() BEFORE .frame() so the label takes its ideal
                        // width (never truncating a timestamp) and the bar yields the
                        // space. Ordered the other way round — .frame then .fixedSize —
                        // the fixedSize overrode the frame entirely and minWidth/maxWidth
                        // were dead modifiers.
                        .fixedSize()
                        .frame(minWidth: 50, alignment: .leading)
                        .accessibilityHidden(true)

                    #if os(iOS)
                    ZStack(alignment: .bottom) {
                        // Chapter tick marks
                        if !chapters.isEmpty && duration > 0 {
                            GeometryReader { sliderGeo in
                                ForEach(chapters.dropFirst(), id: \.id) { ch in
                                    let frac = ch.startSecs / max(duration, 1)
                                    let x = sliderGeo.size.width * frac
                                    Capsule()
                                        .fill(Color.white.opacity(0.55))
                                        .frame(width: 2, height: 8)
                                        .position(x: x, y: sliderGeo.size.height / 2)
                                }
                            }
                            .frame(height: 8)
                            .allowsHitTesting(false)
                        }
                        Slider(
                            value: Binding(
                                get: { isScrubbing ? scrubTime : currentTime },
                                set: { newValue in
                                    // Only update scrubTime during drag — never seek mid-drag.
                                    // Seeking on every tick hammers the server and causes
                                    // stuttering; seek happens once on drag end below.
                                    scrubTime = newValue
                                    isScrubbing = true
                                }
                            ),
                            in: 0...max(duration, 1)
                        ) { editing in
                            if editing {
                                Haptics.play(.selection)
                            } else {
                                isScrubbing = false
                                Haptics.play(.rigid)
                                seek(to: scrubTime, tight: true)
                            }
                        }
                        .tint(.white)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")
                        .accessibilityAdjustableAction { direction in
                            let step = max(duration * 0.01, 5.0)
                            switch direction {
                            case .increment:
                                let t = min(duration, currentTime + step)
                                seek(to: t, tight: true)
                                currentTime = t
                            case .decrement:
                                let t = max(0, currentTime - step)
                                seek(to: t, tight: true)
                                currentTime = t
                            @unknown default: break
                            }
                        }
                    }
                    #else
                    // tvOS: progress bar only (no interactive Slider)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                            Capsule().fill(Color.white)
                                .frame(width: geo.size.width * (duration > 0 ? (isScrubbing ? scrubTime : currentTime) / max(duration, 1) : 0), height: 4)
                            if !chapters.isEmpty && duration > 0 {
                                ForEach(chapters.dropFirst(), id: \.id) { ch in
                                    let frac = ch.startSecs / max(duration, 1)
                                    Capsule()
                                        .fill(Color.white.opacity(0.55))
                                        .frame(width: 2, height: 8)
                                        .position(x: geo.size.width * frac, y: 2)
                                }
                            }
                        }
                    }
                    .frame(height: 8)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")
                    #endif

                    Text("-\(formatTime(max(0, duration - (isScrubbing ? scrubTime : currentTime))))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        // See the elapsed label: .fixedSize() before .frame(). The old
                        // maxWidth: 70 was never enforced anyway, and on a 3-hour film
                        // ("-2:59:59" at tvOS caption size) it would have clipped the
                        // timestamp if it ever had been.
                        .fixedSize()
                        .frame(minWidth: 50, alignment: .trailing)
                        .accessibilityHidden(true)
                }

            }
            // tvOS needs the 60pt title-safe inset horizontally, not just vertically.
            // At 20pt this row sat 40pt inside the overscan region on each side, and a
            // real TV clipped the trailing "-remaining" label off the right edge. The
            // .padding(.bottom) below already branched for tvOS; the horizontal one was
            // missed, so the bug only showed on a TV and never in the simulator.
            .padding(.horizontal, {
                #if os(tvOS)
                return 60.0
                #else
                return 20.0
                #endif
            }())
            .padding(.bottom, {
                #if os(tvOS)
                return 60.0
                #else
                return 40.0
                #endif
            }())
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .contentShape(Rectangle())
        }
    }

    // MARK: - Indicator Overlays

    private var scrubPreviewOverlay: some View {
        VStack(spacing: 8) {
            #if os(iOS)
            // TASK-740: frame preview at the scrub position when trick-play is available.
            if let tp = trickplay, let thumb = tp.thumbnail(at: scrubTime) {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.25), lineWidth: 1))
            }
            #endif
            Text(formatTime(scrubTime))
                .font(.largeTitle.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)

            let delta = scrubTime - scrubStartTime
            Text(delta >= 0 ? "+\(formatTime(delta))" : "-\(formatTime(abs(delta)))")
                .font(.title3.monospacedDigit())
                .foregroundStyle(delta >= 0 ? Color.dsSuccess : Color.dsError)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }

    private var volumeIndicatorOverlay: some View {
        HStack(spacing: 12) {
            Image(systemName: volumeLevel > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.title2)
                .accessibilityLabel(volumeLevel > 0 ? "Volume" : "Muted")

            ProgressView(value: Double(volumeLevel))
                .tint(.white)
                .frame(width: 100)
                .accessibilityLabel("Volume level")
                .accessibilityValue("\(Int(volumeLevel * 100)) percent")
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }


    @ViewBuilder
    private func skipIndicatorOverlay(direction: SkipDirection) -> some View {
        HStack {
            if direction == .backward {
                skipBubble(direction: .backward)
                Spacer()
            } else {
                Spacer()
                skipBubble(direction: .forward)
            }
        }
        .padding(.horizontal, 60)
    }

    private func skipBubble(direction: SkipDirection) -> some View {
        let secs = direction == .backward ? skipBackwardSeconds : skipForwardSeconds
        return VStack(spacing: 4) {
            Image(systemName: direction == .backward ? "gobackward.15" : "goforward.15")
                .font(.title)
                .accessibilityLabel(direction == .backward ? "Skip backward" : "Skip forward")
            Text("\(Int(secs)) sec")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityHidden(true)
    }

    // MARK: - Gesture Handlers

    #if os(iOS)
    private func handleDrag(value: DragGesture.Value, geometry: GeometryProxy) {
        let translation = value.translation
        let width = geometry.size.width
        let height = geometry.size.height

        // Determine gesture type based on start location and direction
        let isHorizontal = abs(translation.width) > abs(translation.height)

        if isHorizontal {
            // Horizontal scrubbing
            if !isScrubbing {
                isScrubbing = true
                scrubStartTime = currentTime
                scrubTime = currentTime
                showScrubPreview = true
            }

            // Calculate time delta based on drag distance
            // Full width = 30 minutes of scrubbing
            let secondsPerPoint = 1800.0 / width
            let timeDelta = translation.width * secondsPerPoint
            scrubTime = max(0, min(duration, scrubStartTime + timeDelta))

            hideControlsTask?.cancel()
        } else {
            // Vertical gesture — full screen controls volume; full height swipe = 0–100%
            if !isAdjustingVolume {
                isAdjustingVolume = true
                volumeStartLevel = volumeLevel
                showVolumeIndicator = true
            }
            scheduleHideVolumeIndicator()

            let delta = Float(-translation.height / height)
            volumeLevel = max(0, min(1, volumeStartLevel + delta))
            setSystemVolume(volumeLevel)

            hideControlsTask?.cancel()
        }
    }

    private func handleDragEnd(value: DragGesture.Value, geometry: GeometryProxy) {
        if isScrubbing {
            seek(to: scrubTime, tight: true)
            isScrubbing = false
            showScrubPreview = false
        }

        // Always reset volume adjustment state and schedule hide
        // The auto-hide timer ensures indicator disappears even if gesture state is inconsistent
        if isAdjustingVolume {
            isAdjustingVolume = false
        }
        // Schedule hide with short delay for smooth UX (indicator stays briefly after release)
        scheduleHideVolumeIndicator()

        scheduleHideControls()
    }
    #endif

    #if os(tvOS)
    private func handleTVSelectPress() {
        // TASK-663: if a scrub is in progress, Select commits it immediately rather
        // than toggling playback.
        if isScrubbing {
            commitTVScrub()
            return
        }
        if showControls {
            // Route Select to whichever control actually holds focus. The focus sink
            // swallows Select for the whole overlay, so without this the top-row
            // buttons could be focused but never activated.
            switch focusedControl {
            case .captions:
                showCaptionsPicker = true
                hideControlsTask?.cancel()
                return
            case .speed:
                let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                let currentIdx = speeds.firstIndex(where: { abs($0 - playbackRate) < 0.01 }) ?? 2
                setPlaybackRate(speeds[(currentIdx + 1) % speeds.count])
                scheduleHideControls()
                return
            default:
                break
            }
            togglePlayPause()
            if isPlaying { scheduleHideControls() }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { showControls = true }
            scheduleHideControls()
        }
    }

    // TASK-663: interactive scrub. D-pad left/right moves a preview position without
    // seeking; rapid presses accelerate the step (10s → 30s → 60s). The actual seek
    // is debounced — it fires once after ~0.6s of no input, or immediately on Select.
    // First press just reveals controls if they were hidden.
    private func handleTVMoveCommand(direction: MoveCommandDirection) {
        // Up/down move focus between the transport row and the top action row
        // (subtitles / playback speed). Without this the top row was unreachable:
        // its buttons had no focus targets, so focus stayed pinned to play/pause.
        if direction == .up || direction == .down {
            guard showControls else {
                withAnimation(.easeInOut(duration: 0.25)) { showControls = true }
                scheduleHideControls()
                return
            }
            hideControlsTask?.cancel()
            switch (direction, focusedControl) {
            case (.up, .playPause), (.up, .hidden), (.up, .none):
                focusedControl = .captions
            case (.down, .captions), (.down, .speed):
                focusedControl = .playPause
            default:
                break
            }
            scheduleHideControls()
            return
        }
        guard direction == .left || direction == .right else { return }
        guard !blockDpadSeek else { return }
        guard showControls else {
            withAnimation(.easeInOut(duration: 0.25)) { showControls = true }
            scheduleHideControls()
            return
        }
        // While focus is on the top action row, left/right moves between those
        // buttons instead of scrubbing the timeline.
        if focusedControl == .captions || focusedControl == .speed {
            hideControlsTask?.cancel()
            focusedControl = (direction == .right) ? .speed : .captions
            scheduleHideControls()
            return
        }
        guard duration > 0 else { return }

        // Accelerate when presses come in quick succession.
        let now = Date()
        if now.timeIntervalSince(lastScrubPressAt) < 0.45 {
            scrubStepRepeat = min(scrubStepRepeat + 1, 12)
        } else {
            scrubStepRepeat = 0
        }
        lastScrubPressAt = now
        let step: Double = scrubStepRepeat >= 8 ? 60 : (scrubStepRepeat >= 3 ? 30 : tvDpadSeekSeconds)

        // Enter scrub mode (preview only — no seek yet).
        if !isScrubbing {
            isScrubbing = true
            scrubStartTime = currentTime
            scrubTime = currentTime
        }
        hideControlsTask?.cancel()  // keep controls up while actively scrubbing
        let delta = direction == .right ? step : -step
        scrubTime = max(0, min(duration, scrubTime + delta))
        showScrubPreview = true

        // Debounce the commit.
        scrubCommitTask?.cancel()
        scrubCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            commitTVScrub()
        }
    }

    // Commit the previewed scrub position to an actual seek and exit scrub mode.
    private func commitTVScrub() {
        scrubCommitTask?.cancel()
        scrubCommitTask = nil
        guard isScrubbing else { return }
        let target = scrubTime
        seek(to: target, tight: true)
        currentTime = target
        isScrubbing = false
        scrubStepRepeat = 0
        withAnimation(.easeInOut(duration: 0.2)) { showScrubPreview = false }
        scheduleHideControls()
    }
    #endif

    // MARK: - Player Controls

    private func setupPlayer() {
        // C1: If a player already exists (e.g. the view re-appeared because PiP
        // is restoring to full screen), don't rebuild it — that would tear down
        // the live AVPlayer driving the PiP window and reset playback to 0.
        // Just re-arm the idle timer and return; the existing observers/Now Playing
        // were preserved through the PiP-aware cleanup().
        if player != nil {
            UIApplication.shared.isIdleTimerDisabled = true
            return
        }
        didSetupPlayer = true
        // Keep the screen awake during playback. Without this, tvOS shows the
        // screensaver and iOS auto-locks during long, interaction-free stretches
        // (e.g. a 90-minute film), interrupting the video.
        UIApplication.shared.isIdleTimerDisabled = true
        // FIX-5: When using QC relay, HLS segments must include Cookie: type=tunnel.
        // AVURLAssetHTTPHeaderFieldsKey only applies to the master playlist request.
        // AVURLAssetHTTPCookiesKey propagates the cookie to ALL requests made by the
        // asset (variant playlists, .ts/.m4s segments) via the system cookie jar.
        let asset: AVURLAsset
        if usesTunnelCookie,
           let cookie = HTTPCookie(properties: [
               .name: "type",
               .value: "tunnel",
               .domain: url.host ?? "",
               .path: "/",
           ]) {
            asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: [cookie]])
        } else {
            asset = AVURLAsset(url: url)
        }
        let playerItem = AVPlayerItem(asset: asset)
        // TASK-739: apply the user's subtitle appearance (size / color / background).
        applySubtitleStyle(to: playerItem)
        let newPlayer = AVPlayer(playerItem: playerItem)
        // Let AVPlayer wait and rebuffer automatically when bandwidth is insufficient.
        // This allows the player to pause internally, accumulate buffer, then resume
        // on its own when the connection recovers — no user action required.
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        player = newPlayer

        // Observe playback status
        player?.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { status in
                Task { @MainActor in
                    isPlaying = status == .playing
                    isBuffering = status == .waitingToPlayAtSpecifiedRate
                }
            }
            .store(in: &cancellables)

        // Observe player item status to surface errors (e.g. 404 on HLS playlist,
        // unsupported codec, network failure). Weak capture prevents a retain cycle
        // between the Combine subscription and the AVPlayerItem.
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak playerItem] status in
                if status == .failed {
                    let msg = playerItem?.error.map { GestureVideoPlayer.friendlyPlayerError($0) } ?? "Unable to play this video."
                    Task { @MainActor in
                        playerError = msg
                        isBuffering = false
                    }
                } else if status == .readyToPlay, let item = playerItem {
                    // TASK-738: apply the user's remembered audio-track language so playback
                    // doesn't always default to track 0. Best-effort — falls through to the
                    // asset default if no preference is stored or no track matches.
                    Task { @MainActor in
                        applyPreferredAudioLanguage(to: item)
                        applyAutoEnabledForcedSubtitle(to: item)
                    }
                }
            }
            .store(in: &cancellables)

        // Seed the scrubber with the server's full runtime immediately, before the
        // playlist's duration is known. For a live-window HLS transcode, playerItem's
        // duration only reflects what's been generated so far, so without this the
        // scrubber starts pinned to the end.
        if serverDuration > 0 {
            duration = serverDuration
        }

        // Observe duration and seek to resume position when ready. Use the LARGER of
        // the playlist duration and the server's known full runtime: a live-window HLS
        // playlist under-reports duration while transcoding (it only knows the segments
        // written so far), so trusting playerItem.duration alone makes the scrubber jump
        // to the end. Once the transcode finishes (or for direct play) playerItem's
        // duration matches the server's and max() is a no-op.
        playerItem.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { dur in
                if dur.isNumeric {
                    let secs = CMTimeGetSeconds(dur)
                    Task { @MainActor in
                        duration = max(secs, serverDuration)
                        let effective = duration
                        if !hasResumedPosition && resumePosition > 0 && resumePosition < effective {
                            hasResumedPosition = true
                            seek(to: resumePosition)
                            currentTime = resumePosition
                        }
                        updateNowPlayingPlayback()
                    }
                }
            }
            .store(in: &cancellables)

        // Periodic time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let secs = CMTimeGetSeconds(time)
            Task { @MainActor in
                if !isScrubbing {
                    currentTime = secs
                    onProgressUpdate?(currentTime, duration)
                    updateNowPlayingPlayback()
                }
            }
        }

        // Observe playback end for autoplay-next support
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak playerItem] _ in
                guard playerItem != nil else { return }
                Task { @MainActor in onPlaybackFinished?() }
            }
            .store(in: &cancellables)

        player?.rate = playbackRate
        scheduleHideControls()
        setupNowPlaying()
    }

    // MARK: - Trick-play (TASK-740)

    #if os(iOS)
    private func loadTrickplay() {
        guard let base = trickplayBaseURL else { return }
        Task {
            let tp = await Trickplay.load(baseURL: base, token: authToken, usesTunnelCookie: usesTunnelCookie)
            await MainActor.run { trickplay = tp }
        }
    }
    #endif

    // MARK: - Subtitle Styling (TASK-739)

    /// Build AVTextStyleRules from the user's stored subtitle-appearance preferences
    /// and apply them to the player item. No-op (system default styling) when the
    /// user hasn't customised anything. Keys are registered with sensible defaults
    /// in SubtitleStyle.registerDefaults().
    private func applySubtitleStyle(to item: AVPlayerItem) {
        let d = UserDefaults.standard
        var attrs: [String: Any] = [:]

        // Font scale relative to the video frame height (1.0 = system default ~5%).
        let scale = d.double(forKey: "dsReel.subtitleScale")
        if scale > 0 && abs(scale - 1.0) > 0.001 {
            attrs[kCMTextMarkupAttribute_RelativeFontSize as String] = 5.0 * scale
        }

        // Foreground text color.
        if let hex = d.string(forKey: "dsReel.subtitleTextColor"),
           let rgb = SubtitleStyle.rgb(fromHex: hex) {
            attrs[kCMTextMarkupAttribute_ForegroundColorARGB as String] = [1.0, rgb.r, rgb.g, rgb.b]
        }

        // Background box opacity (0 = none, 1 = solid black box).
        let bgOpacity = d.double(forKey: "dsReel.subtitleBackgroundOpacity")
        if bgOpacity > 0.001 {
            attrs[kCMTextMarkupAttribute_BackgroundColorARGB as String] = [bgOpacity, 0.0, 0.0, 0.0]
        }

        guard !attrs.isEmpty, let rule = AVTextStyleRule(textMarkupAttributes: attrs) else {
            item.textStyleRules = nil
            return
        }
        item.textStyleRules = [rule]
    }

    // MARK: - Now Playing / Remote Commands (TASK-724)

    /// Populate the system Now Playing info and register remote-command handlers so
    /// Control Center, the Lock Screen, the Apple TV "Now Playing" pane, and Siri
    /// ("pause", "skip back 30 seconds") all drive this player. Best-effort.
    private func setupNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: itemTitle.isEmpty ? title : itemTitle
        ]
        if let year = itemYear {
            info[MPMediaItemPropertyArtist] = String(year)
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(player?.rate ?? 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        let center = MPRemoteCommandCenter.shared()
        // Clear any handlers from a prior player instance before re-adding.
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [self] _ in
            if !isPlaying { togglePlayPause() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [self] _ in
            if isPlaying { togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [self] _ in
            togglePlayPause()
            return .success
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardSeconds)]
        center.skipForwardCommand.addTarget { [self] _ in
            skipForward()
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardSeconds)]
        center.skipBackwardCommand.addTarget { [self] _ in
            skipBackward()
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            seek(to: e.positionTime, tight: true)
            currentTime = e.positionTime
            updateNowPlayingPlayback()
            return .success
        }
    }

    /// Refresh just the volatile Now Playing fields (position + rate). Cheap; called
    /// from the periodic time observer.
    private func updateNowPlayingPlayback() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        // Use the player's actual rate as the source of truth — the isPlaying @State
        // flag lags a play/pause toggle by one timeControlStatus callback.
        let actualRate = Double(player?.rate ?? 0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = actualRate
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Remove Now Playing info and unregister command handlers on teardown.
    private func teardownNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }

    private func cleanup() {
        #if os(iOS)
        // C1: Entering Picture-in-Picture dismisses the full-screen player view,
        // which fires .onDisappear → cleanup(). If we tore everything down here,
        // PiP would die the instant it started (and the idle timer / Now Playing
        // would be wiped out from under it). When PiP is live, do only the
        // non-destructive UI-timer cleanup and bail — the player, observers,
        // audio session, idle timer, Now Playing, and the PiP controller all stay
        // alive so playback continues in the floating window. The real teardown
        // runs on the next cleanup() after PiP stops and the view dismisses for real.
        if isPiPActive {
            hideControlsTask?.cancel()
            hideVolumeIndicatorTask?.cancel()
            skipHideTask?.cancel()
            controlsHideTask?.cancel()
            return
        }
        #endif
        // Re-enable auto-lock / screensaver now that playback is ending.
        UIApplication.shared.isIdleTimerDisabled = false
        teardownNowPlaying()
        #if os(iOS)
        pipController?.delegate = nil
        pipController = nil
        pipDelegate = nil
        isPiPActive = false
        #endif
        hideControlsTask?.cancel()
        hideVolumeIndicatorTask?.cancel()
        skipHideTask?.cancel()
        controlsHideTask?.cancel()
        #if os(tvOS)
        scrubCommitTask?.cancel()  // TASK-663: don't fire a deferred seek post-teardown
        scrubCommitTask = nil
        #endif
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        #if os(iOS)
        // AVAudioSession.setActive can block on the main thread (hang risk). Teardown
        // has no UI dependency, so run it off-main.
        Task.detached(priority: .utility) {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                // Best-effort deactivation; nothing actionable on failure (TASK-767: log for diagnosis).
                orientLog.debug("AVAudioSession.setActive(false) failed on teardown — \(error.localizedDescription)")
            }
        }
        #endif
        player = nil
        cancellables.removeAll()
        // Only post playerDidDismiss if setupPlayer actually ran (TASK-430).
        if didSetupPlayer {
          NotificationCenter.default.post(name: .playerDidDismiss, object: nil)
        }
    }

    private func togglePlayPause() {
        Haptics.play(.medium)
        if isPlaying {
            player?.pause()
            hideControlsTask?.cancel() // Keep controls visible when paused
        } else {
            player?.rate = playbackRate
            scheduleHideControls() // Auto-hide when playing
        }
        // Reflect the new play/pause state in Now Playing immediately (the time
        // observer would otherwise lag by up to 0.5s, and won't tick while paused).
        DispatchQueue.main.async { updateNowPlayingPlayback() }
    }

    /// Seek to a time position.
    /// - tight: frame-accurate seek (zero tolerance) — used for scrub-end and chapter seeks.
    /// - fast (default): seeks to nearest keyframe within ±2s — used for skip buttons.
    ///   With 2s HLS segments keyframes are at most 2s away, so this lands accurately
    ///   without the multi-segment overshoot that .positiveInfinity caused.
    private func seek(to time: Double, tight: Bool = false) {
        // Coalesce rapid seeks. If a seek is already running, just record the
        // latest target (overwriting any earlier pending one) and bail — the
        // completion handler will drain to it. This prevents AVPlayer from
        // cancelling/restarting seeks on every tap, which thrashed the HLS
        // position instead of accumulating the skips.
        guard !isSeekInProgress else {
            pendingSeekTarget = time
            pendingSeekTight = tight
            return
        }

        isSeekInProgress = true
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let toleranceBefore: CMTime
        let toleranceAfter: CMTime
        if tight {
            toleranceBefore = .zero
            toleranceAfter = .zero
        } else {
            let tol = CMTime(seconds: 2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            toleranceBefore = tol
            toleranceAfter = tol
        }

        guard let player else {
            // No player yet — clear state so a later seek isn't permanently blocked.
            isSeekInProgress = false
            return
        }

        player.seek(to: cmTime, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { _ in
            // Completion fires on an arbitrary queue; hop to the main actor to
            // touch @State and to drain any pending target safely.
            Task { @MainActor in
                isSeekInProgress = false
                if let next = pendingSeekTarget {
                    let nextTight = pendingSeekTight
                    pendingSeekTarget = nil
                    pendingSeekTight = false
                    seek(to: next, tight: nextTight)
                }
            }
        }
    }

    private func skipForward() {
        let newTime = min(duration, currentTime + skipForwardSeconds)
        seek(to: newTime)
        currentTime = newTime
        Haptics.play(.light)
        showSkipAnimation(direction: .forward)
        if isPlaying { scheduleHideControls() }
    }

    private func skipBackward() {
        let newTime = max(0, currentTime - skipBackwardSeconds)
        seek(to: newTime)
        currentTime = newTime
        Haptics.play(.light)
        showSkipAnimation(direction: .backward)
        if isPlaying { scheduleHideControls() }
    }

    private func showSkipAnimation(direction: SkipDirection) {
        withAnimation(.easeOut(duration: 0.15)) {
            showSkipIndicator = direction
        }

        skipHideTask?.cancel()
        skipHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                showSkipIndicator = nil
            }
        }
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: "dsReel.playbackRate")
        Haptics.play(.selection)
        if isPlaying {
            player?.rate = rate
        }
    }

    /// TASK-738: select the audio option matching the user's last-chosen language, if any.
    private func applyPreferredAudioLanguage(to item: AVPlayerItem) {
        guard let pref = UserDefaults.standard.string(forKey: "dsReel.preferredAudioLanguage"),
              !pref.isEmpty else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
            let match = group.options.first { opt in
                opt.extendedLanguageTag == pref || opt.locale?.identifier == pref
            }
            if let match {
                await MainActor.run { item.select(match, in: group) }
            }
        }
    }

    /// TASK-828: auto-enable the single forced/translation subtitle track the server
    /// flagged with `autoEnable:true`, at playback start, WITHOUT any user action.
    ///
    /// This is the "A Bridge Too Far" case — the German/French scenes in an otherwise
    /// English film. It is deliberately NOT surfaced to the user as "subtitles were
    /// turned on": there is no toast, no persisted preference, no menu state change the
    /// user initiated. It simply selects the correct forced AVMediaSelectionOption so
    /// foreign dialogue is translated. Full subtitles are never touched here — they stay
    /// off until the user picks them.
    ///
    /// Uses BOTH signals per the contract: the server's `autoEnable`/`language`/`type`
    /// fields decide *whether* to enable and *which language*, and AVFoundation's native
    /// `.containsOnlyForcedSubtitles` characteristic on the legible group locates the
    /// matching forced rendition (delivered with FORCED=YES in the HLS manifest).
    private func applyAutoEnabledForcedSubtitle(to item: AVPlayerItem) {
        guard !didApplyForcedSubtitle else { return }
        // Only one forced track ever carries autoEnable (contract guarantee).
        guard let forcedMeta = subtitles.first(where: { $0.autoEnable && $0.forced && !$0.isImage }) else {
            didApplyForcedSubtitle = true
            return
        }
        didApplyForcedSubtitle = true
        let wantLang = forcedMeta.language.lowercased()
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }

            // Prefer options AVFoundation itself marks as forced-only, then match language.
            let forcedOptions = group.options.filter {
                $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            }
            func langMatches(_ opt: AVMediaSelectionOption) -> Bool {
                guard wantLang != "und", !wantLang.isEmpty else { return true }
                let tag = (opt.extendedLanguageTag ?? opt.locale?.identifier ?? "").lowercased()
                return tag == wantLang || tag.hasPrefix(wantLang + "-") || wantLang.hasPrefix(tag)
            }

            let match = forcedOptions.first(where: langMatches)
                ?? forcedOptions.first
                // Fallback if the manifest didn't tag FORCED but the server told us the
                // display name (already suffixed "(Forced)") — match by name/language.
                ?? group.options.first(where: { opt in
                    opt.displayName == forcedMeta.name && langMatches(opt)
                })

            guard let match else { return }
            await MainActor.run { item.select(match, in: group) }
        }
    }

    private func scheduleHideControls() {
        // TASK-211: Keep controls always visible when VoiceOver is running to prevent dead zones
        #if os(iOS)
        guard !UIAccessibility.isVoiceOverRunning else { return }
        #endif
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }

    private func scheduleHideVolumeIndicator() {
        hideVolumeIndicatorTask?.cancel()
        hideVolumeIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) {
                    showVolumeIndicator = false
                }
            }
        }
    }


    // MARK: - Volume Control

    #if os(iOS)
    // Configure + activate the shared playback audio session off the main thread.
    // setCategory/setActive can block the main thread (AVAudioSession hang risk), and
    // none of it produces UI — so do it on a utility task. Idempotent: AVAudioSession
    // is a process-wide singleton, so calling this from setupVolumeObserver and
    // setupPiP just re-applies the same config harmlessly.
    private func activatePlaybackAudioSession() {
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
    }
    #endif

    private func setupVolumeObserver() {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        activatePlaybackAudioSession()
        // outputVolume is readable immediately without waiting for activation.
        volumeLevel = audioSession.outputVolume

        // Show the volume HUD when hardware volume buttons are pressed.
        // dropFirst() skips the initial emission so the HUD doesn't appear on launch.
        audioSession.publisher(for: \.outputVolume)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { newVolume in
                Task { @MainActor in
                    volumeLevel = newVolume
                    showVolumeIndicator = true
                    scheduleHideVolumeIndicator()
                }
            }
            .store(in: &cancellables)
        #else
        volumeLevel = 0.5
        #endif
    }

    private func setSystemVolume(_ volume: Float) {
        #if os(iOS)
        VolumeSliderCache.shared.setVolume(volume)
        #endif
    }
}

#if os(iOS)
/// Caches the MPVolumeView slider to avoid creating a new one on every volume change
@MainActor
private final class VolumeSliderCache {
    static let shared = VolumeSliderCache()

    private var slider: UISlider?
    private let volumeView = MPVolumeView(frame: .zero)

    private init() {
        // Find the slider in the volume view
        slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
    }

    func setVolume(_ volume: Float) {
        slider?.value = volume
    }
}
#endif

// Extension to close the struct properly - the closing brace was moved above
private extension GestureVideoPlayer {

    // MARK: - Helpers

    #if os(iOS)
    private func setupPiP(layer: AVPlayerLayer) {
        guard !isPiPActive else { return }
        // The playback session is already activated in setupVolumeObserver (onAppear,
        // before this runs). Re-apply off-main rather than blocking here (hang risk).
        activatePlaybackAudioSession()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // Teardown old controller if layer changed (e.g. videoFillMode toggle)
        if pipController != nil {
            pipController?.delegate = nil
            pipController = nil
            pipDelegate = nil
        }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        let delegate = PictureInPictureDelegate(
            onWillStart: { isPiPActive = true },
            onDidStop: { isPiPActive = false }
        )
        controller.delegate = delegate
        pipController = controller
        pipDelegate = delegate
    }

    /// Locks orientation to landscape when the player appears.
    /// Uses setNeedsUpdateOfSupportedInterfaceOrientations (declarative) so UIKit
    /// rotates on its own next layout pass without competing with the fullScreenCover
    /// presentation animation. requestGeometryUpdate (imperative) was the root cause
    /// of gesture-gate timeouts and multi-minute touch freezes.
    private func lockLandscape() {
        orientLog.info("GestureVideoPlayer: locking landscape (onAppear)")
        AppDelegate.setOrientation(.landscape)
    }

    /// Restores portrait lock when the player dismisses.
    /// Called from: dismiss button tap, onDisappear safety catch.
    private func unlockOrientation() {
        orientLog.info("GestureVideoPlayer: restoring portrait (dismiss)")
        AppDelegate.setOrientation(.portrait)
    }

    /// Returns the screen for the active window scene, avoiding the deprecated UIScreen.main.
    private var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.screen
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.screen
    }
    #endif

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// TASK-375: Maps common AVFoundation error codes to user-friendly messages.
    /// Falls back to the system localizedDescription for unrecognised codes.
    private static func friendlyPlayerError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            switch nsError.code {
            case -11800: return "Playback failed. The file may be corrupted."
            case -11828: return "Format not supported."
            case -11849: return "Could not load media."
            case -11850: return "Playback failed. The media is not accessible."
            case -11819: return "The operation was cancelled."
            case -11821: return "Cannot connect to the server."
            default: break
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Video Player Layer

/// A platform-specific view that wraps AVPlayerLayer for better performance
#if os(iOS) || os(tvOS)
struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    #if os(iOS)
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil
    #endif

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        view.playerLayer.videoGravity = gravity
        #if os(iOS)
        let layer = view.playerLayer
        Task { @MainActor in onLayerReady?(layer) }
        #endif
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
            #if os(iOS)
            // Defer onLayerReady so @State writes inside it (pipController, pipDelegate)
            // land after SwiftUI's current render pass, not inside updateUIView.
            let layer = uiView.playerLayer
            Task { @MainActor in onLayerReady?(layer) }
            #endif
        }
    }

    class PlayerUIView: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        var player: AVPlayer? {
            get { playerLayer.player }
            set { playerLayer.player = newValue }
        }
    }
}
#else
struct VideoPlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> NSView {
        let view = PlayerNSView()
        view.player = player
        view.playerLayer?.videoGravity = gravity
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? PlayerNSView {
            view.player = player
            view.playerLayer?.videoGravity = gravity
        }
    }

    class PlayerNSView: NSView {
        var playerLayer: AVPlayerLayer?

        var player: AVPlayer? {
            didSet {
                if playerLayer == nil {
                    playerLayer = AVPlayerLayer()
                    playerLayer?.videoGravity = .resizeAspect
                    wantsLayer = true
                    layer = playerLayer
                }
                playerLayer?.player = player
            }
        }

        override func layout() {
            super.layout()
            playerLayer?.frame = bounds
        }
    }
}
#endif

// MARK: - PiP Delegate

#if os(iOS)
private final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    var onWillStart: () -> Void
    var onDidStop: () -> Void

    init(onWillStart: @escaping () -> Void, onDidStop: @escaping () -> Void) {
        self.onWillStart = onWillStart
        self.onDidStop = onDidStop
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onWillStart()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        AccessibilityNotification.Announcement("Picture in Picture started").post()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onDidStop()
        AccessibilityNotification.Announcement("Picture in Picture stopped").post()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
#endif

// MARK: - AirPlay Button

#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Color.dsAccent)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

// MARK: - Subtitle & Audio Picker

/// Half-sheet picker for subtitle and audio track selection.
private struct SubtitleAudioPickerView: View {
    let player: AVPlayer
    var chapters: [Chapter] = []
    // TASK-828: server subtitle semantics, used to split the list into Forced /
    // Full / (greyed) Image and to label the auto-enabled forced track.
    var subtitles: [Subtitle] = []
    var itemTitle: String = ""
    var itemYear: Int? = nil
    var onOffsetChange: ((Double) -> Void)? = nil
    var onSeekToChapter: ((Double) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var subtitleGroup: AVMediaSelectionGroup? = nil
    @State private var audioGroup: AVMediaSelectionGroup? = nil
    @State private var isLoading: Bool = true
    @State private var currentSelection: AVMediaSelection? = nil
    @State private var subtitleOffsetSeconds: Double = 0
    @State private var showSubtitleDownload: Bool = false
    @State private var subtitleSearchResults: [SubtitleResult] = []
    @State private var isSearchingSubtitles: Bool = false
    @State private var subtitleDownloadError: String? = nil
    @State private var subtitleDownloadMessage: String? = nil

    var body: some View {
        NavigationStack {
            contentView
                .navigationTitle("Subtitles & Audio")
                #if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .task {
            async let subtitle = player.currentItem?.asset.loadMediaSelectionGroup(for: .legible)
            async let audio = player.currentItem?.asset.loadMediaSelectionGroup(for: .audible)
            subtitleGroup = try? await subtitle
            audioGroup = try? await audio
            currentSelection = player.currentItem?.currentMediaSelection
            isLoading = false
        }
        .sheet(isPresented: $showSubtitleDownload) {
            SubtitleDownloadSheet(
                itemTitle: itemTitle,
                itemYear: itemYear,
                results: subtitleSearchResults,
                isSearching: isSearchingSubtitles,
                error: subtitleDownloadError,
                onDownload: { result in
                    Task { await downloadSubtitle(result) }
                }
            )
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        if isLoading {
            ProgressView("Loading tracks…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section("Subtitles") {
                    subtitleSection
                    subtitleOffsetRow
                    findSubtitlesButton
                }
                Section("Audio") {
                    audioSection
                }
                if !chapters.isEmpty {
                    Section("Chapters") {
                        chaptersSection
                    }
                }
            }
        }
    }

    // TASK-828: match a server metadata entry to a live AVMediaSelectionOption.
    // Forced tracks: prefer the AVFoundation forced characteristic, then language.
    // Full tracks: language + NOT forced-characteristic. Language uses loose prefix
    // matching because tags vary ("de" vs "de-DE").
    private func metadata(for option: AVMediaSelectionOption) -> Subtitle? {
        let optForced = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
        let optLang = (option.extendedLanguageTag ?? option.locale?.identifier ?? "").lowercased()
        func langMatches(_ meta: Subtitle) -> Bool {
            let m = meta.language.lowercased()
            guard m != "und", !m.isEmpty, !optLang.isEmpty else { return true }
            return optLang == m || optLang.hasPrefix(m + "-") || m.hasPrefix(optLang)
        }
        // Exact display-name match wins when the server label matches AVFoundation's.
        if let byName = subtitles.first(where: { !$0.isImage && $0.name == option.displayName }) {
            return byName
        }
        return subtitles.first {
            !$0.isImage && $0.forced == optForced && langMatches($0)
        }
    }

    @ViewBuilder
    private var subtitleSection: some View {
        if let group = subtitleGroup {
            let noneSelected = currentSelection?.selectedMediaOption(in: group) == nil
            // "None" applies to full subtitles; forced/translation is handled separately
            // and auto-managed, so keep the off control at the top of the list.
            Button {
                player.currentItem?.select(nil, in: group)
                currentSelection = player.currentItem?.currentMediaSelection
            } label: {
                trackRow(name: "Off", isSelected: noneSelected)
            }
            .buttonStyle(.plain)

            // Partition the live options by the server's semantics. Options with no
            // metadata (offline/older server) fall into `full` so nothing disappears.
            let forcedOptions = group.options.filter { metadata(for: $0)?.forced == true }
            let fullOptions = group.options.filter { metadata(for: $0)?.forced != true }

            // Forced / translation tracks — labelled as translation, not "subtitles",
            // because these carry only the foreign-scene dialogue.
            ForEach(forcedOptions, id: \.self) { option in
                subtitleOptionRow(option, in: group, forced: true)
            }

            ForEach(fullOptions, id: \.self) { option in
                subtitleOptionRow(option, in: group, forced: false)
            }

            // Image (bitmap) subtitles: listed but greyed and non-selectable — the
            // server never renders them (contract: out of scope).
            ForEach(imageSubtitles, id: \.self) { meta in
                imageSubtitleRow(meta)
            }
        } else if !imageSubtitles.isEmpty {
            // Direct/remux with only image subs: no legible group at all.
            ForEach(imageSubtitles, id: \.self) { meta in
                imageSubtitleRow(meta)
            }
        } else {
            Text("No subtitle tracks available")
                .foregroundStyle(.secondary)
        }
        if let msg = subtitleDownloadMessage {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imageSubtitles: [Subtitle] {
        subtitles.filter { $0.isImage }
    }

    @ViewBuilder
    private func subtitleOptionRow(_ option: AVMediaSelectionOption,
                                   in group: AVMediaSelectionGroup,
                                   forced: Bool) -> some View {
        let isSelected = currentSelection?.selectedMediaOption(in: group) == option
        Button {
            player.currentItem?.select(option, in: group)
            currentSelection = player.currentItem?.currentMediaSelection
        } label: {
            trackRow(name: option.displayName,
                     isSelected: isSelected,
                     detail: forced ? "Translation" : nil)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func imageSubtitleRow(_ meta: Subtitle) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name)
                Text("Image subtitles — not supported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meta.name), image subtitles, not supported")
        #if os(tvOS)
        // Keep the row focusable so tvOS focus can traverse past it without a dead-end,
        // but it performs no action.
        .focusable(true)
        #endif
    }

    @ViewBuilder
    private var subtitleOffsetRow: some View {
        #if os(iOS)
        Stepper(
            value: $subtitleOffsetSeconds,
            in: -10...10,
            step: 0.1
        ) {
            HStack {
                Text("Offset")
                Spacer()
                Text(subtitleOffsetSeconds == 0
                     ? "0.0s"
                     : String(format: "%+.1fs", subtitleOffsetSeconds))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .onChange(of: subtitleOffsetSeconds) { _, v in
            onOffsetChange?(v)
        }
        .accessibilityLabel("Subtitle offset, \(String(format: "%.1f", subtitleOffsetSeconds)) seconds")
        #else
        HStack {
            Text("Offset")
            Spacer()
            Button("-") { subtitleOffsetSeconds = max(-10, subtitleOffsetSeconds - 0.5); onOffsetChange?(subtitleOffsetSeconds) }
                .accessibilityLabel("Decrease subtitle offset")
            Text(subtitleOffsetSeconds == 0 ? "0.0s" : String(format: "%+.1fs", subtitleOffsetSeconds))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 50)
            Button("+") { subtitleOffsetSeconds = min(10, subtitleOffsetSeconds + 0.5); onOffsetChange?(subtitleOffsetSeconds) }
                .accessibilityLabel("Increase subtitle offset")
        }
        #endif
    }

    @ViewBuilder
    private var findSubtitlesButton: some View {
        if !OpenSubtitlesAPIKey.isEmpty {
            Button {
                subtitleDownloadError = nil
                subtitleSearchResults = []
                showSubtitleDownload = true
                Task { await searchSubtitles() }
            } label: {
                Label("Find Subtitles Online", systemImage: "magnifyingglass.circle")
            }
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        if let group = audioGroup {
            ForEach(group.options, id: \.self) { option in
                let isSelected = currentSelection?.selectedMediaOption(in: group) == option
                Button {
                    player.currentItem?.select(option, in: group)
                    currentSelection = player.currentItem?.currentMediaSelection
                    // TASK-738: remember the chosen audio language so the next playback
                    // defaults to it instead of always falling back to track 0.
                    if let lang = option.extendedLanguageTag ?? option.locale?.identifier {
                        UserDefaults.standard.set(lang, forKey: "dsReel.preferredAudioLanguage")
                    }
                } label: {
                    trackRow(name: option.displayName, isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("No audio tracks available")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chaptersSection: some View {
        ForEach(chapters, id: \.id) { ch in
            Button {
                onSeekToChapter?(ch.startSecs)
                dismiss()
            } label: {
                HStack {
                    Text(ch.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(formatChapterTime(ch.startSecs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func trackRow(name: String, isSelected: Bool, detail: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "checkmark")
                .foregroundStyle(Color.dsAccent)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(!isSelected)
                .accessibilityLabel("Selected")
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func formatChapterTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func searchSubtitles() async {
        guard !itemTitle.isEmpty else { return }
        isSearchingSubtitles = true
        defer { isSearchingSubtitles = false }
        do {
            let client = OpenSubtitlesClient()
            subtitleSearchResults = try await client.searchSubtitles(query: itemTitle, year: itemYear)
        } catch {
            subtitleDownloadError = error.localizedDescription
        }
    }

    private func downloadSubtitle(_ result: SubtitleResult) async {
        do {
            let client = OpenSubtitlesClient()
            let localURL = try await client.downloadSubtitle(fileId: result.id)
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let subtitlesDir = docsURL.appendingPathComponent("Subtitles", isDirectory: true)
            try? FileManager.default.createDirectory(at: subtitlesDir, withIntermediateDirectories: true)
            let destURL = subtitlesDir.appendingPathComponent("\(itemTitle).srt")
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: localURL, to: destURL)
            showSubtitleDownload = false
            subtitleDownloadMessage = "Subtitles saved — restart playback to apply."
        } catch {
            subtitleDownloadError = "Download failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Subtitle Download Sheet

private struct SubtitleDownloadSheet: View {
    let itemTitle: String
    let itemYear: Int?
    let results: [SubtitleResult]
    let isSearching: Bool
    let error: String?
    let onDownload: (SubtitleResult) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView("Searching OpenSubtitles…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(err))
                } else if results.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "captions.bubble", description: Text("No subtitles found for \"\(itemTitle)\""))
                } else {
                    List(results) { result in
                        Button {
                            onDownload(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.fileName)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    Text(result.language.uppercased())
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.dsAccent)
                                    Text("\(result.downloadCount) downloads")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Find Subtitles")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
}

// MARK: - Preview

#Preview {
    GestureVideoPlayer(
        url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
        title: "Big Buck Bunny"
    )
}
