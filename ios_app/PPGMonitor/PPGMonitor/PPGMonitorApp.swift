//
//  PPGMonitorApp.swift
//  PPGMonitor
//
//  Created by Phoebe Lo on 8/18/26.
//

import SwiftUI

@main
struct PPGMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // UI is a fixed-palette port of ppg_monitor.html (#dce8f5
                // background, white cards, etc.) — never designed with dark
                // mode in mind. Without this, views with no explicit
                // background (e.g. ParticipantEntryView) fall through to
                // the system's dark default, while views with hardcoded
                // white/light colors don't — a jarring half-light/half-dark
                // mix depending on the device's Appearance setting. Locking
                // to light mode keeps the intended design consistent
                // everywhere, regardless of the device's system setting.
                .preferredColorScheme(.light)
        }
    }
}
