//
//  BluetoothManager.swift
//  PPG Monitor
//

import Foundation
import CoreBluetooth
import Combine

let NUS_SERVICE_UUID      = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let NUS_TX_CHARACTERISTIC = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

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

class BluetoothManager: NSObject, ObservableObject {
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?

    @Published var isConnected   = false
    @Published var statusMessage = "Not connected"

    // channelKey → rolling buffer of DataPoints
    @Published var channels: [Int: [DataPoint]] = [:]
    private var counters: [Int: Int] = [:]   // channelKey → next x value

    private var lineBuffer = ""              // accumulates partial BLE packets
    private let maxPoints  = 200             // rolling window size

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        statusMessage = "Scanning..."
        centralManager.scanForPeripherals(withServices: [NUS_SERVICE_UUID])
    }

    func disconnect() {
        if let p = peripheral { centralManager.cancelPeripheralConnection(p) }
    }

    // MARK: - Parsing

    fileprivate func receive(_ text: String) {
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

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            if central.state == .poweredOn {
                self.statusMessage = "Bluetooth ready"
                self.startScanning()
            } else {
                self.statusMessage = "Bluetooth unavailable"
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        print("Found: \(peripheral.name ?? "unknown")")
        self.peripheral = peripheral
        centralManager.stopScan()
        centralManager.connect(peripheral)
        DispatchQueue.main.async {
            self.statusMessage = "Connecting to \(peripheral.name ?? "device")…"
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            self.isConnected   = true
            self.statusMessage = "Connected to \(peripheral.name ?? "device")"
        }
        peripheral.delegate = self
        peripheral.discoverServices([NUS_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        DispatchQueue.main.async {
            self.isConnected   = false
            self.statusMessage = "Disconnected — scanning…"
            self.channels      = [:]
        }
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([NUS_TX_CHARACTERISTIC], for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == NUS_TX_CHARACTERISTIC {
                peripheral.setNotifyValue(true, for: char)
                print("Subscribed to NUS TX")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }
        receive(text)
    }
}
