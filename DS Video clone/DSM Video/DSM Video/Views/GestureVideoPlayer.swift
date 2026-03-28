import AVKit
import Combine
import SwiftUI
import os.log

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
    var onDismiss: (() -> Void)?
    var onProgressUpdate: ((Double, Double) -> Void)?

    @State private var player: AVPlayer?
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
    @State private var timeObserver: Any?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var hasResumedPosition: Bool = false
    @State private var showCaptionsPicker: Bool = false

    private let skipSeconds: Double = 30

    enum SkipDirection {
        case backward, forward
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
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    controlsInteractive = false
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Play/Pause") { togglePlayPause() }
        .accessibilityAction(named: "Skip forward 30 seconds") { skipForward() }
        .accessibilityAction(named: "Skip backward 30 seconds") { skipBackward() }
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
                    SubtitleAudioPickerView(player: player)
                }
            }
        #elseif os(macOS)
        return base
            .sheet(isPresented: $showCaptionsPicker) {
                if let player {
                    SubtitleAudioPickerView(player: player)
                }
            }
        #else
        return base
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
                    VideoPlayerLayer(player: player, gravity: .resizeAspectFill)
                        .ignoresSafeArea()
                } else {
                    VideoPlayerLayer(player: player, gravity: .resizeAspect)
                }
            }

            // Gesture overlay
            gestureOverlay(geometry: geometry)

            // Controls overlay
            controlsOverlay(geometry: geometry)
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(controlsInteractive)

            // Center play/pause button — positioned midway between screen top and progress bar
            #if os(iOS)
            centerPlayPauseButton(geometry: geometry)
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(controlsInteractive)
            #endif

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

    // MARK: - Gesture Overlay

    @ViewBuilder
    private func gestureOverlay(geometry: GeometryProxy) -> some View {
        let width = geometry.size.width

        Color.clear
            .contentShape(Rectangle())
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


    // MARK: - Center Play/Pause Button

    #if os(iOS)
    @ViewBuilder
    private func centerPlayPauseButton(geometry: GeometryProxy) -> some View {
        // Bottom controls height: 40pt bottom pad + ~20pt progress bar = ~60pt
        // Top bar height: ~80pt
        // Center of the open space between them:
        let bottomControlsHeight: CGFloat = 60
        let topBarHeight: CGFloat = 80
        let openSpaceCenter = topBarHeight + (geometry.size.height - topBarHeight - bottomControlsHeight) / 2

        HStack(spacing: 48) {
            // Skip backward
            Button {
                skipBackward()
                scheduleHideControls()
            } label: {
                Image(systemName: "gobackward.30")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip backward 30 seconds")

            // Play/pause
            Button {
                togglePlayPause()
                scheduleHideControls()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 88, height: 88)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            // Skip forward
            Button {
                skipForward()
                scheduleHideControls()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward 30 seconds")
        }
        .position(x: geometry.size.width / 2, y: openSpaceCenter)
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
                        .padding(10)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Close")

                Spacer()

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                // Right actions: AirPlay + fill mode + speed selector
                HStack(spacing: 16) {
                    // AirPlay button (iOS only)
                    #if os(iOS)
                    AirPlayButton()
                        .frame(width: 44, height: 44)
                    #endif

                    // Captions / subtitle picker (iOS/macOS only)
                    #if !os(tvOS)
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
            .padding(.top, 8)
            .padding(.bottom, 16)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            // Bottom controls — progress bar only
            HStack(spacing: 12) {
                Text(formatTime(isScrubbing ? scrubTime : currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 50, alignment: .leading)

                #if os(iOS)
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : currentTime },
                        set: { newValue in
                            scrubTime = newValue
                            if !isScrubbing {
                                seek(to: newValue)
                            }
                        }
                    ),
                    in: 0...max(duration, 1)
                ) { editing in
                    isScrubbing = editing
                    if !editing {
                        seek(to: scrubTime, tight: true)
                    }
                }
                .tint(.white)
                .scaleEffect(y: 1.3)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")
                #else
                // tvOS: progress bar only (no interactive Slider)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                        Capsule().fill(Color.white)
                            .frame(width: geo.size.width * (duration > 0 ? (isScrubbing ? scrubTime : currentTime) / max(duration, 1) : 0), height: 4)
                    }
                }
                .frame(height: 4)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")
                #endif

                Text("-\(formatTime(duration - (isScrubbing ? scrubTime : currentTime)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 50, maxWidth: 70, alignment: .trailing)
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
    }

    private var volumeIndicatorOverlay: some View {
        HStack(spacing: 12) {
            Image(systemName: volumeLevel > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.title2)
                .accessibilityLabel(volumeLevel > 0 ? "Volume" : "Muted")

            ProgressView(value: Double(volumeLevel))
                .tint(.white)
                .frame(width: 100)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
            Image(systemName: direction == .backward ? "gobackward.30" : "goforward.30")
                .font(.title)
                .accessibilityLabel(direction == .backward ? "Skip backward" : "Skip forward")
            Text("\(Int(skipSeconds)) sec")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: Circle())
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
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // Observe playback status
        player?.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { status in
                isPlaying = status == .playing
                isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
            .store(in: &cancellables)

        // Observe player item status to surface errors (e.g. 404 on HLS playlist,
        // unsupported codec, network failure)
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status == .failed {
                    let msg = playerItem.error?.localizedDescription ?? "Unable to play this video."
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

        player?.play()
        scheduleHideControls()
    }

    private func cleanup() {
        hideControlsTask?.cancel()
        hideVolumeIndicatorTask?.cancel()
        skipHideTask?.cancel()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[GestureVideoPlayer] Failed to deactivate audio session: \(error)")
        }
        #endif
        player?.pause()
        player = nil
        cancellables.removeAll()
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

    private func seek(to time: Double, tight: Bool = false) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        if tight {
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    private func skipForward() {
        let newTime = min(duration, currentTime + skipSeconds)
        seek(to: newTime)
        currentTime = newTime
        showSkipAnimation(direction: .forward)
        if isPlaying { scheduleHideControls() }
    }

    private func skipBackward() {
        let newTime = max(0, currentTime - skipSeconds)
        seek(to: newTime)
        currentTime = newTime
        showSkipAnimation(direction: .backward)
        if isPlaying { scheduleHideControls() }
    }

    private func showSkipAnimation(direction: SkipDirection) {
        withAnimation(.easeOut(duration: 0.15)) {
            showSkipIndicator = direction
        }

        skipHideTask?.cancel()
        skipHideTask = Task {
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
}

// MARK: - Video Player Layer

/// A platform-specific view that wraps AVPlayerLayer for better performance
#if os(iOS) || os(tvOS)
struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
        uiView.playerLayer.videoGravity = gravity
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

#if !os(tvOS)
/// Half-sheet picker for subtitle and audio track selection.
private struct SubtitleAudioPickerView: View {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var subtitleGroup: AVMediaSelectionGroup? = nil
    @State private var audioGroup: AVMediaSelectionGroup? = nil
    @State private var isLoading: Bool = true
    @State private var currentSelection: AVMediaSelection? = nil

    var body: some View {
        NavigationStack {
            contentView
                .navigationTitle("Subtitles & Audio")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
        .task {
            // Use async loading — sync mediaSelectionGroup may return nil for HLS
            // until the asset's tracks are fully loaded.
            async let subtitle = player.currentItem?.asset.loadMediaSelectionGroup(for: .legible)
            async let audio = player.currentItem?.asset.loadMediaSelectionGroup(for: .audible)
            subtitleGroup = try? await subtitle
            audioGroup = try? await audio
            currentSelection = player.currentItem?.currentMediaSelection
            isLoading = false
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
                }
                Section("Audio") {
                    audioSection
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

    private func trackRow(name: String, isSelected: Bool) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "checkmark")
                .foregroundStyle(Color.accentColor)
                .opacity(isSelected ? 1 : 0)
                .accessibilityLabel(isSelected ? "Selected" : "")
        }
        .contentShape(Rectangle())
    }
}
#endif

// MARK: - Preview

#Preview {
    GestureVideoPlayer(
        url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
        title: "Big Buck Bunny"
    )
}
