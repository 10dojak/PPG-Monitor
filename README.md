# PPG Monitor

**Last updated July 2026**

A full-stack photoplethysmography (PPG) system for the Proto2403 custom board, including embedded firmware, a web-based monitor, and a native iOS app. Streams live optical and IMU data over Bluetooth Low Energy (BLE).

---

## Hardware

- **Board:** Proto2403 (nRF52840 / ISP1807-LR)
- **Optical sensors:** 2× SFH 7016 packages — each contains Red (660nm), IR (880nm), and Green (530nm) LEDs plus 2 photodiodes (4 photodiodes total)
- **PPG ICs:** 2× MAX86141
  - U10 (primary, CSB1 = P0.17) — controls LED4 sensor package
  - U2 (secondary, CSB2 = P0.27) — controls LED1 sensor package via MAX4783 analog mux
- **Mux:** MAX4783 — routes U2's 3 LED drivers between both sensor packages; controlled automatically by U2's GPIO2 pin in sync with the LED sequencer
- **IMU:** LSM6DSOTR (accelerometer, ±2g @ 26 Hz)
- **BLE stack:** Zephyr RTOS / NCS v2.9.0, Nordic UART Service (NUS)

---

## Repository Structure

```
PPG-Monitor/
├── src/
│   ├── main.c               # BLE/NUS streaming, IMU polling, main loop
│   ├── max86140_spi.c       # MAX86141 SPI driver and chip configuration
│   └── max86140_spi.h       # Header for SPI driver
├── CMakeLists.txt           # Zephyr build system
├── prj.conf                 # Kconfig project configuration
├── app.overlay              # Devicetree overlay for Proto2403 pins
├── Kconfig                  # Kconfig definitions
├── Kconfig.sysbuild         # Sysbuild Kconfig
├── ppg_monitor.html         # Web BLE monitor (Chrome on desktop/Android)
└── ios_app/
    └── PPGMonitor/                       # Xcode project (PPGMonitor.xcodeproj)
        ├── PPGMonitor/
        │   ├── PPGMonitorApp.swift       # App entry point
        │   ├── ContentView.swift         # Tab layout, toolbar, top-level state
        │   ├── BluetoothManager.swift    # Owns a PPGDataSource, publishes parsed/display data + HR/SpO2
        │   ├── DataSource/               # PPGDataSource protocol + BLEDataSource / MockReplayDataSource
        │   ├── Parsing/PacketParser.swift    # Wire-format line -> ParsedSample
        │   ├── Models/                   # ParsedSample, PPGDataset (24-channel table), SessionMetadata
        │   ├── Session/                  # SessionController (state machine), SessionRecorder (CSV/JSON writer)
        │   ├── Views/                    # ParticipantEntryView, RecordingControlsView, MetricCardsView,
        │   │                             # WaveformChartView, ChannelSelectView, HeatmapView, AccelView, BadgeView
        │   └── Mock/sample_session.txt   # Real BLE capture used by MockReplayDataSource
        ├── PPGMonitorTests/              # Unit tests (Swift Testing) — parser, recorder, thread-safety
        └── PPGMonitorUITests/            # XCUITest — drives the full recording flow, screenshots each step
```

---

## Firmware

### Building

Requires [nRF Connect SDK v2.9.0](https://developer.nordicsemi.com/nRF_Connect_SDK/doc/latest/nrf/installation.html).

```bash
west build -b isp1807_lr -- -DBOARD_ROOT=. 
west flash
```

### BLE Data Format

Data is streamed over the Nordic UART Service (NUS):
- **Service UUID:** `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- **TX Characteristic:** `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

Each line: `tag value slotIndex\r\n`

| Field | Description |
|---|---|
| `tag` | MAX86141 FIFO tag (1–12) — identifies LED + photodiode combination |
| `value` | 19-bit ADC optical count |
| `slotIndex` | 0–11 = U10, 128–139 = U2, 200–202 = IMU (X/Y/Z) |

**Tag mapping (U10):**

| Tag | Channel |
|---|---|
| 1, 7 | Red · PD1 / PD2 |
| 3, 9 | IR · PD1 / PD2 |
| 5, 11 | Green · PD1 / PD2 |

**IMU encoding:** `encoded = accel_cm/s² + 20000` (offset to keep unsigned)

### Key Configuration (July 2026)

| Parameter | U10 | U2 |
|---|---|---|
| ADC Range | 8192 nA | 8192 nA |
| Integration Time | 58.7 µs | 58.7 µs |
| Sample Rate | 25 SPS | 25 SPS |
| Red LED current | 14.53 mA | 14.53 mA |
| IR LED current | 29.06 mA | 29.06 mA |
| Green LED current | 14.53 mA | 14.53 mA |
| Sequencer | 6-slot dual-PD scan | 3-slot mux-routed |

---

## Web Monitor (`ppg_monitor.html`)

A single-file HTML app using Web Bluetooth and Chart.js.

**Open in Chrome** (desktop or Android) — iOS Safari does not support Web Bluetooth. On iOS use the [Bluefy](https://apps.apple.com/app/bluefy-web-ble-browser/id1492822055) browser.

**Features:**
- Live waveform display for all 24 channels (4 PDs × 3 wavelengths × 2 LED positions)
- Heart rate estimation from IR peak detection
- SpO₂ estimation using ratio-of-ratios (Red/IR)
- 24-channel heatmap view
- Live accelerometer (X/Y/Z) chart
- Packet counter and sample rate display

---

## iOS App (`ios_app/PPGMonitor/`)

Native iPad app built with SwiftUI, Swift Charts, and Core Bluetooth. UI is a
panel-for-panel port of `ppg_monitor.html` — same 24 channels/colors, same
tabs (Waveforms / All 24 Channels / Acceleration), same HR/SpO2 math, same
recorder-bar behavior — not just visually, but functionally: toggling a
channel chip actually shows/hides that series, Start/Stop actually records
real samples to disk, Download CSV/Download JSON are the native equivalent
of the HTML's own two download buttons.

**Requirements:** Xcode 15+, iOS 16+. A physical iPad is only required to
test against real BLE hardware — the whole app, including a full recording,
also runs against mock data (`Mock/sample_session.txt`, a real capture with
zero IMU samples — see `MockReplayDataSource.swift` for how it interleaves a
synthetic accel signal to still exercise that path) in the Simulator with no
device at all.

**Build & run:**
```bash
cd ios_app/PPGMonitor
open PPGMonitor.xcodeproj
# ⌘R in Xcode, or from the command line:
xcodebuild -project PPGMonitor.xcodeproj -scheme PPGMonitor \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```
Data source defaults automatically: real `BLEDataSource` on a physical
device, `MockReplayDataSource` in Simulator (which has no Bluetooth radio to
test against). A Settings toggle (gear icon, top-right toolbar) switches
between the two at runtime — no source edit or rebuild needed.

On a machine other than the original developer's, Xcode's automatic signing
will prompt to select a different Apple Developer Team the first time the
project is opened (the project's `DEVELOPMENT_TEAM` is bound to one
specific account) — a one-time, one-click step, not a code change.

**Run the tests:**
```bash
xcodebuild test -project PPGMonitor.xcodeproj -scheme PPGMonitor \
  -destination 'platform=iOS Simulator,name=<a simulator name>'
```
`PPGMonitorTests` covers packet parsing (including corrupted/malformed
input), the recording pipeline end-to-end (real files asserted on disk, not
mocked), crash-safety (data written before an unclean shutdown survives),
and thread-safety. `PPGMonitorUITests` drives the actual participant-entry →
record → stop → tab-switching flow via `XCUIApplication` and screenshots
each step.

**Exported data format** (`Documents/Sessions/{participantID}_{sessionID}_{timestamp}/`):

A single file, **`session.csv`** — no separate JSON, no separate "wide"
variant. One export button, one file to keep track of.

**Layout:** a `#`-prefixed comment block (participant/session identity +
fixed acquisition settings, written at `start()`), a normal CSV header row
naming every column, data rows, then a second `#`-prefixed comment block
(end-of-recording stats, appended at `close()`). Both comment blocks are
skipped automatically by `pandas.read_csv(path, comment='#')` — no manual
line-skipping or a second file to open — while still being plain text anyone
can read by eye:

```
# PPG Monitor session export
# participantID: phoebeTest
# sessionID: abc123
# startTime: 2026-08-26T15:00:00.000Z
# nominalPPGSampleRateHz: 25.0
# adcRangeNanoamps: 8192.0
# ... (full Key Configuration table, see below)
# accelEncoding: raw = (acceleration_m/s^2 * 100) + 20000 -- decode with (raw - 20000) / 100
# rowCadenceSeconds: 0.2 -- one row per ~200ms cycle; each column carries forward its last known value until it next updates
# columns: timestamp (ISO 8601, wall-clock receive time -- the wire format has no on-device timestamp), then the 24 PPG channels [chip tagN], then Accel X/Y/Z [imu slotIdx]
timestamp,IR·LED1 PD1 [u10 tag3],IR·LED1 PD2 [u10 tag9],...,Accel X [imu 200],Accel Y [imu 201],Accel Z [imu 202]
2026-08-26T15:00:00.101Z,481,512,...,20050,19980,20010
...
# endTime: 2026-08-26T15:05:00.000Z
# measuredPPGSampleRateHz: 24.6
# measuredAccelSampleRateHz: 25.1
# finalHeartRateBPM: 72
# finalSpo2Percent: 98
```

**28 columns, self-labeled:** `timestamp` + the 24 PPG channels + `Accel
X/Y/Z`. Every PPG column name carries its own chip/tag right in the header
(`IR·LED1 PD1 [u10 tag3]`) — no separate legend to cross-reference to know
which column is which channel. `timestamp` is ISO 8601 (e.g.
`2026-08-26T15:00:00.101Z`), not a raw Unix epoch number — reads
unambiguously by eye, and both pandas and MATLAB parse it directly.

**What's *not* in this file, on purpose:**
- **Gyro** — defined in the wire protocol, but the checklist's §4 asks for
  accelerometer only, and gyro has never appeared in any real capture.
- **The wake-up event bitmask** (`slotIdx` 220, bit0/1/2 = X/Y/Z motion
  triggered) — this is a firmware motion-interrupt flag, not a scientific
  measurement someone would analyze in Python/MATLAB. It's also currently
  disabled on the `peripheral_uart_test` firmware branch. If a "was there
  motion" column is ever wanted, deriving one from the accelerometer signal
  (the app already computes a motion threshold for the live "Still" badge)
  is more meaningful than exposing a raw hardware interrupt bit.

Both are easy to add as extra columns later if that changes — the row-write
logic already branches on `sample.stream`, see `SessionRecorder.append(_:)`.

**Row cadence, and why there's no near-duplicate row per sample:** the 24
PPG channels + 3 accel channels each update on their own independent
schedule (not all at once), so naively writing one row per incoming sample
would mean ~27 largely-identical rows for every real "reading." Instead,
samples are batched into ~200ms buckets — matching the firmware's own
per-cycle transmit tick — and one row is flushed per bucket, carrying
forward each column's last-known value. A crash mid-recording can only ever
lose the one bucket that hadn't been flushed yet when it happened; everything
before that is already durable on disk.

**Tunable thresholds** (all in `BluetoothManager.swift` unless noted):
HR normal range 50–110 BPM, SpO2 normal ≥95%, motion-detected deviation from
1g >0.5 m/s² (`AccelView.swift`), signal quality Good/Fair/Poor error-rate
cutoffs at 2%/10% (`signalQuality`), heatmap color intensity max value
`HEAT_MAX`-equivalent 300,000 (`Models/PPGDataset.swift`), BLE scan timeout
15s (`BLEDataSource.swift`), `session.csv` row-batching interval 0.2s
(`rowIntervalSeconds`, `SessionRecorder.swift`).

---

## Device Name

The firmware advertises as: **`PPG_DK_2026A`**
