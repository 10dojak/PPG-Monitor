//
//  SettingsView.swift
//  PPGMonitor
//
//  Lets the user switch between mock replay data and real BLE hardware at
//  runtime — no source-code edit + rebuild required to test against real
//  hardware vs. demo without it. ppg_monitor.html has a "Settings" button
//  too, though it just reopens the same connect modal there; this is the
//  more useful native equivalent for an app that supports two data sources.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var bt: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Use Mock Data", isOn: Binding(
                        get: { bt.isUsingMockData },
                        set: { bt.switchDataSource(useMock: $0) }
                    ))
                } footer: {
                    Text("Mock data replays a captured PPG session — useful for testing with no hardware. Turn this off to scan for and connect to a real PPG_DK_2026A device over Bluetooth.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
