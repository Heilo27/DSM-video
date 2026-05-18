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

private let orientLog = Logger(subsystem: "com.dsm.orientation", category: "player")

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
    var chapters: [Chapter] = []
    var itemID: String = ""
    var itemTitle: String = ""
    var itemYear: Int? = nil
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
    @State private var playbackRate: Float = 1.0
    @State private var isBuffering: Bool = true
    @State private var playerError: String?

    // Gesture states
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @State private var scrubStartTime: Double = 0
    @State private var showScrubPreview: Bool = false

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
    @State private var showCaptionsPicker: Bool = false
    @State private var didSetupPlayer: Bool = false
    @State private var subtitleOffsetSeconds: Double = 0

    private let skipSeconds: Double = 15

    enum SkipDirection {
        case backward, forward
    }

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
            #endif
    }

    private var playerContent: some View {
        let base = GeometryReader { geometry in
            playerZStack(geometry: geometry)
        }
        .onChange(of: showControls) { _, newValue in
            if newValue {
                controlsInteractive = true
            } else {
                controlsHideTask?.cancel()
                controlsHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    controlsInteractive = false
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Play/Pause") { togglePlayPause() }
        .accessibilityAction(named: "Skip forward \(Int(skipSeconds)) seconds") { skipForward() }
        .accessibilityAction(named: "Skip backward \(Int(skipSeconds)) seconds") { skipBackward() }
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
                        itemTitle: itemTitle,
                        itemYear: itemYear,
                        onOffsetChange: { offset in subtitleOffsetSeconds = offset; onSubtitleOffsetChange?(offset) },
                        onSeekToChapter: { t in seek(to: t) }
                    )
                }
            }
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
                if onPlaybackFailed != nil {
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
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Button {
                                setPlaybackRate(Float(speed))
                            } label: {
                                HStack {
                                    Text(speed == 1.0 ? "Normal" : "\(speed, specifier: "%.2g")x")
                                    if playbackRate == Float(speed) {
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
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, videoFillMode == .fill ? max(geometry.safeAreaInsets.top, 8) : 8)
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
            HStack(spacing: 40) {
                // Rewind 15s
                Button {
                    let t = max(0, currentTime - 15)
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
                .accessibilityLabel("Rewind 15 seconds")
                .accessibilityAddTraits(.isButton)

                // Play / Pause
                Button {
                    togglePlayPause()
                    scheduleHideControls()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.white)
                        .frame(minWidth: 75, minHeight: 75)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .accessibilityAddTraits(.isButton)

                // Forward 15s
                Button {
                    let t = min(duration, currentTime + 15)
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
                .accessibilityLabel("Forward 15 seconds")
                .accessibilityAddTraits(.isButton)
            }
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
                        .frame(width: 50, alignment: .leading)
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
                            if !editing {
                                isScrubbing = false
                                seek(to: scrubTime, tight: true)
                            }
                        }
                        .tint(.white)
                        .scaleEffect(y: 1.3)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")
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
                        .frame(minWidth: 50, maxWidth: 70, alignment: .trailing)
                        .accessibilityHidden(true)
                }

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
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
        VStack(spacing: 4) {
            Image(systemName: direction == .backward ? "gobackward.15" : "goforward.15")
                .font(.title)
                .accessibilityLabel(direction == .backward ? "Skip backward" : "Skip forward")
            Text("\(Int(skipSeconds)) sec")
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

    // MARK: - Player Controls

    private func setupPlayer() {
        didSetupPlayer = true
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
                isPlaying = status == .playing
                isBuffering = status == .waitingToPlayAtSpecifiedRate
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
                    playerError = msg
                    isBuffering = false
                }
            }
            .store(in: &cancellables)

        // Observe duration and seek to resume position when ready
        playerItem.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { dur in
                if dur.isNumeric {
                    duration = CMTimeGetSeconds(dur)

                    // Seek to resume position once we have duration
                    if !hasResumedPosition && resumePosition > 0 && resumePosition < CMTimeGetSeconds(dur) {
                        hasResumedPosition = true
                        seek(to: resumePosition)
                        currentTime = resumePosition
                    }
                }
            }
            .store(in: &cancellables)

        // Periodic time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if !isScrubbing {
                currentTime = CMTimeGetSeconds(time)
                onProgressUpdate?(currentTime, duration)
            }
        }

        // Observe playback end for autoplay-next support
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak playerItem] _ in
                guard playerItem != nil else { return }
                onPlaybackFinished?()
            }
            .store(in: &cancellables)

        player?.play()
        scheduleHideControls()
    }

    private func cleanup() {
        #if os(iOS)
        if isPiPActive {
            pipController?.stopPictureInPicture()
            // isPiPActive will be set false by the delegate
        }
        pipController?.delegate = nil
        pipController = nil
        pipDelegate = nil
        isPiPActive = false
        #endif
        hideControlsTask?.cancel()
        hideVolumeIndicatorTask?.cancel()
        skipHideTask?.cancel()
        controlsHideTask?.cancel()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            orientLog.warning("Failed to deactivate audio session: \(error.localizedDescription)")
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
        if isPlaying {
            player?.pause()
            hideControlsTask?.cancel() // Keep controls visible when paused
        } else {
            player?.play()
            scheduleHideControls() // Auto-hide when playing
        }
    }

    /// Seek to a time position.
    /// - tight: frame-accurate seek (zero tolerance) — used for scrub-end and chapter seeks.
    /// - fast (default): seeks to nearest keyframe within ±2s — used for skip buttons.
    ///   With 2s HLS segments keyframes are at most 2s away, so this lands accurately
    ///   without the multi-segment overshoot that .positiveInfinity caused.
    private func seek(to time: Double, tight: Bool = false) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        if tight {
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tol = CMTime(seconds: 2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            player?.seek(to: cmTime, toleranceBefore: tol, toleranceAfter: tol)
        }
    }

    private func skipForward() {
        let newTime = min(duration, currentTime + skipSeconds)
        seek(to: newTime)  // fast seek (positiveInfinity tolerance)
        currentTime = newTime
        showSkipAnimation(direction: .forward)
        if isPlaying { scheduleHideControls() }
    }

    private func skipBackward() {
        let newTime = max(0, currentTime - skipSeconds)
        seek(to: newTime)  // fast seek (positiveInfinity tolerance)
        currentTime = newTime
        showSkipAnimation(direction: .backward)
        if isPlaying { scheduleHideControls() }
    }

    private func showSkipAnimation(direction: SkipDirection) {
        withAnimation(.easeOut(duration: 0.15)) {
            showSkipIndicator = direction
        }

        skipHideTask?.cancel()
        skipHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                showSkipIndicator = nil
            }
        }
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    private func scheduleHideControls() {
        // TASK-211: Keep controls always visible when VoiceOver is running to prevent dead zones
        #if os(iOS)
        guard !UIAccessibility.isVoiceOverRunning else { return }
        #endif
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 seconds
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }

    private func scheduleHideVolumeIndicator() {
        hideVolumeIndicatorTask?.cancel()
        hideVolumeIndicatorTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) {
                    showVolumeIndicator = false
                }
            }
        }
    }


    // MARK: - Volume Control

    private func setupVolumeObserver() {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)
        volumeLevel = audioSession.outputVolume

        // Show the volume HUD when hardware volume buttons are pressed.
        // dropFirst() skips the initial emission so the HUD doesn't appear on launch.
        audioSession.publisher(for: \.outputVolume)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { newVolume in
                volumeLevel = newVolume
                showVolumeIndicator = true
                scheduleHideVolumeIndicator()
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
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
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
        onLayerReady?(view.playerLayer)
        #endif
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
            #if os(iOS)
            onLayerReady?(uiView.playerLayer)
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
        picker.activeTintColor = UIColor(DSReelBrandColor.background)
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

    @ViewBuilder
    private var subtitleSection: some View {
        if let group = subtitleGroup {
            let noneSelected = currentSelection?.selectedMediaOption(in: group) == nil
            Button {
                player.currentItem?.select(nil, in: group)
                currentSelection = player.currentItem?.currentMediaSelection
            } label: {
                trackRow(name: "None", isSelected: noneSelected)
            }
            .buttonStyle(.plain)

            ForEach(group.options, id: \.self) { option in
                let isSelected = currentSelection?.selectedMediaOption(in: group) == option
                Button {
                    player.currentItem?.select(option, in: group)
                    currentSelection = player.currentItem?.currentMediaSelection
                } label: {
                    trackRow(name: option.displayName, isSelected: isSelected)
                }
                .buttonStyle(.plain)
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

    private func trackRow(name: String, isSelected: Bool) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "checkmark")
                .foregroundStyle(Color.accentColor)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(!isSelected)
                .accessibilityLabel("Selected")
        }
        .contentShape(Rectangle())
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
                                        .foregroundStyle(Color.accentColor)
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
