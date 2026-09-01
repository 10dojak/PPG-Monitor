//
//  RawStreamDebugView.swift
//  PPGMonitor
//
//  On-device diagnostics for real-hardware bring-up: shows the raw text
//  coming off the BLE stream verbatim, the running parse counters, and any
//  lines parseLine rejected. Lets a parse-error run be understood on the
//  iPad itself — and the capture exported and replayed through the mock
//  source at a desk (drop it in as Mock/sample_session.txt).
//

import SwiftUI

struct RawStreamDebugView: View {
    @ObservedObject var bt: BluetoothManager

    // Polled copies, refreshed on a local timer so the raw stream (100+
    // lines/sec) never drives SwiftUI invalidations from BluetoothManager.
    @State private var lines: [String] = []
    @State private var failures: [String] = []

    // Written on demand (button below), not every refresh — serialising tens
    // of thousands of lines to disk 4×/sec would be absurd.
    @State private var exportURL: URL?

    // @State, not a plain let: a Timer.publish on a View struct is otherwise
    // recreated (and never fires) every time the parent redraws.
    @State private var refresh = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var totalParsed: Int { bt.cntU10 + bt.cntU2 }
    private var errorRateText: String {
        let denom = totalParsed + bt.cntErr
        guard denom > 0 else { return "—" }
        return String(format: "%.1f%%", 100 * Double(bt.cntErr) / Double(denom))
    }

    var body: some View {
        List {
            Section("Connection") {
                labeled("Status", bt.statusMessage)
                labeled("Source", bt.isUsingMockData ? "Mock replay" : "Real BLE")
                labeled("Signal quality", bt.signalQuality.rawValue)
            }

            Section("Parse counters") {
                labeled("U10 samples", "\(bt.cntU10)")
                labeled("U2 samples", "\(bt.cntU2)")
                labeled("Parse errors", "\(bt.cntErr)")
                labeled("Error rate", errorRateText)
                labeled("Samples/sec", "\(bt.samplesPerSecond)")
            }

            if !failures.isEmpty {
                Section("First rejected lines (verbatim)") {
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? "⟨empty⟩" : line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Raw stream — most recent") {
                if lines.isEmpty {
                    Text("Nothing received yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Button {
                    exportURL = bt.exportRawCapture()
                } label: {
                    Label("Prepare capture file", systemImage: "doc.badge.plus")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("“Prepare” snapshots every line received so far this session to a file. Share it out, then drop it into Mock/sample_session.txt to replay this exact stream through the mock source.")
            }
        }
        .navigationTitle("Raw Data Stream")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(refresh) { _ in
            lines = bt.rawStreamSnapshot(last: 200)
            failures = bt.parseFailureSamples
        }
        .onAppear {
            lines = bt.rawStreamSnapshot(last: 200)
            failures = bt.parseFailureSamples
        }
    }

    private func labeled(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
        .font(.subheadline)
    }
}
