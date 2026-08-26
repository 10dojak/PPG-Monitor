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

`raw.csv` — one row per sample, streamed as it arrives (not buffered then
written, so a crash mid-recording only loses the last unflushed sample, not
the whole file). This is both the checklist's "raw PPG data" (the untouched
`value` column — 19-bit ADC counts / offset-encoded IMU, byte-for-byte off
the wire) and its "processed PPG data" (`chip`/`stream`/`tag`/`slotIdx`
decoded from the wire's bare integers into identified, labeled channels) —
one file serves both, nothing is thrown away between the two. "Relevant
calculated metrics" (HR/SpO2) live separately in `metadata.json`, below.

| Column | Meaning |
|---|---|
| `timestamp` | Unix epoch seconds (`Double`) — wall-clock receive time, not on-device sample time (the wire format has no on-device timestamp) |
| `chip` | `u10` / `u2` / `imu` |
| `stream` | `ppg` / `accel` / `gyro` / `wakeup` |
| `tag` | MAX86141 FIFO tag (1–12), or `0` for all IMU streams |
| `value` | Raw wire value — 19-bit ADC count for PPG, offset-encoded for IMU (see `README`'s BLE Data Format section above) |
| `slotIdx` | 0–11 = U10, 128–139 = U2, 200–202 = accel X/Y/Z, 210–212 = gyro X/Y/Z, 220 = wake-up |

`metadata.json` — `participantID`, `sessionID`, `startTime`/`endTime` (Unix
epoch seconds — matches `raw.csv`'s convention, *not* `JSONEncoder`'s
default of seconds-since-2001), `measuredSampleRate` (all streams combined,
actual observed rate, not the 25 SPS spec), `measuredPPGSampleRate` /
`measuredAccelSampleRate` (same, broken out per stream so each can be
checked against its own spec independently), `acquisitionSettings` (fixed
hardware configuration this session was recorded under — ADC range,
integration time, LED currents, accel range/ODR — copied from the Key
Configuration table above so a session is self-describing without
cross-referencing the README), `finalHeartRateBPM`/`finalSpo2Percent` (last
computed values at stop time, `null` if never enough data to compute).
Written twice — once at `start()` with `endTime: null` for crash safety,
again at `close()` with final values.

**Tunable thresholds** (all in `BluetoothManager.swift` unless noted):
HR normal range 50–110 BPM, SpO2 normal ≥95%, motion-detected deviation from
1g >0.5 m/s² (`AccelView.swift`), signal quality Good/Fair/Poor error-rate
cutoffs at 2%/10% (`signalQuality`), heatmap color intensity max value
`HEAT_MAX`-equivalent 300,000 (`Models/PPGDataset.swift`), BLE scan timeout
15s (`BLEDataSource.swift`).

---

## Device Name

The firmware advertises as: **`PPG_DK_2026A`**
