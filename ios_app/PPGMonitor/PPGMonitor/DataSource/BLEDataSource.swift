//
//  BLEDataSource.swift
//  PPGMonitor
//
import Foundation
import CoreBluetooth

private let NUS_SERVICE_UUID      = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let NUS_TX_CHARACTERISTIC = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
private let DEVICE_NAME           = "PPG_DK_2026A"

final class BLEDataSource: NSObject, PPGDataSource {
    var onLine: ((String) -> Void)?
    var onStatusChange: ((Bool, String) -> Void)?
    
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func start() {
        guard centralManager.state == .poweredOn else { return }
        onStatusChange?(false, "Scanning...")
        centralManager.scanForPeripherals(withServices: [NUS_SERVICE_UUID])
    }

    func stop() {
        if let p = peripheral { centralManager.cancelPeripheralConnection(p) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEDataSource: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            onStatusChange?(false, "Bluetooth ready")
            start()
        } else {
            onStatusChange?(false, "Bluetooth unavailable")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // Filter by device name, not just service UUID — don't connect to
        // just any peripheral that happens to advertise the NUS service.
        guard peripheral.name == DEVICE_NAME else { return }

        print("Found: \(peripheral.name ?? "unknown")")
        self.peripheral = peripheral
        centralManager.stopScan()
        centralManager.connect(peripheral)
        onStatusChange?(false, "Connecting to \(peripheral.name ?? "device")…")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onStatusChange?(true, "Connected to \(peripheral.name ?? "device")")
        peripheral.delegate = self
        peripheral.discoverServices([NUS_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        onStatusChange?(false, "Disconnected — scanning…")
        start()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEDataSource: CBPeripheralDelegate {
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
        onLine?(text)
    }
}
