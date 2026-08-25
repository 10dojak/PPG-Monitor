//
//  RecordingControlsView.swift
//  PPGMonitor
//
//  "Session Recorder" bar, ported from ppg_monitor.html's .recorder-bar —
//  same status text logic (packet count while recording / last-saved
//  summary / idle), same Start/Stop semantics, and Download CSV/Download
//  JSON buttons — a ShareLink is the iOS-native stand-in for the HTML's
//  browser download, per PLANNING.md's "Export = share sheet" call, but
//  kept as two separate buttons to match the HTML layout exactly.
//

import SwiftUI

struct RecordingControlsView: View {
    @ObservedObject var sessionController: SessionController
    @ObservedObject var bt: BluetoothManager
    @State private var elapsedSeconds: Int = 0
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Populated by refreshShareURLs(), not computed inline in `body` — this
    // view also observes `bt`, whose @Published properties change many
    // times a second while data is streaming, and copying files on every
    // single re-render would be wasteful I/O. Only recomputed when
    // lastSessionFolder actually changes (i.e., once per stopRecording()).
    @State private var csvShareURL: URL?
    @State private var jsonShareURL: URL?

    private var elapsedText: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var summaryText: String {
        if sessionController.state == .recording {
            let started = sessionController.recordingStartedAt.map {
                DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium)
            } ?? ""
            return "Recording \(sessionController.recordedSampleCount) packets · started \(started)"
        }
        if let folder = sessionController.lastSessionFolder {
            return "Last saved \(sessionController.recordedSampleCount) packets · \(folder.lastPathComponent)"
        }
        return "Not recording · no saved sessions yet"
    }

    // Copies raw.csv/metadata.json to temp files named after the session
    // folder (e.g. "phoebeTest_abc123_20260825-120000.csv") instead of
    // sharing the on-disk "raw.csv"/"metadata.json" directly — participant
    // ID, session ID, and timestamp only otherwise live in the folder name,
    // which doesn't travel with a share. A generically-named "raw.csv"
    // AirDropped or saved to Files would silently lose all of that context
    // (§8: "participant/session information is included").
    private func refreshShareURLs(for folder: URL?) {
        guard let folder else {
            csvShareURL = nil
            jsonShareURL = nil
            return
        }
        let base = folder.lastPathComponent
        csvShareURL = copyForSharing(folder.appendingPathComponent("raw.csv"), as: "\(base).csv")
        jsonShareURL = copyForSharing(folder.appendingPathComponent("metadata.json"), as: "\(base).json")
    }

    private func copyForSharing(_ source: URL, as filename: String) -> URL? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = sessionController.recordingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Recorder").font(.headline)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if sessionController.state == .recording {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(elapsedText).font(.subheadline.monospacedDigit())
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Start Recording") {
                    sessionController.startRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#dc2626"))
                .disabled(sessionController.state == .recording)

                Button("Stop & Save") {
                    sessionController.stopRecording(heartRateBPM: bt.heartRateBPM, spo2Percent: bt.spo2Percent)
                }
                .buttonStyle(.bordered)
                .disabled(sessionController.state != .recording)

                Spacer()

                if let csvShareURL {
                    ShareLink(item: csvShareURL) {
                        Label("Download CSV", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Label("Download CSV", systemImage: "square.and.arrow.up")
                        .foregroundColor(.secondary)
                        .opacity(0.4)
                }

                if let jsonShareURL {
                    ShareLink(item: jsonShareURL) {
                        Label("Download JSON", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Label("Download JSON", systemImage: "square.and.arrow.up")
                        .foregroundColor(.secondary)
                        .opacity(0.4)
                }
            }
            .font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .overlay(Divider(), alignment: .top)
        .onReceive(timer) { _ in
            guard sessionController.state == .recording, let start = sessionController.recordingStartedAt else { return }
            elapsedSeconds = Int(Date().timeIntervalSince(start))
        }
        .onAppear {
            refreshShareURLs(for: sessionController.lastSessionFolder)
        }
        .onChange(of: sessionController.lastSessionFolder) { newFolder in
            refreshShareURLs(for: newFolder)
        }
    }
}
