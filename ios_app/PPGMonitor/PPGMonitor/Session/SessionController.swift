//
//  SessionController.swift
//  PPGMonitor
//

import Foundation

enum SessionState {
    case participantEntry
    case ready
    case recording
    case stopped
}

class SessionController: ObservableObject {
    @Published var state: SessionState = .participantEntry
    @Published var participantID: String = ""
    @Published var recordingError: String?

    // Mirrors ppg_monitor.html's currentRecording — live packet count +
    // start time while recording, so the recorder bar can show real status.
    @Published var recordedSampleCount = 0
    @Published var recordingStartedAt: Date?

    // The most recently completed recording's folder, for CSV/JSON export —
    // equivalent to the HTML's "Download CSV/JSON" buttons.
    @Published var lastSessionFolder: URL?

    private var recorder: SessionRecorder?

    func beginSession(participantID: String) {
        let trimmed = participantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.participantID = trimmed
        state = .ready
    }

    func startRecording() {
        guard state == .ready || state == .stopped else { return }

        let sessionID = String(UUID().uuidString.prefix(8))
        let newRecorder = SessionRecorder(participantID: participantID, sessionID: sessionID)
        do {
            try newRecorder.start()
        } catch {
            recordingError = "Couldn't start recording: \(error.localizedDescription)"
            return
        }
        recorder = newRecorder
        recordingError = nil
        recordedSampleCount = 0
        recordingStartedAt = Date()
        state = .recording
    }

    func stopRecording(heartRateBPM: Int? = nil, spo2Percent: Int? = nil) {
        guard state == .recording else { return }
        lastSessionFolder = recorder?.sessionFolder
        recorder?.close(finalHeartRateBPM: heartRateBPM, finalSpo2Percent: spo2Percent)
        recorder = nil
        recordingStartedAt = nil
        state = .stopped
    }

    // Called by BluetoothManager.onParsedSample for every sample that
    // arrives, regardless of session state — it's a no-op unless we're
    // actively recording.
    func recordSample(_ sample: ParsedSample) {
        guard state == .recording else { return }
        recorder?.append(sample)
        recordedSampleCount += 1
    }

    func changeParticipant() {
        guard state != .recording else { return }
        participantID = ""
        // Otherwise the recorder bar would keep showing the previous
        // participant's "Last saved..." summary until the new participant
        // actually records something — stale state implying the wrong
        // session, not actual data mixing, but still worth clearing.
        lastSessionFolder = nil
        recordedSampleCount = 0
        recordingError = nil
        state = .participantEntry
    }
}
