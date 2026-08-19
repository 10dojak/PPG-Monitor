//
//  MockReplayDataSource.swift
//  PPGMonitor
//
//  Replays a captured log file as if it were a live BLE stream, so the rest
//  of the app can be built and tested with no hardware and no CoreBluetooth
//  involved. Mock/sample_session.txt is a real capture from Rutendo
//  (ppg-session-2026-08-18T22-53-15-230Z), not synthetic data.
//

import Foundation

final class MockReplayDataSource: PPGDataSource {
    var onLine: ((String) -> Void)?
    var onStatusChange: ((Bool, String) -> Void)?

    private let lines: [String]
    private let intervalSeconds: TimeInterval
    private var timer: Timer?
    private var index = 0

    // 0.01s ≈ 101 lines/sec — matches the real aggregate line rate measured
    // from Rutendo's capture (1203 lines / 11.87s), not the 25 SPS nominal
    // spec, which the firmware doesn't currently achieve (see TODO.md).
    init(resourceName: String = "sample_session", intervalSeconds: TimeInterval = 0.01) {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            self.lines = content
                .split(separator: "\n")
                .map { String($0) }
                .filter { !$0.isEmpty }
        } else {
            self.lines = []
        }
        self.intervalSeconds = intervalSeconds
    }

    func start() {
        guard !lines.isEmpty else {
            onStatusChange?(false, "Mock data file not found")
            return
        }
        onStatusChange?(true, "Replaying mock data")
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            self?.emitNextLine()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onStatusChange?(false, "Mock data source stopped")
    }

    private func emitNextLine() {
        onLine?(lines[index] + "\n")
        index = (index + 1) % lines.count
    }
}
