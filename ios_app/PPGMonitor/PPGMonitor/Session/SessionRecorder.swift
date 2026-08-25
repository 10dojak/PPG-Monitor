//
//  SessionRecorder.swift
//  PPGMonitor
//

import Foundation

class SessionRecorder {
    let sessionFolder: URL
    private var fileHandle: FileHandle?
    private var metadata: SessionMetadata
    private var sampleCount = 0

    init(participantID: String, sessionID: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let startTime = Date()
        let timestamp = formatter.string(from: startTime)

        let folderName = "\(participantID)_\(sessionID)_\(timestamp)"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        sessionFolder = documents.appendingPathComponent("Sessions").appendingPathComponent(folderName)

        metadata = SessionMetadata(
            participantID: participantID,
            sessionID: sessionID,
            startTime: startTime,
            endTime: nil,
            measuredSampleRate: nil,
            finalHeartRateBPM: nil,
            finalSpo2Percent: nil
        )
    }

    func start() throws {
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)

        let csvURL = sessionFolder.appendingPathComponent("raw.csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: csvURL)

        let header = "timestamp,chip,stream,tag,value,slotIdx\n"
        try fileHandle?.write(contentsOf: header.data(using: .utf8)!)

        try writeMetadata()
    }

    func append(_ sample: ParsedSample) {
        guard let fileHandle else { return }
        sampleCount += 1
        let line = "\(sample.receivedAt.timeIntervalSince1970),\(sample.chip),\(sample.stream),\(sample.tag),\(sample.value),\(sample.slotIdx)\n"
        do {
            try fileHandle.write(contentsOf: line.data(using: .utf8)!)
        } catch {
            print("SessionRecorder: failed to write sample - \(error)")
        }
    }

    func close(finalHeartRateBPM: Int? = nil, finalSpo2Percent: Int? = nil) {
        let endTime = Date()
        let elapsed = endTime.timeIntervalSince(metadata.startTime)
        metadata.endTime = endTime
        metadata.measuredSampleRate = elapsed > 0 ? Double(sampleCount) / elapsed : 0
        metadata.finalHeartRateBPM = finalHeartRateBPM
        metadata.finalSpo2Percent = finalSpo2Percent

        do {
            try writeMetadata()
        } catch {
            print("SessionRecorder: failed to write final metadata - \(error)")
        }

        try? fileHandle?.close()
        fileHandle = nil
    }

    private func writeMetadata() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        // Match raw.csv's timestamp convention (Unix epoch seconds) — the
        // default .deferredToDate strategy encodes seconds since Apple's
        // 2001-01-01 reference date instead, which would silently read as
        // ~31 years wrong in Python/MATLAB with no hint anything's off.
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(metadata)

        let metadataURL = sessionFolder.appendingPathComponent("metadata.json")
        try data.write(to: metadataURL)
    }
}
