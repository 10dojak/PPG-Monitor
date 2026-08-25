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

// Channel keys: U10 tags key display buffers directly by tag (1-12); U2 tags
// are offset by u2ChannelKeyOffset (see PPGDataset.swift); IMU data
// (slotIdx 200-222) keeps slotIdx as key.

struct DataPoint: Identifiable {
    let id   = UUID()
    let x: Int      // rolling sample index (x-axis)
    let y: Double   // ADC count (y-axis)
}

class BluetoothManager: ObservableObject {
    private var dataSource: PPGDataSource

    // Whether the currently active data source is MockReplayDataSource
    // (vs. real BLEDataSource) — drives the Settings toggle, and lets
    // switchDataSource(useMock:) know whether a switch is actually needed.
    @Published var isUsingMockData: Bool

    @Published var isConnected   = false
    @Published var statusMessage = "Not connected"

    // channelKey → rolling buffer of DataPoints
    @Published var channels: [Int: [DataPoint]] = [:]
    private var counters: [Int: Int] = [:]   // channelKey → next x value

    // Which of the 24 PPG datasets are currently toggled on (IR/LED1 group by default).
    @Published var datasetVisible: [Bool] = ppgDatasets.map { $0.groupIndex == 0 }

    // Packet/error counters, mirrors ppg_monitor.html's cntU10/cntU2/cntErr.
    @Published var cntU10 = 0
    @Published var cntU2  = 0
    @Published var cntErr = 0
    @Published var samplesPerSecond = 0

    // Signal-quality indicator (checklist §9) — neither BluetoothManager nor
    // ppg_monitor.html had one; this is a simple packet/error-rate heuristic
    // rather than real signal-processing (amplitude/AC-DC based), by design.
    enum SignalQuality: String {
        case none = "No Signal"
        case poor = "Poor"
        case fair = "Fair"
        case good = "Good"
    }

    var signalQuality: SignalQuality {
        let total = cntU10 + cntU2
        guard total > 0 else { return .none }
        guard cntU10 > 0, cntU2 > 0 else { return .poor }   // one chip silent
        let errorRate = Double(cntErr) / Double(total + cntErr)
        if errorRate > 0.10 { return .poor }
        if errorRate > 0.02 { return .fair }
        return .good
    }

    // HR / SpO2, computed the same way as ppg_monitor.html (detectPeak / updateSpO2).
    @Published var heartRateBPM: Int?
    @Published var hrInRange = true
    @Published var spo2Percent: Int?
    @Published var spo2InRange = true

    // Fires for every successfully parsed sample, independent of the display
    // buffers above — this is the feed SessionRecorder listens to.
    var onParsedSample: ((ParsedSample) -> Void)?

    private var lineBuffer = ""              // accumulates partial lines
    private let maxPoints  = 200             // rolling window size

    // Sample-rate bookkeeping
    private var totalPPGSamples = 0
    private var spsLastCount = 0
    private var spsLastTime = Date()

    // HR bookkeeping (IR·LED1 PD4, chip u2 tag 9)
    private var rollingIR: [Double] = []
    private var irPeakGapsMs: [Double] = []
    private var lastPeakTime: Date?
    private var prevIRValue: Double = 0
    private var prevIRDelta: Double = 0

    // SpO2 bookkeeping (adds Red·LED1 PD4, chip u2 tag 7)
    private var rollingRed: [Double] = []

    // No explicit dataSource -> real BLE on a physical device, mock replay
    // in Simulator (which has no real Bluetooth radio to connect through).
    // Pass an explicit dataSource (as the test suite does) to override this.
    init(dataSource: PPGDataSource? = nil) {
        let resolvedSource: PPGDataSource
        let usingMock: Bool
        if let dataSource {
            resolvedSource = dataSource
            usingMock = dataSource is MockReplayDataSource
        } else {
            #if targetEnvironment(simulator)
            resolvedSource = MockReplayDataSource()
            usingMock = true
            #else
            resolvedSource = BLEDataSource()
            usingMock = false
            #endif
        }
        self.dataSource = resolvedSource
        self.isUsingMockData = usingMock
        wire(resolvedSource)
        resolvedSource.start()
    }

    private func wire(_ source: PPGDataSource) {
        source.onLine = { [weak self] line in
            self?.receive(line)
        }
        source.onStatusChange = { [weak self] connected, message in
            DispatchQueue.main.async {
                self?.isConnected = connected
                self?.statusMessage = message
            }
        }
    }

    func disconnect() {
        dataSource.stop()
    }

    func reconnect() {
        dataSource.start()
    }

    // Swaps the live data source at runtime — e.g. from the Settings
    // toggle — so switching between mock and real BLE never requires a
    // rebuild. Stops the old source, clears all stream state (a half-mock,
    // half-real dataset would be meaningless), and starts the new one.
    func switchDataSource(useMock: Bool) {
        guard useMock != isUsingMockData else { return }
        dataSource.stop()
        resetStreamState()

        let newSource: PPGDataSource = useMock ? MockReplayDataSource() : BLEDataSource()
        dataSource = newSource
        isUsingMockData = useMock
        wire(newSource)
        newSource.start()
    }

    private func resetStreamState() {
        channels = [:]
        counters = [:]
        cntU10 = 0
        cntU2 = 0
        cntErr = 0
        samplesPerSecond = 0
        totalPPGSamples = 0
        spsLastCount = 0
        spsLastTime = Date()
        heartRateBPM = nil
        hrInRange = true
        spo2Percent = nil
        spo2InRange = true
        rollingIR = []
        rollingRed = []
        irPeakGapsMs = []
        lastPeakTime = nil
        prevIRValue = 0
        prevIRDelta = 0
        lineBuffer = ""
        isConnected = false
        statusMessage = "Not connected"
    }

    // MARK: - Parsing

    // Both PPGDataSource implementations happen to call onLine on the main
    // queue today (CBCentralManager(queue: nil) and MockReplayDataSource's
    // DispatchSourceTimer are both main-queue), which is what made it safe
    // for handle() to read `counters`/`channels` synchronously and only
    // defer the write. That's an unstated, fragile invariant — if onLine
    // ever fired from another thread, that read/write split races across
    // threads on the same Dictionary (confirmed: reproducibly segfaults in
    // Dictionary.subscript.getter under concurrent access in testing).
    // Hopping onto main here, once, up front, makes every subsequent read
    // and write in this call chain strictly serialized regardless of which
    // thread onLine actually fires from.
    private func receive(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.processReceivedText(text)
        }
    }

    private func processReceivedText(_ text: String) {
        lineBuffer += text
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()   // last chunk may be incomplete
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let sample = parseLine(trimmed) else {
                cntErr += 1
                continue
            }
            handle(sample)
        }
    }

    private func handle(_ sample: ParsedSample) {
        onParsedSample?(sample)

        // Determine a stable channel key for the display buffers.
        let key: Int
        switch sample.chip {
        case .imu:
            key = sample.slotIdx        // 200-202 accel, 210-212 gyro, 220 wakeup
        case .u2:
            key = sample.tag + u2ChannelKeyOffset   // clear of both U10 tags and IMU's raw-slotIdx keys
        case .u10:
            key = sample.tag            // FIFO tag (1-12) as identifier
        }

        let x     = counters[key, default: 0]
        let point = DataPoint(x: x, y: Double(sample.value))

        var buf = channels[key, default: []]
        buf.append(point)
        if buf.count > maxPoints { buf.removeFirst(buf.count - maxPoints) }

        channels[key] = buf
        counters[key]  = x + 1

        guard sample.chip != .imu else { return }   // PPG-only bookkeeping below

        if sample.chip == .u10 { cntU10 += 1 } else { cntU2 += 1 }
        totalPPGSamples += 1
        updateSampleRate()

        if sample.chip == .u2, sample.tag == 9 {
            let value = Double(sample.value)
            rollingIR.append(value)
            if rollingIR.count > 50 { rollingIR.removeFirst() }
            detectPeak(value: value, at: sample.receivedAt)
            updateSpO2()
        }
        if sample.chip == .u2, sample.tag == 7 {
            rollingRed.append(Double(sample.value))
            if rollingRed.count > 50 { rollingRed.removeFirst() }
        }
    }

    // MARK: - Sample rate

    private func updateSampleRate() {
        let now = Date()
        let elapsed = now.timeIntervalSince(spsLastTime)
        guard elapsed >= 1.0 else { return }
        let rate = Int((Double(totalPPGSamples - spsLastCount) / elapsed).rounded())
        spsLastCount = totalPPGSamples
        spsLastTime = now
        DispatchQueue.main.async { self.samplesPerSecond = rate }
    }

    // MARK: - Heart rate (peak detection on rolling IR)

    private func detectPeak(value: Double, at time: Date) {
        let delta = value - prevIRValue
        if prevIRDelta > 0, delta <= 0, prevIRValue > average(rollingIR) * 1.02 {
            if let last = lastPeakTime {
                let gapMs = time.timeIntervalSince(last) * 1000
                if gapMs > 300, gapMs < 2000 {
                    irPeakGapsMs.append(gapMs)
                    if irPeakGapsMs.count > 8 { irPeakGapsMs.removeFirst() }
                    let avgGap = irPeakGapsMs.reduce(0, +) / Double(irPeakGapsMs.count)
                    let bpm = Int((60000 / avgGap).rounded())
                    DispatchQueue.main.async {
                        self.heartRateBPM = bpm
                        self.hrInRange = bpm >= 50 && bpm <= 110
                    }
                }
            }
            lastPeakTime = time
        }
        prevIRDelta = delta
        prevIRValue = value
    }

    // MARK: - SpO2 (ratio-of-ratios)

    private func updateSpO2() {
        guard rollingRed.count >= 20, rollingIR.count >= 20 else { return }
        let acRed = stddev(rollingRed), dcRed = average(rollingRed)
        let acIR  = stddev(rollingIR),  dcIR  = average(rollingIR)
        guard dcRed != 0, dcIR != 0 else { return }
        let r = (acRed / dcRed) / (acIR / dcIR)
        let spo2 = min(100, max(85, Int((110 - 25 * r).rounded())))
        DispatchQueue.main.async {
            self.spo2Percent = spo2
            self.spo2InRange = spo2 >= 95
        }
    }

    private func average(_ arr: [Double]) -> Double {
        arr.isEmpty ? 0 : arr.reduce(0, +) / Double(arr.count)
    }

    private func stddev(_ arr: [Double]) -> Double {
        let m = average(arr)
        return (arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(arr.count)).squareRoot()
    }
}
