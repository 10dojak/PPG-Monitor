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
    private var scanTimeoutTimer: Timer?
    private var notifCount = 0   // diagnostics: count of raw BLE notifications received

    // Set by stop(), so didDisconnectPeripheral can tell "user tapped
    // Disconnect" apart from "device dropped unexpectedly" — without this,
    // the auto-reconnect below would immediately undo a deliberate
    // disconnect.
    private var userInitiatedDisconnect = false

    // How long to scan before telling the user nothing was found, instead of
    // sitting on "Scanning..." forever (checklist §1: clear error message
    // when the device can't be found).
    private let scanTimeoutSeconds: TimeInterval = 15

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        userInitiatedDisconnect = false
        guard centralManager.state == .poweredOn else { return }
        onStatusChange?(false, "Scanning...")
        // Scan unfiltered and match by name. The firmware advertises the NUS
        // 128-bit UUID in the *scan response* (sd[]), not the primary
        // advertising payload (ad[]) — a `withServices:` filter can miss it
        // on iOS, which would look exactly like "device not found."
        print("[rawstream] scan start (unfiltered, matching name \(DEVICE_NAME))")
        centralManager.scanForPeripherals(withServices: nil,
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: scanTimeoutSeconds, repeats: false) { [weak self] _ in
            self?.handleScanTimeout()
        }
    }

    func stop() {
        userInitiatedDisconnect = true
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        } else {
            centralManager.stopScan()
            onStatusChange?(false, "Disconnected")
        }
    }

    private func handleScanTimeout() {
        guard peripheral == nil else { return }   // already found one, timeout is moot
        centralManager.stopScan()
        onStatusChange?(false, "Device not found — retrying…")
        print("[rawstream] scan timeout — retrying in 3s")
        // Keep retrying instead of giving up: after the app is killed and
        // relaunched, the board can hold the stale link for its supervision
        // timeout (~30s) before it re-advertises.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.peripheral == nil, !self.userInitiatedDisconnect else { return }
            self.start()
        }
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
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        print("[rawstream] discovered name=\(String(describing: peripheral.name)) advName=\(String(describing: advName)) rssi=\(RSSI) svc=\(String(describing: advertisementData[CBAdvertisementDataServiceUUIDsKey]))")

        // Match on either the GAP name or the advertised local name.
        guard peripheral.name == DEVICE_NAME || advName == DEVICE_NAME else { return }

        print("[rawstream] MATCH \(peripheral.name ?? advName ?? "unknown") — connecting")
        self.peripheral = peripheral
        centralManager.stopScan()
        centralManager.connect(peripheral)
        onStatusChange?(false, "Connecting to \(peripheral.name ?? "device")…")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        scanTimeoutTimer?.invalidate()
        onStatusChange?(true, "Connected to \(peripheral.name ?? "device")")
        peripheral.delegate = self
        peripheral.discoverServices([NUS_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        guard !userInitiatedDisconnect else {
            onStatusChange?(false, "Disconnected")
            return
        }
        onStatusChange?(false, "Disconnected — scanning…")
        start()
    }

    // Distinct from didDisconnectPeripheral: this fires when the connection
    // attempt itself never succeeds (vs. connecting, then later dropping).
    // Without this, a failed connect() left the app stuck on "Connecting
    // to X…" forever with no error and no retry.
    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        onStatusChange?(false, "Couldn't connect to \(peripheral.name ?? "device") — retrying…")
        start()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEDataSource: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            // Connected, but the device didn't expose the NUS service we
            // asked for — was silently a no-op before, leaving the app
            // stuck on "Connected" with no data ever arriving and no
            // explanation why. Disconnecting (not user-initiated) reuses
            // the existing auto-retry path via didDisconnectPeripheral.
            onStatusChange?(false, "Device didn't expose the expected service — retrying…")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        for svc in services {
            peripheral.discoverCharacteristics([NUS_TX_CHARACTERISTIC], for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let txChar = service.characteristics?.first(where: { $0.uuid == NUS_TX_CHARACTERISTIC }) else {
            guard error == nil, service.uuid == NUS_SERVICE_UUID else { return }
            onStatusChange?(false, "Device didn't expose the expected data channel — retrying…")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: txChar)
        print("[rawstream] subscribed to NUS TX \(txChar.uuid); notifying=\(txChar.isNotifying)")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        print("[rawstream] notifyState uuid=\(characteristic.uuid) isNotifying=\(characteristic.isNotifying) err=\(String(describing: error))")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        notifCount += 1
        let data = characteristic.value
        if notifCount <= 400 {
            let hex = (data ?? Data()).map { String(format: "%02x", $0) }.joined(separator: " ")
            let utf8 = data.flatMap { String(data: $0, encoding: .utf8) }
            print("[rawstream] notif #\(notifCount) len=\(data?.count ?? -1) err=\(String(describing: error)) utf8=\(String(reflecting: utf8 ?? "<non-utf8>")) hex=[\(hex)]")
        }
        guard let data, let text = String(data: data, encoding: .utf8) else { return }
        onLine?(text)
    }
}
