//
//  KeyboardBlockerApp.swift
//  禁用自带键盘
//
//  Created by ArtiSheng on 2026/3/19.
//

import SwiftUI

struct KeyboardBlockerApp: App {
    @StateObject private var keyboardManager = KeyboardManager()
    @StateObject private var daemonInstaller = DaemonInstaller()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(keyboardManager)
                .environmentObject(daemonInstaller)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 560)
    }
}
