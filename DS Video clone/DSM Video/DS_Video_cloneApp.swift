//
//  DS_Video_cloneApp.swift
//  DS Video clone
//
//  Created by Ryan on 1/7/26.
//

import SwiftUI
import os.log
#if canImport(UIKit)
import UIKit
#endif

// Filter by subsystem "com.dsm.orientation" in Console.app to trace all lock changes
private let orientLog = Logger(subsystem: "com.dsm.orientation", category: "lock")

// MARK: - App Delegate (orientation lock)

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Per-scene orientation locks. Portrait for all navigation UI; landscape for the scene
    /// that hosts the video player. Per scene, not global: with multiple scenes enabled a
    /// global mask leaked landscape into every other window (TASK-756).
    static var locks = OrientationLockRegistry()

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        let id = window?.windowScene.map(AppDelegate.sceneID)
        let lock = AppDelegate.locks.mask(for: id)
        orientLog.debug("UIKit queried supported orientations → \(lock == .landscape ? "landscape" : "portrait", privacy: .public)")
        return lock
    }

    /// Stable identity for a scene across the lock registry and the player.
    static func sceneID(_ scene: UIWindowScene) -> String { scene.session.persistentIdentifier }

    /// The scene to signal when the caller does not know which one hosts the player: the
    /// foreground one, else any window scene.
    static func fallbackScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    // FIX-7: Reconnect completed background downloads to DownloadManager so they finalize.
    // Without this, downloads completing while the app is in the background are never saved.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == "com.heiloprojects.dsreel.downloads" else {
            completionHandler()
            return
        }
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }

    /// Update one scene's orientation mask and signal UIKit to re-query on its next layout pass.
    /// - Parameter sceneID: the scene hosting the player. nil falls back to the foreground scene.
    /// - Never call requestGeometryUpdate — it competes with SwiftUI animations and
    ///   causes gesture-gate timeouts and touch freezes.
    /// - Use scene.windows.first instead of deprecated keyWindow — keyWindow returns
    ///   nil on iOS 15+ and silently drops the signal, leaving a stale lock that
    ///   blocks all touches on navigation views after player dismissal.
    static func setOrientation(_ mask: UIInterfaceOrientationMask, sceneID: String?) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let target = sceneID.flatMap { id in scenes.first(where: { AppDelegate.sceneID($0) == id }) }
            ?? fallbackScene()
        let label = mask == .landscape ? "landscape" : "portrait"

        guard let scene = target else {
            orientLog.error("setOrientation(\(label, privacy: .public)): no window scene — signal dropped")
            return
        }
        let id = AppDelegate.sceneID(scene)
        locks.prune(keeping: Set(scenes.map(AppDelegate.sceneID)))
        let wasLocked = locks.isLocked(id)
        locks.set(mask, for: id)
        orientLog.info("setOrientation: scene \(id, privacy: .public) \(wasLocked ? "landscape" : "portrait", privacy: .public) → \(label, privacy: .public)")

        guard let rootVC = scene.windows.first?.rootViewController else {
            orientLog.error("setOrientation: no rootViewController in scene — signal dropped, stale lock will persist!")
            return
        }
        orientLog.debug("setOrientation: signaling \(type(of: rootVC), privacy: .public)")
        rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
        // NOTE: do NOT call scene.requestGeometryUpdate here — it competes with the
        // fullScreenCover dismiss animation and causes "System gesture gate timed out"
        // (the touch-freeze the codebase has always warned about). Reverted 2026-06-14.
    }

    /// True while the given scene is held in landscape.
    static func isLandscapeLocked(sceneID: String?) -> Bool {
        guard let id = sceneID ?? fallbackScene().map(AppDelegate.sceneID) else { return false }
        return locks.isLocked(id)
    }
}
#endif

// MARK: - App

@main
struct DS_Video_cloneApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    // Persisted theme selection. Default = Classic (byte-identical to the prior look).
    @AppStorage("dsReel.theme") private var themeIDRaw: String = ThemeID.classic.rawValue

    /// Resolve the persisted raw value to a concrete Theme, defaulting to Classic.
    var activeTheme: Theme {
        ThemeID.theme(forRaw: themeIDRaw)
    }

    init() {
        // TASK-739: register subtitle-appearance defaults before any player reads them.
        SubtitleStyle.registerDefaults()
        // Seed the active theme before any view body reads a token accessor.
        let raw = UserDefaults.standard.string(forKey: "dsReel.theme") ?? ThemeID.classic.rawValue
        MainActor.assumeIsolated { ThemeHolder.shared.current = ThemeID.theme(forRaw: raw) }
    }
    // Track the prior phase so we only refresh on a real background→active return,
    // not on initial launch (RootView's own .task already does the cold load).
    @State private var didBecomeActiveOnce = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(\.theme, activeTheme)
                .task {
                    // Let resumed downloads fetch a LIVE token. The token captured when a
                    // download started is deliberately not persisted (it's a credential),
                    // so after a relaunch every resume attempted an unauthenticated
                    // request and 401'd.
                    // appState is owned by the scene for the app's lifetime, and
                    // DownloadManager is a singleton — capturing it strongly here is
                    // correct and matches the lifetimes involved.
                    let state = appState
                    // App Intents run in this process with no SwiftUI environment, so Siri
                    // has no other way to reach the signed-in state. Registered here
                    // because this is where the scene's state becomes available.
                    AppStateHolder.register(state)
                    DownloadManager.shared.tokenProvider = { state.sessionToken }
                    DownloadManager.shared.usesTunnelCookieProvider = { state.api.usesTunnelCookie }
                    // A download's URL is session-scoped (/playback/{id}/stream), so the
                    // session must be released only when the transfer ends — and a restart
                    // must open a fresh one rather than reuse a dead URL.
                    DownloadManager.shared.releaseSessionProvider = { sessionID in
                        Task { await state.api.stopPlayback(sessionID: sessionID) }
                    }
                    DownloadManager.shared.urlResolver = { itemID in
                        // Through the current address, so a restart never resumes on a host
                        // the device just left (TASK-1009).
                        guard let info = try? await state.playbackThroughCurrentAddress(id: itemID).info,
                              let url = info.streamUrl else { return nil }
                        return (url: url, sessionID: info.resolvedSessionID)
                    }
                    // Downloads that finished in a background relaunch, before these providers
                    // existed, left sessions to release and posters to fetch (TASK-994).
                    DownloadManager.shared.flushDeferredWork()
                    // A local store that could not open is named at launch (TASK-1012).
                    await state.checkLocalStoreHealth()
                }
                .onChange(of: themeIDRaw) { _, _ in
                    ThemeHolder.shared.current = activeTheme
                }
                .onOpenURL { url in
                    // Handle dsvideo://item/{id} deep links from the Top Shelf extension
                    guard url.scheme == "dsvideo",
                          url.host == "item",
                          !url.pathComponents.dropFirst().isEmpty else { return }
                    let itemID = url.pathComponents.dropFirst().joined(separator: "/")
                    appState.pendingDeepLinkItemID = itemID
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // TASK-738: refresh Continue Watching when returning to the foreground so it
            // reflects playback from another device. Skip the very first activation —
            // the initial cold load handles that.
            // FR-260: tvOS asks for the profile again after a long absence. Background time
            // is recorded here; the gate decides (iOS ignores it).
            if newPhase == .background {
                appState.noteEnteredBackground()
            }
            guard newPhase == .active else { return }
            appState.noteReturnedToForeground()
            if didBecomeActiveOnce {
                // TASK-787: single foreground owner — revalidate connection (LAN→WAN
                // cascade if the stored address went stale while backgrounded) then
                // refresh once. Replaces the old split where LibrariesView ALSO ran
                // revalidate+homeLoad on the same .active event.
                Task { await appState.foregroundReconnectAndRefresh() }
            } else {
                didBecomeActiveOnce = true
            }
        }
    }
}
