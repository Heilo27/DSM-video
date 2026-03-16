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
    /// Set this before calling requestGeometryUpdate to lock orientation.
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
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
