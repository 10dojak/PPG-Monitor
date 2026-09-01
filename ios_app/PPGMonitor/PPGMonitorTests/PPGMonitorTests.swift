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

        let csvText = try String(contentsOf: sessionFolder.appendingPathComponent("session.csv"), encoding: .utf8)
        let lines = csvText.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        let commentLines = lines.filter { $0.hasPrefix("#") }
        let nonCommentLines = lines.filter { !$0.hasPrefix("#") }

        // Header comment block: participant/session identity + fixed
        // acquisition settings, all known at start() — present regardless
        // of how the recording ends.
        #expect(commentLines.contains { $0 == "# participantID: \(participantID)" })
        #expect(commentLines.contains { $0.hasPrefix("# sessionID: ") })
        #expect(commentLines.contains { $0 == "# nominalPPGSampleRateHz: 25.0" })
        #expect(commentLines.contains { $0 == "# accelRangeG: 2.0" })
        #expect(commentLines.contains { $0 == "# accelNominalODRHz: 26.0" })

        // Footer comment block: only known at close() — measured rates and
        // final HR/SpO2 (§7: calculated metrics are saved).
        #expect(commentLines.contains { $0.hasPrefix("# endTime: ") })
        #expect(commentLines.contains { $0.hasPrefix("# measuredPPGSampleRateHz: ") })
        #expect(commentLines.contains { $0.hasPrefix("# measuredAccelSampleRateHz: ") })
        // HR/SpO2 need enough rolling samples to compute — 9s of mock data
        // is enough; a "null" value (not just the key existing) means it
        // never actually got computed.
        #expect(commentLines.contains { $0.hasPrefix("# finalHeartRateBPM: ") && !$0.hasSuffix("null") })
        #expect(commentLines.contains { $0.hasPrefix("# finalSpo2Percent: ") && !$0.hasSuffix("null") })

        // One column header row + real data rows, not just an empty stub.
        let header = nonCommentLines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(header.count == 1 + ppgDatasets.count + 3)   // timestamp + 24 PPG + accel X/Y/Z
        #expect(header[0] == "timestamp")
        #expect(nonCommentLines.count > 6)   // several ~200ms-batched rows over 9 real seconds
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
            let csvText = try String(contentsOf: folder.appendingPathComponent("session.csv"), encoding: .utf8)
            let dataRows = csvText.split(separator: "\n").filter { !$0.hasPrefix("#") }.dropFirst()   // drop column header
            #expect(dataRows.count >= 1)   // close() always flushes at least the final pending bucket
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
        #expect(parseLine("5") == nil)                    // single token
        #expect(parseLine("0 3") == nil)                  // 2 tokens but tag 0 isn't a PPG tag
        #expect(parseLine("abc 481 3") == nil)            // non-numeric tag
        #expect(parseLine("3 xyz 3") == nil)              // non-numeric value
        #expect(parseLine("3 481 abc") == nil)            // slotIdx present but non-numeric → garbled
        #expect(parseLine("3 481 999") == nil)            // explicit slotIdx out of every known range
        #expect(parseLine("3 481 -1") == nil)             // explicit negative slotIdx
    }

    // ppg_monitor.html's parser accepts a bare "tag value" pair and ignores
    // junk after a valid triplet; being stricter than that caused a
    // 100%-parse-error run on real hardware, so the port matches it here.
    @Test func parseLineMatchesHtmlTolerance() {
        let bare = parseLine("3 481")                     // no slotIdx on the wire
        #expect(bare?.chip == .u10)
        #expect(bare?.stream == .ppg)
        #expect(bare?.tag == 3)
        #expect(bare?.value == 481)
        #expect(bare?.slotIdx == slotIdxAbsent)

        let trailingJunk = parseLine("3 481 3 extra tokens")
        #expect(trailingJunk?.chip == .u10)
        #expect(trailingJunk?.slotIdx == 3)

        #expect(parseLine("9\t66234\t137")?.chip == .u2)  // tab-separated, like /\s+/
        #expect(parseLine("  3   481   3  ")?.tag == 3)   // padded / multi-space
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

        // Each sample lands in a fresh ~200ms bucket, one distinct PPG tag
        // per sample — deterministically forces a flush on every append
        // after the first, instead of depending on real wall-clock gaps.
        let base = Date()
        let samples = (0..<5).map { i in
            ParsedSample(receivedAt: base.addingTimeInterval(Double(i) * 0.25), chip: .u10, stream: .ppg, tag: i + 1, value: 100 * i, slotIdx: i + 1)
        }
        samples.forEach { recorder.append($0) }
        // Deliberately never call recorder.close() — simulates a crash
        // mid-recording. Only the most-recent, not-yet-flushed bucket is
        // ever at risk this way (the accepted tradeoff of batching rows by
        // ~200ms cycle instead of flushing every single sample) — the 5th
        // sample's tag is expected to be missing below; everything before
        // it was already durable on disk the moment its bucket completed.

        let csvText = try String(contentsOf: recorder.sessionFolder.appendingPathComponent("session.csv"), encoding: .utf8)
        let allLines = csvText.split(separator: "\n").filter { !$0.isEmpty }
        #expect(allLines.contains { $0 == "# participantID: \(participantID)" })
        #expect(!allLines.contains { $0.hasPrefix("# endTime: ") })   // close() never ran

        let dataRows = allLines.filter { !$0.hasPrefix("#") }.dropFirst()   // drop column header
        #expect(dataRows.count == 4)   // 5 samples, 4 completed buckets flushed, 5th still pending

        func tagColumn(_ tag: Int) -> Int {
            let dataset = ppgDatasets.first { $0.channelKey == tag }!
            let colName = "\(dataset.label) [\(dataset.chip) tag\(dataset.tag)]"
            let header = allLines.first { !$0.hasPrefix("#") }!.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return header.firstIndex(of: colName)!
        }
        // Row N carries forward tags 1...N — tag 5 (the pending bucket)
        // never appears in any flushed row.
        let lastRow = dataRows.last!.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(lastRow[tagColumn(1)] == "0")
        #expect(lastRow[tagColumn(2)] == "100")
        #expect(lastRow[tagColumn(3)] == "200")
        #expect(lastRow[tagColumn(4)] == "300")
        #expect(lastRow[tagColumn(5)] == "")
    }

    // MARK: - §11: "saved data compared against real-time display" /
    // "exported data checked against the original recorded values"

    // Single unified export, one row per ~200ms cycle: PPG + accel columns
    // carry forward last-known values (§11: exported data checked against
    // original recorded values), gyro/wake-up are excluded entirely, and
    // synthetic timestamps 250ms apart force one flush per sample so the
    // whole carry-forward sequence is deterministic instead of depending on
    // real wall-clock gaps.
    @Test func sessionCsvCarriesForwardLastKnownValuesAndExcludesGyroWakeup() throws {
        let recorder = SessionRecorder(participantID: "fidelityTest", sessionID: "fid1")
        try recorder.start()

        let base = Date()
        func at(_ offsetSeconds: Double) -> Date { base.addingTimeInterval(offsetSeconds) }

        recorder.append(ParsedSample(receivedAt: at(0.00), chip: .u10, stream: .ppg,    tag: 3, value: 481,   slotIdx: 3))
        recorder.append(ParsedSample(receivedAt: at(0.25), chip: .u10, stream: .ppg,    tag: 9, value: 512,   slotIdx: 9))
        recorder.append(ParsedSample(receivedAt: at(0.30), chip: .imu, stream: .gyro,   tag: 0, value: 50000, slotIdx: 210))   // excluded
        recorder.append(ParsedSample(receivedAt: at(0.35), chip: .imu, stream: .wakeup, tag: 0, value: 1,     slotIdx: 220))   // excluded
        recorder.append(ParsedSample(receivedAt: at(0.50), chip: .imu, stream: .accel,  tag: 0, value: 20030, slotIdx: 200))
        recorder.append(ParsedSample(receivedAt: at(0.75), chip: .u2,  stream: .ppg,    tag: 9, value: 66234, slotIdx: 137))
        recorder.append(ParsedSample(receivedAt: at(1.00), chip: .u10, stream: .ppg,    tag: 3, value: 490,   slotIdx: 3))
        recorder.close()   // flushes the final pending bucket too

        let text = try String(contentsOf: recorder.sessionFolder.appendingPathComponent("session.csv"), encoding: .utf8)
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        let nonComment = allLines.filter { !$0.hasPrefix("#") }
        let header = nonComment[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let dataRows = nonComment.dropFirst()

        #expect(header.count == 1 + ppgDatasets.count + 3)   // timestamp + 24 PPG + accel X/Y/Z — no gyro/wake-up columns at all
        #expect(dataRows.count == 5)   // 4 bucket-boundary flushes + 1 final flush at close()

        func ppgColumn(chip: Chip, tag: Int) -> Int {
            let key = chip == .u10 ? tag : tag + u2ChannelKeyOffset
            let dataset = ppgDatasets.first { $0.channelKey == key }!
            return header.firstIndex(of: "\(dataset.label) [\(dataset.chip) tag\(dataset.tag)]")!
        }
        let tag3Col = ppgColumn(chip: .u10, tag: 3)
        let tag9Col = ppgColumn(chip: .u10, tag: 9)
        let u2Tag9Col = ppgColumn(chip: .u2, tag: 9)
        let accelXCol = header.firstIndex(of: "Accel X [imu 200]")!

        func row(_ i: Int) -> [String] {
            dataRows[dataRows.index(dataRows.startIndex, offsetBy: i)].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        #expect(row(0)[tag3Col] == "481"); #expect(row(0)[tag9Col] == "");    #expect(row(0)[u2Tag9Col] == "");      #expect(row(0)[accelXCol] == "")
        #expect(row(1)[tag3Col] == "481"); #expect(row(1)[tag9Col] == "512"); #expect(row(1)[u2Tag9Col] == "");      #expect(row(1)[accelXCol] == "")
        #expect(row(2)[tag3Col] == "481"); #expect(row(2)[tag9Col] == "512"); #expect(row(2)[u2Tag9Col] == "");      #expect(row(2)[accelXCol] == "20030")
        #expect(row(3)[tag3Col] == "481"); #expect(row(3)[tag9Col] == "512"); #expect(row(3)[u2Tag9Col] == "66234"); #expect(row(3)[accelXCol] == "20030")
        #expect(row(4)[tag3Col] == "490"); #expect(row(4)[tag9Col] == "512"); #expect(row(4)[u2Tag9Col] == "66234"); #expect(row(4)[accelXCol] == "20030")
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
        // The recording pipeline, unlike the display buffers, doesn't drop
        // anything under load — 20,000 samples land in real wall-clock time
        // this tight loop takes (milliseconds), so with ~200ms row batching
        // they collapse into far fewer rows than 20,000 by design (see
        // sessionCsvCarriesForwardLastKnownValuesAndExcludesGyroWakeup for
        // the batching's exact row semantics) — what matters here is that
        // the pipeline didn't crash or silently produce an empty file under
        // sustained synchronous throughput.
        guard let folder = sessionController.lastSessionFolder,
              let csvText = try? String(contentsOf: folder.appendingPathComponent("session.csv"), encoding: .utf8) else {
            Issue.record("expected a session folder with a readable session.csv")
            return
        }
        let dataRows = csvText.split(separator: "\n").filter { !$0.hasPrefix("#") }.dropFirst()
        #expect(dataRows.count >= 1)
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
