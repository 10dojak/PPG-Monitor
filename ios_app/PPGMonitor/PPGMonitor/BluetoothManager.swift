//
//  BluetoothManager.swift
//  PPG Monitor
//
//  Owns exactly one PPGDataSource (real BLE or mock replay — doesn't know or
//  care which) and turns its raw lines into parsed, published channel data.
//  No CoreBluetooth code lives here anymore; see DataSource/BLEDataSource.swift.
//

import Foundation
import Combine

// MAX86141 FIFO tag → channel description
// Tags 1-12 come from U10; we use the tag value as the channel key.
// U2 data (slotIdx 128-139) gets key = tag + 200 to avoid collision.
// IMU data (slotIdx 200-202) keeps slotIdx as key.
let tagToName: [Int: String] = [
    1:  "Red PD1",
    7:  "Red PD2",
    2:  "Red PD1-B",
    8:  "Red PD2-B",
    3:  "IR  PD1",
    9:  "IR  PD2",
    4:  "IR  PD1-B",
    10: "IR  PD2-B",
    5:  "Grn PD1",
    11: "Grn PD2",
    6:  "Grn PD1-B",
    12: "Grn PD2-B",
]

struct DataPoint: Identifiable {
    let id   = UUID()
    let x: Int      // rolling sample index (x-axis)
    let y: Double   // ADC count (y-axis)
}

class BluetoothManager: ObservableObject {
    private let dataSource: PPGDataSource

    @Published var isConnected   = false
    @Published var statusMessage = "Not connected"

    // channelKey → rolling buffer of DataPoints
    @Published var channels: [Int: [DataPoint]] = [:]
    private var counters: [Int: Int] = [:]   // channelKey → next x value

    private var lineBuffer = ""              // accumulates partial lines
    private let maxPoints  = 200             // rolling window size

    // Defaults to mock replay so the app is useful with no hardware at all.
    // Pass BLEDataSource() here once real-device testing is underway.
    init(dataSource: PPGDataSource = MockReplayDataSource()) {
        self.dataSource = dataSource

        self.dataSource.onLine = { [weak self] line in
            self?.receive(line)
        }
        self.dataSource.onStatusChange = { [weak self] connected, message in
            DispatchQueue.main.async {
                self?.isConnected = connected
                self?.statusMessage = message
            }
        }
        self.dataSource.start()
    }

    func disconnect() {
        dataSource.stop()
    }

    // MARK: - Parsing

    private func receive(_ text: String) {
        lineBuffer += text
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()   // last chunk may be incomplete
        for line in lines {
            parseLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func parseLine(_ line: String) {
        guard !line.isEmpty else { return }
        let parts = line.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 3 else { return }

        let tag     = parts[0]
        let value   = Double(parts[1])
        let slotIdx = parts[2]

        // Determine a stable channel key
        let key: Int
        if slotIdx >= 200 {
            key = slotIdx               // IMU: 200, 201, 202
        } else if slotIdx >= 128 {
            key = tag + 200             // U2 PPG (offset to avoid colliding with U10 tags)
        } else {
            key = tag                   // U10 PPG: use FIFO tag (1-12) as identifier
        }

        let x     = counters[key, default: 0]
        let point = DataPoint(x: x, y: value)

        var buf = channels[key, default: []]
        buf.append(point)
        if buf.count > maxPoints { buf.removeFirst(buf.count - maxPoints) }

        DispatchQueue.main.async {
            self.channels[key] = buf
            self.counters[key]  = x + 1
        }
    }
}
