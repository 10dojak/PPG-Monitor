//
//  ContentView.swift
//  PPG Monitor
//

import SwiftUI

// MARK: - Tabs (Waveforms / All 24 Channels / Acceleration)

enum MainTab: String, CaseIterable {
    case waveform = "Waveforms"
    case heatmap  = "All 24 Channels"
    case accel    = "Acceleration"
}

struct PillTabBar: View {
    @Binding var selected: MainTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Text(tab.rawValue)
                    .font(.subheadline.weight(selected == tab ? .semibold : .regular))
                    .foregroundColor(selected == tab ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selected == tab ? Color.white : Color.clear)
                    .cornerRadius(9)
                    .shadow(color: selected == tab ? .black.opacity(0.1) : .clear, radius: 3, y: 1)
                    .onTapGesture { selected = tab }
            }
        }
        .padding(4)
        .background(Color(.systemGray5))
        .cornerRadius(12)
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var bt = BluetoothManager()
    @StateObject private var sessionController = SessionController()
    @State private var selectedTab: MainTab = .waveform
    @Environment(\.scenePhase) private var scenePhase
    @State private var showExitDuringRecordingWarning = false
    @State private var showSettings = false
    @State private var showMetricCards = true

    // Background color matches ppg_monitor.html's body { background: #dce8f5 }
    private let pageBackground = Color(hex: "#dce8f5")

    var body: some View {
        Group {
            if sessionController.state == .participantEntry {
                ParticipantEntryView(sessionController: sessionController)
            } else {
                recordingScreen
            }
        }
        .onAppear {
            bt.onParsedSample = { [weak sessionController] sample in
                sessionController?.recordSample(sample)
            }
        }
        // iOS gives no way to actually block backgrounding/navigation, so
        // this is the honest version of checklist §6's "warns the user
        // before exiting an active recording" — .inactive fires right as
        // the user starts to leave (app switcher, incoming call, etc.),
        // before the app is actually hidden.
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active, sessionController.state == .recording {
                showExitDuringRecordingWarning = true
            }
        }
        .alert("Recording in Progress", isPresented: $showExitDuringRecordingWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A recording is still active. Keep PPG Monitor open and the device connected for the most reliable capture.")
        }
    }

    private var recordingScreen: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showMetricCards.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(showMetricCards ? "Hide Metrics" : "Show Metrics")
                                Image(systemName: showMetricCards ? "chevron.up" : "chevron.down")
                                    .accessibilityHidden(true)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                        }

                        if showMetricCards {
                            MetricCardsView(bt: bt)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        PillTabBar(selected: $selectedTab)

                        switch selectedTab {
                        case .waveform: WaveformChartView(bt: bt)
                        case .heatmap:  HeatmapView(bt: bt)
                        case .accel:    AccelView(bt: bt)
                        }
                    }
                    .padding()
                }
                .background(pageBackground)
                RecordingControlsView(sessionController: sessionController, bt: bt)
            }
            .navigationTitle("PPG Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(bt.isConnected ? Color.green : Color.orange)
                                .frame(width: 9, height: 9)
                            Text(bt.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button {
                            if bt.isConnected {
                                bt.disconnect()
                            } else {
                                bt.reconnect()
                            }
                        } label: {
                            Text(bt.isConnected ? "Disconnect" : "Reconnect")
                                .font(.caption)
                        }
                        signalQualityBadge
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Text(sessionController.participantID)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Switch Participant") {
                            sessionController.changeParticipant()
                        }
                        .font(.caption)
                        .disabled(sessionController.state == .recording)

                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showSettings) {
            SettingsView(bt: bt)
        }
    }

    private var signalQualityBadge: some View {
        let quality = bt.signalQuality
        let color: Color = {
            switch quality {
            case .none: return .secondary
            case .poor: return .red
            case .fair: return .orange
            case .good: return .green
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
                .font(.caption2)
            Text(quality.rawValue)
                .font(.caption2.weight(.semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }
}
