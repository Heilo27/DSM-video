//
//  DS_Video_cloneApp.swift
//  DS Video clone
//
//  Created by Ryan on 1/7/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - App Delegate (orientation lock)

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Portrait for all navigation UI; landscape for the video player.
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    /// Update the orientation mask and let UIKit rotate naturally on its next
    /// layout pass. Never call requestGeometryUpdate here — that competes with
    /// ongoing SwiftUI animations and freezes touch delivery.
    static func setOrientation(_ mask: UIInterfaceOrientationMask) {
        orientationLock = mask
        // Tell UIKit the supported orientations changed so it re-queries
        // application(_:supportedInterfaceOrientationsFor:) on its own schedule.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
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
