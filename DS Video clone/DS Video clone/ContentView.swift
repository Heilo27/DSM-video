//
//  ContentView.swift
//  DS Video clone
//
//  Created by Ryan on 1/7/26.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if appState.sessionToken == nil {
                LoginView()
            } else {
                #if os(tvOS)
                  TVMainView()
                #else
                  MainView(layout: horizontalSizeClass == .regular ? .split : .tabs)
                #endif
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
