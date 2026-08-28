//
//  SessionRecorder.swift
//  PPGMonitor
//
//  One file per recording: session.csv. No separate metadata.json, no
//  separate "wide" file — participant/session/settings info lives in a
//  `#`-prefixed comment header (pandas/MATLAB skip these natively), the 24
//  PPG channels + accel X/Y/Z are columns (self-documented in the header row
//  with each column's chip/tag/slotIdx), and end-of-recording stats
//  (measured rates, HR/SpO2) land in a comment footer once they're known.
//

import Foundation

class SessionRecorder {
    let sessionFolder: URL
    private var fileHandle: FileHandle?

    private let participantID: String
    private let sessionID: String
    private let startTime: Date

    // Row cadence: matches the firmware's ~200ms per-cycle transmit tick
    // (CLAUDE.md). Writing one row per *incoming sample* would mean up to 27
    // near-identical rows (24 PPG + 3 accel columns, each updating on its
    // own independent schedule) for every real reading — instead, samples
    // are batched into ~200ms buckets and one row is flushed per bucket,
    // carrying forward each column's last-known value.
    private let rowIntervalSeconds: TimeInterval = 0.2
    private var currentBucketIndex: Int?
    private var currentBucketTimestamp: Date?

    private let ppgChannelKeys: [Int] = ppgDatasets.map { $0.channelKey }
    private var lastKnownPPGValues: [Int: Int] = [:]
    private let accelSlotIdxs = [200, 201, 202]
    private var lastKnownAccelValues: [Int: Int] = [:]

    private var sampleCount = 0
    private var sampleCountsByStream: [StreamType: Int] = [:]

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    init(participantID: String, sessionID: String) {
        self.participantID = participantID
        self.sessionID = sessionID
        self.startTime = Date()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folderName = "\(participantID)_\(sessionID)_\(formatter.string(from: startTime))"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        sessionFolder = documents.appendingPathComponent("Sessions").appendingPathComponent(folderName)
    }

    func start() throws {
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)

        let csvURL = sessionFolder.appendingPathComponent("session.csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: csvURL)

        try write(headerComment())
        try write(columnHeaderRow())
    }

    func append(_ sample: ParsedSample) {
        sampleCount += 1
        sampleCountsByStream[sample.stream, default: 0] += 1

        // Not part of this export: gyro has never appeared in a real
        // capture and isn't in the checklist's scope (§4 asks for
        // accelerometer only); the wake-up bitmask is a hardware motion
        // interrupt flag, not a scientific measurement, and is currently
        // disabled on the peripheral_uart_test firmware branch anyway.
        // Returning before any bucket bookkeeping means these samples don't
        // affect row timing at all, as if they didn't exist for this file.
        guard sample.stream == .ppg || sample.stream == .accel else { return }

        // Flush the *previous* bucket's snapshot before merging this
        // sample's value in — otherwise a sample that starts a new bucket
        // would leak its own value into the row being flushed for the old
        // one, corrupting exactly the boundary this batching is built
        // around.
        let bucket = Int((sample.receivedAt.timeIntervalSince1970 / rowIntervalSeconds).rounded(.down))
        if let current = currentBucketIndex, bucket != current, let pendingTimestamp = currentBucketTimestamp {
            flushRow(at: pendingTimestamp)
        }
        currentBucketIndex = bucket
        currentBucketTimestamp = sample.receivedAt

        switch sample.stream {
        case .ppg:
            let key = sample.chip == .u10 ? sample.tag : sample.tag + u2ChannelKeyOffset
            lastKnownPPGValues[key] = sample.value
        case .accel:
            lastKnownAccelValues[sample.slotIdx] = sample.value
        default:
            break
        }
    }

    func close(finalHeartRateBPM: Int? = nil, finalSpo2Percent: Int? = nil) {
        if let pendingTimestamp = currentBucketTimestamp {
            flushRow(at: pendingTimestamp)
            currentBucketIndex = nil
            currentBucketTimestamp = nil
        }

        let endTime = Date()
        let elapsed = endTime.timeIntervalSince(startTime)
        let measuredPPGRate = elapsed > 0 ? Double(sampleCountsByStream[.ppg, default: 0]) / elapsed : 0
        let measuredAccelRate = elapsed > 0 ? Double(sampleCountsByStream[.accel, default: 0]) / elapsed : 0

        try? write(footerComment(
            endTime: endTime,
            measuredPPGRate: measuredPPGRate,
            measuredAccelRate: measuredAccelRate,
            heartRateBPM: finalHeartRateBPM,
            spo2Percent: finalSpo2Percent
        ))

        try? fileHandle?.close()
        fileHandle = nil
    }

    private func flushRow(at timestamp: Date) {
        let ppgValues = ppgChannelKeys.map { lastKnownPPGValues[$0].map(String.init) ?? "" }
        let accelValues = accelSlotIdxs.map { lastKnownAccelValues[$0].map(String.init) ?? "" }
        let line = ([Self.iso(timestamp)] + ppgValues + accelValues).joined(separator: ",") + "\n"
        try? write(line)
    }

    private func columnHeaderRow() -> String {
        let ppgHeaders = ppgDatasets.map { "\($0.label) [\($0.chip) tag\($0.tag)]" }
        let accelHeaders = ["Accel X [imu 200]", "Accel Y [imu 201]", "Accel Z [imu 202]"]
        return (["timestamp"] + ppgHeaders + accelHeaders).joined(separator: ",") + "\n"
    }

    private func headerComment() -> String {
        let settings = AcquisitionSettings.current
        let lines = [
            "# PPG Monitor session export",
            "# participantID: \(participantID)",
            "# sessionID: \(sessionID)",
            "# startTime: \(Self.iso(startTime))",
            "# nominalPPGSampleRateHz: \(settings.nominalPPGSampleRateHz)",
            "# adcRangeNanoamps: \(settings.adcRangeNanoamps)",
            "# integrationTimeMicroseconds: \(settings.integrationTimeMicroseconds)",
            "# redLEDCurrentMA: \(settings.redLEDCurrentMA)",
            "# irLEDCurrentMA: \(settings.irLEDCurrentMA)",
            "# greenLEDCurrentMA: \(settings.greenLEDCurrentMA)",
            "# accelRangeG: \(settings.accelRangeG)",
            "# accelNominalODRHz: \(settings.accelNominalODRHz)",
            "# accelEncoding: raw = (acceleration_m/s^2 * 100) + 20000 -- decode with (raw - 20000) / 100",
            "# rowCadenceSeconds: \(rowIntervalSeconds) -- one row per ~200ms cycle; each column carries forward its last known value until it next updates",
            "# columns: timestamp (ISO 8601, wall-clock receive time -- the wire format has no on-device timestamp), then the 24 PPG channels [chip tagN], then Accel X/Y/Z [imu slotIdx]",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private func footerComment(
        endTime: Date,
        measuredPPGRate: Double,
        measuredAccelRate: Double,
        heartRateBPM: Int?,
        spo2Percent: Int?
    ) -> String {
        let lines = [
            "# endTime: \(Self.iso(endTime))",
            "# measuredPPGSampleRateHz: \(measuredPPGRate)",
            "# measuredAccelSampleRateHz: \(measuredAccelRate)",
            "# finalHeartRateBPM: \(heartRateBPM.map(String.init) ?? "null")",
            "# finalSpo2Percent: \(spo2Percent.map(String.init) ?? "null")",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private func write(_ text: String) throws {
        try fileHandle?.write(contentsOf: text.data(using: .utf8)!)
    }
}
