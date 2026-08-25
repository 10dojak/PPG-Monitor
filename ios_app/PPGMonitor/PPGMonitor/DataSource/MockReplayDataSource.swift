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
    private var timerSource: DispatchSourceTimer?
    private var index = 0

    // 0.01s ≈ 101 lines/sec — matches the real aggregate line rate measured
    // from Rutendo's capture (1203 lines / 11.87s), not the 25 SPS nominal
    // spec, which the firmware doesn't currently achieve (see TODO.md).
    init(resourceName: String = "sample_session", intervalSeconds: TimeInterval = 0.01) {
        var captured: [String] = []
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            captured = content
                .split(separator: "\n")
                .map { String($0) }
                .filter { !$0.isEmpty }
        }
        // Rutendo's capture (see header above) predates IMU support and has
        // zero accel samples, so the accel parse/convert/chart path has
        // never actually run against anything. Interleave a synthetic accel
        // signal so it does — not a stand-in for real IMU data, just enough
        // to exercise the path before real hardware is available.
        self.lines = Self.interleaveAccel(into: captured)
        self.intervalSeconds = intervalSeconds
    }

    // Roughly-stationary device (~1g on Z, small X/Y wobble) with a brief
    // "motion" burst every so often, so both the still and motion-detected
    // states in AccelView actually get exercised.
    private static func interleaveAccel(into captured: [String]) -> [String] {
        guard !captured.isEmpty else { return captured }

        var result: [String] = []
        var sampleIndex = 0
        for (i, line) in captured.enumerated() {
            result.append(line)
            guard (i + 1) % 8 == 0 else { continue }   // one accel triplet per 8 PPG lines

            let t = Double(sampleIndex) * 0.04
            let burst = (sampleIndex / 60) % 5 == 0 ? 6.0 : 0.0
            let x = 0.3 * sin(t * 1.3) + burst * sin(t * 4)
            let y = 0.3 * cos(t * 0.9) + burst * cos(t * 4)
            let z = 9.81 + 0.3 * sin(t * 0.5)
            for (axisValue, slotIdx) in [(x, 200), (y, 201), (z, 202)] {
                let raw = Int((axisValue * 100).rounded()) + 20000
                result.append("0 \(raw) \(slotIdx)")
            }
            sampleIndex += 1
        }
        return result
    }

    func start() {
        guard !lines.isEmpty else {
            onStatusChange?(false, "Mock data file not found")
            return
        }
        timerSource?.cancel()   // guard against double-starting (e.g. tapping Reconnect while already running)
        onStatusChange?(true, "Replaying mock data")

        // DispatchSourceTimer on an explicit queue, not Timer.scheduledTimer
        // on "whatever run loop happens to be current" — start() can be
        // called from a thread with no actively-spinning run loop (e.g. a
        // Swift Testing worker task), where a plain Timer would silently
        // never fire.
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: intervalSeconds)
        source.setEventHandler { [weak self] in
            self?.emitNextLine()
        }
        source.resume()
        timerSource = source
    }

    func stop() {
        timerSource?.cancel()
        timerSource = nil
        onStatusChange?(false, "Mock data source stopped")
    }

    private func emitNextLine() {
        onLine?(lines[index] + "\n")
        index = (index + 1) % lines.count
    }
}
