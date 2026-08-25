//
//  PPGMonitorTests.swift
//  PPGMonitorTests
//
//  Created by Phoebe Lo on 8/18/26.
//

import Foundation
import Testing
@testable import PPGMonitor

struct PPGMonitorTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    // End-to-end: mock BLE lines -> BluetoothManager -> SessionController ->
    // SessionRecorder -> real files on disk. Proves the wiring actually
    // moves data, not just that each piece compiles in isolation.
    @Test func mockRecordingWritesRealFiles() async throws {
        let bt = BluetoothManager()
        let sessionController = SessionController()
        bt.onParsedSample = { sample in sessionController.recordSample(sample) }

        let participantID = "testParticipant"
        sessionController.beginSession(participantID: participantID)
        sessionController.startRecording()
        #expect(sessionController.recordingError == nil)
        #expect(sessionController.state == .recording)

        // SpO2 needs >=20 rolling samples on each of two specific channels
        // (u2 tag 7 and tag 9), which at the mock's ~4 samples/sec/channel
        // rate takes a few seconds — longer than what CSV/metadata checks
        // alone would need.
        try await Task.sleep(nanoseconds: 9_000_000_000)

        sessionController.stopRecording(heartRateBPM: bt.heartRateBPM, spo2Percent: bt.spo2Percent)
        #expect(sessionController.state == .stopped)

        let sessionsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions")
        let folders = try FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
        let sessionFolder = try #require(folders.filter { $0.lastPathComponent.hasPrefix(participantID) }.first)

        let csvText = try String(contentsOf: sessionFolder.appendingPathComponent("raw.csv"), encoding: .utf8)
        let csvLines = csvText.split(separator: "\n")
        #expect(csvLines.first == "timestamp,chip,stream,tag,value,slotIdx")
        #expect(csvLines.count > 10)   // header + real samples, not just an empty stub

        let metadataData = try Data(contentsOf: sessionFolder.appendingPathComponent("metadata.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970   // matches SessionRecorder's encoder
        let metadata = try decoder.decode(SessionMetadata.self, from: metadataData)
        #expect(metadata.participantID == participantID)
        #expect(metadata.endTime != nil)
        #expect((metadata.measuredSampleRate ?? 0) > 0)
        // HR/SpO2 need enough rolling samples to compute (§7: calculated
        // metrics are saved) — 1.5s of ~100 lines/sec mock data is enough.
        #expect(metadata.finalHeartRateBPM != nil)
        #expect(metadata.finalSpo2Percent != nil)
    }

    // §2: "starting/stopping multiple sessions does not require restarting
    // the app" — start, stop, start again on the same controller instance
    // and confirm both recordings land in distinct, complete folders.
    @Test func backToBackRecordingsProduceSeparateFolders() async throws {
        let bt = BluetoothManager()
        let sessionController = SessionController()
        bt.onParsedSample = { sample in sessionController.recordSample(sample) }

        let participantID = "backToBackTest"
        sessionController.beginSession(participantID: participantID)

        sessionController.startRecording()
        #expect(sessionController.state == .recording)
        try await Task.sleep(nanoseconds: 800_000_000)
        sessionController.stopRecording()
        #expect(sessionController.state == .stopped)
        let firstFolder = try #require(sessionController.lastSessionFolder)

        // No restart, no re-entering participant ID — straight into a second
        // recording, same as a user tapping Start again on the same screen.
        sessionController.startRecording()
        #expect(sessionController.recordingError == nil)
        #expect(sessionController.state == .recording)
        try await Task.sleep(nanoseconds: 800_000_000)
        sessionController.stopRecording()
        #expect(sessionController.state == .stopped)
        let secondFolder = try #require(sessionController.lastSessionFolder)

        #expect(firstFolder != secondFolder)
        for folder in [firstFolder, secondFolder] {
            let csvText = try String(contentsOf: folder.appendingPathComponent("raw.csv"), encoding: .utf8)
            #expect(csvText.split(separator: "\n").count > 5)
        }
    }

    // MARK: - §10: corrupted/incomplete packet handling

    @Test func parseLineHandlesWellFormedPackets() {
        let u10 = parseLine("3 481 3")
        #expect(u10?.chip == .u10)
        #expect(u10?.stream == .ppg)
        #expect(u10?.tag == 3)
        #expect(u10?.value == 481)
        #expect(u10?.slotIdx == 3)

        let u2 = parseLine("9 66234 137")
        #expect(u2?.chip == .u2)
        #expect(u2?.stream == .ppg)

        let accel = parseLine("0 20030 200")
        #expect(accel?.chip == .imu)
        #expect(accel?.stream == .accel)

        let gyro = parseLine("0 50120 211")
        #expect(gyro?.chip == .imu)
        #expect(gyro?.stream == .gyro)

        let wakeup = parseLine("0 3 220")
        #expect(wakeup?.chip == .imu)
        #expect(wakeup?.stream == .wakeup)
    }

    @Test func parseLineRejectsCorruptedPackets() {
        #expect(parseLine("") == nil)
        #expect(parseLine("3 481") == nil)              // missing slotIdx
        #expect(parseLine("3 481 3 extra") == nil)      // extra token
        #expect(parseLine("abc 481 3") == nil)           // non-numeric tag
        #expect(parseLine("3 xyz 3") == nil)              // non-numeric value
        #expect(parseLine("3 481 abc") == nil)            // non-numeric slotIdx
        #expect(parseLine("3 481 999") == nil)            // slotIdx out of every known range
        #expect(parseLine("3 481 -1") == nil)             // negative slotIdx
    }

    // MARK: - §10: "existing recorded data are protected if an error occurs"

    // Streaming writes should survive even if the recording is never
    // cleanly stopped (app crash, force-quit) — this is the specific claim
    // FileHandle-based append() exists to make true, verified directly here
    // rather than just asserted in a comment.
    @Test func dataWrittenBeforeUncleanShutdownSurvives() throws {
        let participantID = "crashTest"
        let recorder = SessionRecorder(participantID: participantID, sessionID: "crash1")
        try recorder.start()

        let samples = (0..<5).map { i in
            ParsedSample(receivedAt: Date(), chip: .u10, stream: .ppg, tag: i + 1, value: 100 * i, slotIdx: i + 1)
        }
        samples.forEach { recorder.append($0) }
        // Deliberately never call recorder.close() — simulates a crash
        // mid-recording. The file handle still gets deallocated when
        // `recorder` goes out of scope, but no explicit flush/close happens.

        let csvText = try String(contentsOf: recorder.sessionFolder.appendingPathComponent("raw.csv"), encoding: .utf8)
        let rows = csvText.split(separator: "\n").dropFirst()   // skip header
        #expect(rows.count == 5)
        for (i, row) in rows.enumerated() {
            let fields = row.split(separator: ",")
            #expect(fields[3] == "\(i + 1)")           // tag
            #expect(fields[4] == "\(100 * i)")         // value
        }
        // metadata.json from the start()-time write should also be present,
        // even though close() (the endTime/rate update) never ran.
        #expect(FileManager.default.fileExists(atPath: recorder.sessionFolder.appendingPathComponent("metadata.json").path))
    }

    // MARK: - §11: "saved data compared against real-time display" /
    // "exported data checked against the original recorded values"

    @Test func recordedCsvValuesExactlyMatchInputSamples() throws {
        let recorder = SessionRecorder(participantID: "fidelityTest", sessionID: "fid1")
        try recorder.start()

        let inputSamples = [
            ParsedSample(receivedAt: Date(), chip: .u10, stream: .ppg, tag: 3, value: 481, slotIdx: 3),
            ParsedSample(receivedAt: Date(), chip: .u2, stream: .ppg, tag: 9, value: 66234, slotIdx: 137),
            ParsedSample(receivedAt: Date(), chip: .imu, stream: .accel, tag: 0, value: 20030, slotIdx: 200),
        ]
        inputSamples.forEach { recorder.append($0) }
        recorder.close()

        let csvText = try String(contentsOf: recorder.sessionFolder.appendingPathComponent("raw.csv"), encoding: .utf8)
        let rows = csvText.split(separator: "\n").dropFirst()
        #expect(rows.count == inputSamples.count)

        for (input, row) in zip(inputSamples, rows) {
            let fields = row.split(separator: ",").map(String.init)
            #expect(fields[1] == "\(input.chip)")
            #expect(fields[2] == "\(input.stream)")
            #expect(fields[3] == "\(input.tag)")
            #expect(fields[4] == "\(input.value)")
            #expect(fields[5] == "\(input.slotIdx)")
        }
    }

    // MARK: - §2: "no samples are unintentionally dropped" — partial lines
    // split across separate BLE characteristic-value-changed callbacks.

    private final class TestDataSource: PPGDataSource {
        var onLine: ((String) -> Void)?
        var onStatusChange: ((Bool, String) -> Void)?
        func start() {}
        func stop() {}
    }

    @Test func partialLinesSplitAcrossCallbacksAreNotDropped() async {
        let source = TestDataSource()
        let bt = BluetoothManager(dataSource: source)
        var received: [ParsedSample] = []
        bt.onParsedSample = { received.append($0) }

        // A line split mid-way (as BLE MTU boundaries can do), plus a
        // complete line landing in the same callback as the split remainder.
        source.onLine?("3 481 3\n5 200 ")
        source.onLine?("5\n9 700 9\n")

        // receive() dispatches to main async now (see BluetoothManager);
        // wait for both calls above to actually finish processing.
        await MainActor.run {
            #expect(received.count == 3)
            #expect(received[0].tag == 3 && received[0].value == 481)
            #expect(received[1].tag == 5 && received[1].value == 200 && received[1].slotIdx == 5)
            #expect(received[2].tag == 9 && received[2].value == 700)
        }
    }

    // MARK: - §3/§11: bounded display buffers under sustained high throughput
    // ("plot does not freeze during long recordings" / "long-duration
    // recording tested") — feeds far more samples than a real session would
    // see per second, synchronously (no timer pacing), so this runs in
    // milliseconds instead of needing actual long wall-clock recording time.

    @Test func displayBuffersStayBoundedUnderHighThroughput() async throws {
        let source = TestDataSource()
        let bt = BluetoothManager(dataSource: source)
        let sessionController = SessionController()
        bt.onParsedSample = { sample in sessionController.recordSample(sample) }

        sessionController.beginSession(participantID: "stressTest")
        sessionController.startRecording()

        for i in 0..<20_000 {
            let tag = (i % 12) + 1
            let slotIdx = tag - 1   // keep in 0...11 (valid U10 range) for every i
            source.onLine?("\(tag) \(i % 300_000) \(slotIdx)\n")
        }

        // BluetoothManager.receive() dispatches to main async now (so it's
        // correctly serialized regardless of which thread calls it — see
        // that file for why), but this test's synchronous loop above just
        // enqueued 20,000 of those calls without waiting for any to run.
        // Hopping onto the main actor drains that queue first; only then is
        // it safe to inspect `bt.channels` or trust every sample has been
        // recorded.
        await MainActor.run {
            for (_, points) in bt.channels {
                #expect(points.count <= 200)
            }
        }

        sessionController.stopRecording()
        // The recording itself, unlike the display buffers, is NOT capped —
        // every sample fed in should have reached disk.
        guard let folder = sessionController.lastSessionFolder,
              let csvText = try? String(contentsOf: folder.appendingPathComponent("raw.csv"), encoding: .utf8) else {
            Issue.record("expected a session folder with a readable raw.csv")
            return
        }
        let rowCount = csvText.split(separator: "\n").count - 1   // minus header
        #expect(rowCount == 20_000)
    }

    // §5: changing participants shouldn't leave the previous participant's
    // "last saved" summary visible until the new one records something.
    @Test func changeParticipantClearsPreviousSessionSummary() async throws {
        let bt = BluetoothManager()
        let sessionController = SessionController()
        bt.onParsedSample = { sample in sessionController.recordSample(sample) }

        sessionController.beginSession(participantID: "participantA")
        sessionController.startRecording()
        try await Task.sleep(nanoseconds: 500_000_000)
        sessionController.stopRecording()
        #expect(sessionController.lastSessionFolder != nil)
        #expect(sessionController.recordedSampleCount > 0)

        sessionController.changeParticipant()
        #expect(sessionController.state == .participantEntry)
        #expect(sessionController.lastSessionFolder == nil)
        #expect(sessionController.recordedSampleCount == 0)
    }

}
