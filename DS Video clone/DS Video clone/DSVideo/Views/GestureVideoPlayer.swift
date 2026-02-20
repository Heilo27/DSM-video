import AVKit
import Combine
import SwiftUI

#if os(iOS) || os(tvOS)
import MediaPlayer
#endif

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
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var playbackRate: Float = 1.0
    @State private var isBuffering: Bool = true

    // Gesture states
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @State private var scrubStartTime: Double = 0
    @State private var showScrubPreview: Bool = false

    @State private var isAdjustingVolume: Bool = false
    @State private var volumeLevel: Float = 0.5
    @State private var showVolumeIndicator: Bool = false

    #if os(iOS)
    @State private var isAdjustingBrightness: Bool = false
    @State private var brightnessLevel: CGFloat = 0.5
    @State private var showBrightnessIndicator: Bool = false
    #endif

    @State private var showSkipIndicator: SkipDirection? = nil

    @State private var hideControlsTask: Task<Void, Never>?
    @State private var hideVolumeIndicatorTask: Task<Void, Never>?
    #if os(iOS)
    @State private var hideBrightnessIndicatorTask: Task<Void, Never>?
    #endif
    @State private var timeObserver: Any?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var hasResumedPosition: Bool = false

    private let skipSeconds: Double = 10

    enum SkipDirection {
        case backward, forward
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // Video layer
                if let player {
                    VideoPlayerLayer(player: player)
                }

                // Gesture overlay
                gestureOverlay(geometry: geometry)

                // Controls overlay
                controlsOverlay(geometry: geometry)
                    .opacity(showControls ? 1 : 0)
                    .allowsHitTesting(showControls)

                // Scrub preview
                if showScrubPreview {
                    scrubPreviewOverlay
                }

                // Volume indicator
                if showVolumeIndicator {
                    volumeIndicatorOverlay
                }

                #if os(iOS)
                // Brightness indicator
                if showBrightnessIndicator {
                    brightnessIndicatorOverlay
                }
                #endif

                // Skip indicator
                if let direction = showSkipIndicator {
                    skipIndicatorOverlay(direction: direction)
                }

                // Buffering indicator
                if isBuffering && !showScrubPreview {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }
            }
            // Accessibility actions for gesture-based controls
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Skip forward 10 seconds") { skipForward() }
            .accessibilityAction(named: "Skip backward 10 seconds") { skipBackward() }
            #if os(iOS)
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
            #endif
        }
        .onAppear {
            setupPlayer()
            setupVolumeObserver()
            #if os(iOS)
            lockLandscape()
            #endif
        }
        .onDisappear {
            cleanup()
            #if os(iOS)
            unlockOrientation()
            #endif
        }
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
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
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showControls.toggle()
                        }
                        if showControls {
                            scheduleHideControls()
                        }
                    }
            )
            .overlay {
                // Double-tap zones
                HStack(spacing: 0) {
                    // Left zone - skip backward
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            skipBackward()
                        }
                        .frame(width: width * 0.3)

                    // Middle zone - no double tap action
                    Color.clear
                        .frame(width: width * 0.4)

                    // Right zone - skip forward
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            skipForward()
                        }
                        .frame(width: width * 0.3)
                }
            }
    }

    // MARK: - Controls Overlay

    @ViewBuilder
    private func controlsOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            // Top bar
            HStack {
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")

                Spacer()

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

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
                    Text(playbackRate == 1.0 ? "1x" : "\(playbackRate, specifier: "%.2g")x")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityLabel("Playback speed, \(playbackRate == 1.0 ? "normal" : "\(playbackRate, specifier: "%.2g") times")")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            // Center play/pause button
            Button {
                togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Spacer()

            // Bottom controls
            VStack(spacing: 12) {
                // Progress bar
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
                            seek(to: scrubTime)
                        }
                    }
                    .tint(.white)
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
                        .frame(width: 50, alignment: .trailing)
                }

                // Skip buttons
                HStack(spacing: 40) {
                    Button {
                        skipBackward()
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip backward 10 seconds")

                    Button {
                        togglePlayPause()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")

                    Button {
                        skipForward()
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip forward 10 seconds")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
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
                .font(.system(size: 48, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)

            let delta = scrubTime - scrubStartTime
            Text(delta >= 0 ? "+\(formatTime(delta))" : "-\(formatTime(abs(delta)))")
                .font(.title3.monospacedDigit())
                .foregroundStyle(delta >= 0 ? .green : .red)
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

    #if os(iOS)
    private var brightnessIndicatorOverlay: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .accessibilityLabel("Brightness")

            ProgressView(value: brightnessLevel)
                .tint(.white)
                .frame(width: 100)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    #endif

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
            Image(systemName: direction == .backward ? "gobackward.10" : "goforward.10")
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
        let location = value.startLocation
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
            // Full width = 60 seconds of scrubbing
            let secondsPerPoint = 60.0 / width
            let timeDelta = translation.width * secondsPerPoint
            scrubTime = max(0, min(duration, scrubStartTime + timeDelta))

            hideControlsTask?.cancel()
        } else {
            #if os(iOS)
            // Vertical gesture - left side = brightness, right side = volume
            let isLeftSide = location.x < width / 2

            if isLeftSide {
                // Brightness adjustment
                if !isAdjustingBrightness {
                    isAdjustingBrightness = true
                    brightnessLevel = currentScreen?.brightness ?? brightnessLevel
                    showBrightnessIndicator = true
                }
                // Reset the auto-hide timer on each drag update
                scheduleHideBrightnessIndicator()

                let delta = -translation.height / (height * 1.5)
                brightnessLevel = max(0, min(1, brightnessLevel + delta))
                currentScreen?.brightness = brightnessLevel
            } else {
                // Volume adjustment
                if !isAdjustingVolume {
                    isAdjustingVolume = true
                    showVolumeIndicator = true
                }
                // Reset the auto-hide timer on each drag update
                scheduleHideVolumeIndicator()

                let delta = Float(-translation.height / (height * 1.5))
                volumeLevel = max(0, min(1, volumeLevel + delta))
                setSystemVolume(volumeLevel)
            }
            #endif

            hideControlsTask?.cancel()
        }
    }

    private func handleDragEnd(value: DragGesture.Value, geometry: GeometryProxy) {
        if isScrubbing {
            seek(to: scrubTime)
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

        #if os(iOS)
        // Always reset brightness adjustment state and schedule hide
        if isAdjustingBrightness {
            isAdjustingBrightness = false
        }
        // Schedule hide with short delay for smooth UX
        scheduleHideBrightnessIndicator()
        #endif

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
        #if os(iOS)
        hideBrightnessIndicatorTask?.cancel()
        #endif
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
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

    private func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func skipForward() {
        let newTime = min(duration, currentTime + skipSeconds)
        seek(to: newTime)
        currentTime = newTime
        showSkipAnimation(direction: .forward)
        scheduleHideControls()
    }

    private func skipBackward() {
        let newTime = max(0, currentTime - skipSeconds)
        seek(to: newTime)
        currentTime = newTime
        showSkipAnimation(direction: .backward)
        scheduleHideControls()
    }

    private func showSkipAnimation(direction: SkipDirection) {
        withAnimation(.easeOut(duration: 0.15)) {
            showSkipIndicator = direction
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
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
        hideVolumeIndicatorTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) {
                    showVolumeIndicator = false
                }
            }
        }
    }

    #if os(iOS)
    private func scheduleHideBrightnessIndicator() {
        hideBrightnessIndicatorTask?.cancel()
        hideBrightnessIndicatorTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) {
                    showBrightnessIndicator = false
                }
            }
        }
    }
    #endif

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
    /// Locks orientation to landscape and rotates the device immediately.
    private func lockLandscape() {
        AppDelegate.orientationLock = .landscape
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        }
    }

    /// Restores all-but-upside-down orientation support and snaps back to portrait.
    private func unlockOrientation() {
        AppDelegate.orientationLock = .allButUpsideDown
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
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

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
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
            set {
                playerLayer.player = newValue
                playerLayer.videoGravity = .resizeAspect
            }
        }
    }
}
#else
struct VideoPlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? PlayerNSView {
            view.player = player
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

// MARK: - Preview

#Preview {
    GestureVideoPlayer(
        url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
        title: "Big Buck Bunny"
    )
}
