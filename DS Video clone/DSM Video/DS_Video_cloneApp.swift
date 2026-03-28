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
    /// Portrait for all navigation UI; landscape for the video player.
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        let lock = AppDelegate.orientationLock
        orientLog.debug("UIKit queried supported orientations → \(lock == .landscape ? "landscape" : "portrait", privacy: .public)")
        return lock
    }

    /// Update the orientation mask and signal UIKit to re-query on its next layout pass.
    /// - Never call requestGeometryUpdate — it competes with SwiftUI animations and
    ///   causes gesture-gate timeouts and touch freezes.
    /// - Use scene.windows.first instead of deprecated keyWindow — keyWindow returns
    ///   nil on iOS 15+ and silently drops the signal, leaving a stale lock that
    ///   blocks all touches on navigation views after player dismissal.
    static func setOrientation(_ mask: UIInterfaceOrientationMask) {
        let prev = orientationLock
        orientationLock = mask
        let label = mask == .landscape ? "landscape" : "portrait"
        let prevLabel = prev == .landscape ? "landscape" : "portrait"
        orientLog.info("setOrientation: \(prevLabel, privacy: .public) → \(label, privacy: .public)")

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else {
            orientLog.error("setOrientation: no rootViewController found — signal dropped, stale lock will persist!")
            return
        }
        orientLog.debug("setOrientation: signaling \(type(of: rootVC), privacy: .public)")
        rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}
