# PPG Monitor iOS App — Running & Testing

A guide for running the current iOS app and using it to verify firmware changes
on the wire. Companion to the top-level `README.md`; this file focuses on setup,
the BLE bring-up state, and the on-device diagnostics.

---

## 1. Where the code is

- **Repo:** `https://github.com/10dojak/PPG-Monitor`
- **Branch:** **`ios-dev`** — this is the app branch. `main` is a stale July
  snapshot and the repo's default HEAD points at a firmware branch
  (`peripheral_uart_test`), so a plain `git clone` will *not* put you on the app
  code. You must `git checkout ios-dev`.
- **App location in the tree:** `ios_app/PPGMonitor/` (Xcode project:
  `PPGMonitor.xcodeproj`).

> **Sync status (read before cloning):** the newest BLE bring-up work — the
> lenient packet parser, the unfiltered-scan / name-match fix, the on-device
> "Raw data stream" diagnostics screen, and the structured logging — is being
> pushed to `ios-dev` now. You have the current version once `git log` on
> `ios-dev` shows a commit *newer than* `1db5244 "Consolidate CSV export…"`.
> If you only see `1db5244` at the tip, wait for the push — the version under
> it has the old strict parser that produced 100%-parse-error runs against the
> board.

```bash
git clone https://github.com/10dojak/PPG-Monitor.git
cd PPG-Monitor
git checkout ios-dev
git pull
```

---

## 2. Prerequisites

| Need | Version | Notes |
|---|---|---|
| macOS | 14.5+ | built/tested on 14.7.4 |
| Xcode | **16.0+** (tested on 16.2) | Xcode 15 will not work — project deploys to iOS 18.2 and uses file-system-synchronized project groups |
| iPhone/iPad (real-hardware testing only) | **iOS 18.2+** | Simulator is fine for everything except real BLE |
| Apple ID / signing team | any | for putting the app on a physical device |

No CocoaPods, SPM, or Homebrew dependencies — the app uses only first-party
frameworks (SwiftUI, Swift Charts, Core Bluetooth).

---

## 3. Open and sign

```bash
cd ios_app/PPGMonitor
open PPGMonitor.xcodeproj
```

First time on a new machine:

1. Select the **PPGMonitor** target → **Signing & Capabilities**.
2. Change **Team** from the baked-in value (`6S5692CPD8`) to your own Apple ID /
   personal team. Xcode auto-manages the provisioning profile.
3. If the bundle id `com.tsaichenlo.PPGMonitor` collides with something already
   on your account, append a suffix (e.g. `com.tsaichenlo.PPGMonitor.<name>`).
4. This signing change is local — **do not commit it.**

Adding or pulling a `.swift` file needs no `.xcodeproj` edit — the project uses
synchronized groups, so files on disk are compiled automatically.

---

## 4. Run with no hardware (Simulator + mock replay)

The fastest way to see the whole app working end to end.

1. Scheme **PPGMonitor**, destination: any **iOS 18.2+** Simulator (an iPad
   model matches the primary layout best).
2. Run (⌘R).

In the Simulator there is no Bluetooth radio, so the app automatically uses
`MockReplayDataSource`, which replays `PPGMonitor/Mock/sample_session.txt` — a
real capture. You get live waveforms, HR/SpO₂, a full recording, and CSV export
without a board.

Command-line build:

```bash
xcodebuild -project PPGMonitor.xcodeproj -scheme PPGMonitor \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=<a simulator from `xcrun simctl list devices`>' \
  build
```

---

## 5. Run against real `PPG_DK_2026A` hardware

1. Connect a physical iPhone/iPad (iOS 18.2+), pick it as the run destination,
   ⌘R. On the device, trust the developer certificate if prompted
   (**Settings → General → VPN & Device Management**).
2. Grant the Bluetooth permission prompt on first launch.
3. Open **Settings** (gear icon, top-right toolbar) and make sure
   **"Use mock data" is OFF**. On a physical device it already defaults to real
   BLE, but confirm.
4. Power the board — it must be advertising as **`PPG_DK_2026A`**.
5. The app scans **unfiltered** and matches on the GAP name *or* the advertised
   local name, then connects to the Nordic UART Service
   (`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`), subscribes to the TX characteristic
   (`6E400003-…`), and starts plotting.

**If it doesn't connect immediately:** the scan auto-retries every 3 s. After
the app is killed and relaunched, the board can hold the stale link for its
~30 s supervision timeout before it re-advertises — just wait it out; no need to
power-cycle.

> The scan is unfiltered on purpose: the firmware advertises the 128-bit NUS
> UUID in the **scan response**, not the primary advertising payload, and a
> Core Bluetooth `withServices:` scan filter can miss it on iOS — which looks
> exactly like "device not found."

---

## 6. Diagnosing the BLE stream while you change firmware

Use this to confirm what a firmware change actually puts on the wire.

### On the device

**Settings → Raw data stream.** Shows:

- the text coming off BLE **verbatim** (real framing — a trailing `\r` is
  visible),
- live parse counters: U10 samples, U2 samples, parse errors, error rate,
  samples/sec,
- the first ~60 lines that **failed to parse**, verbatim,
- **Prepare capture file** → Share sheet → AirDrop or save the raw stream to a
  `.txt`. Drop that file in as
  `ios_app/PPGMonitor/PPGMonitor/Mock/sample_session.txt` to replay your exact
  capture through the mock source at a desk.

### From a Mac

With the device connected (or on the same network):

```bash
log stream --style compact \
  --predicate 'subsystem == "com.tsaichenlo.PPGMonitor"'
```

Or just watch the Xcode console for `[rawstream] …` lines: RX chunks with byte
count + hex + UTF-8, every `PARSE-FAIL` line verbatim, and the first 60 parsed
samples with chip / tag / value / slot.

---

## 7. Wire format the parser accepts

The parser now mirrors `ppg_monitor.html`'s leniency (the previous
triplet-only parser discarded every non-triplet line and produced
100%-parse-error runs against the board):

- Split on any run of whitespace.
- `tag value slotIdx` — the normal line. **Trailing junk after the third token
  is ignored.**
- `tag value` — a 2-token line with no `slotIdx` is accepted as a **U10 PPG**
  sample **only if `tag` is 1–12** (older / pre-`slotIdx` transmit format).
- `slotIdx` map: `0–11` U10 PPG · `128–139` U2 PPG · `200–202` accel X/Y/Z ·
  `210–212` gyro X/Y/Z · `220` wake-up bitmask.
- An **explicit** `slotIdx` that maps to nothing known (e.g. `999`) is
  **rejected**, not coerced.
- IMU value encoding: accel `raw = (m/s² × 100) + 20000`; gyro
  `raw = (mrad/s) + 50000`.
- There is **no on-device timestamp** on the wire — every timestamp in an
  export is receive-time (`Date()` on arrival).

---

## 8. Run the tests

```bash
xcodebuild test -project PPGMonitor.xcodeproj -scheme PPGMonitor \
  -destination 'platform=iOS Simulator,name=<a simulator name>'
```

- **PPGMonitorTests** — packet parsing (including the new lenient cases and
  malformed input), the recording pipeline end to end (real files asserted on
  disk, not mocked), crash-safety (data written before an unclean shutdown
  survives), thread-safety.
- **PPGMonitorUITests** — drives the real participant-entry → record → stop →
  tab-switch flow via `XCUIApplication` and screenshots each step.

---

## 9. Where recordings land

On the device: **Files app → On My iPad → PPGMonitor →**
`Sessions/{participantID}_{sessionID}_{timestamp}/session.csv`.

One file per session: a `#`-prefixed comment block (participant/session identity
+ fixed acquisition settings), a normal CSV header row, data rows, then a second
`#`-comment block (end-of-recording stats). `pandas.read_csv(path, comment='#')`
reads it directly. 28 columns: `timestamp` (ISO 8601) + the 24 PPG channels
(each column header self-labels its chip/tag, e.g. `IR·LED1 PD1 [u10 tag3]`) +
Accel X/Y/Z.

---

## 10. Tunable thresholds

| Knob | Default | File |
|---|---|---|
| BLE scan timeout | 15 s | `BLEDataSource.swift` |
| Scan auto-retry interval | 3 s | `BLEDataSource.swift` |
| Raw-capture cap | 40,000 lines | `BluetoothManager.swift` |
| Parse-failure sample cap | 60 lines | `BluetoothManager.swift` |
| `session.csv` row-batch interval | 0.2 s | `SessionRecorder.swift` |
| HR normal range | 50–110 BPM | `BluetoothManager.swift` |
| SpO₂ normal | ≥ 95% | `BluetoothManager.swift` |
| Motion-detected deviation from 1g | > 0.5 m/s² | `AccelView.swift` |
