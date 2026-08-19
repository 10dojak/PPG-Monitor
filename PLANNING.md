# PPG Monitor iOS App — Objectives & Architecture

Scope: `ios_app/` only (BluetoothManager, ContentView, and the Xcode project that
doesn't exist yet). `src/`, `boards/`, firmware — reference only, not built or
fixed here. Deadline Sept 4, 2026.

---

## Objectives

**O1 — Ship an app that satisfies the checklist by Sept 4, developed hardware-free
until real BLE testing is unavoidable.**
- KR1: Xcode project exists and builds, with BluetoothManager wired to a
  swappable data source (mock replay or real BLE)
- KR2: Every Tier 1 checklist item (connection, acquisition, visualization,
  participant/session, recording workflow, storage/export, baseline error
  handling) works end-to-end against mock replay data
- KR3: Real BLE path validated against actual hardware once available, with no
  behavior change required in the UI/session/storage layers
- KR4: Exported CSV opens in Python with no manual cleanup — actually tested,
  not assumed
- KR5: Tier 2 (test pass + docs) done, Tier 3 (heatmap, live HR/SpO2 —
  reinstated by the "match the HTML exactly" decision) explicitly scoped in

**O2 — Don't let things outside the app's control turn into surprises at
acceptance.**
- KR1: Actual measured sample rate + firmware FIFO-drop behavior documented
  once Rutendo's logs are in hand
- KR2: Scope/timeline flagged to the professor, decision recorded here

---

## Architecture

### Why a data-source abstraction is the first real decision

Everything else follows from this: `BluetoothManager` should not be "the BLE
code." It should be "the parsed-sample publisher," fed by *something* that
hands it raw text lines. Today that's CoreBluetooth. For the next two weeks
it's a mock replay source. The existing code already has the right seam —
`receive(_ text: String)` is separate from the CoreBluetooth callback that
calls it — this just needs to be formalized into a protocol so both sources
can plug into the same pipeline:

```swift
protocol PPGDataSource {
    var onLine: ((String) -> Void)? { get set }
    func start()
    func stop()
}
```

- `BLEDataSource` — wraps CoreBluetooth, filters scan by device name
  (`PPG_DK_2026A`, not just service UUID — current code's bug), calls
  `onLine` from the characteristic-value-changed callback.
- `MockReplayDataSource` — reads one of Rutendo's captured logs (or a
  synthetic generator as a fallback before the logs arrive), replays lines on
  a timer that approximates real timing, calls `onLine` identically. Runs in
  the Simulator, no physical device needed.

`BluetoothManager` (or a renamed `PPGSessionController` — the "BLE" name stops
fitting once it owns session/recording logic too) owns one `PPGDataSource` at
a time and doesn't care which kind it is.

### Project layout

```
PPGMonitor.xcodeproj
PPGMonitor/
  App/                  entry point, Info.plist (NSBluetoothAlwaysUsageDescription)
  DataSource/           PPGDataSource protocol, BLEDataSource, MockReplayDataSource
  Parsing/              PacketParser (tag/value/slotIdx → typed sample), shared by both sources
  Models/                ParsedSample, ParticipantInfo, RecordingSession
  Session/               SessionController (state machine), SessionRecorder (storage)
  Storage/                CSV/JSON writer, file naming
  Views/
    ParticipantEntryView, RecordingControlsView,
    WaveformView, ChannelSelectView, AccelView, HeatmapView, MetricCardsView
  Mock/                   sample log files for MockReplayDataSource
```

### Parsing & data model

One `PacketParser` (used by both sources) turns a line into:

```swift
struct ParsedSample {
    let receivedAt: Date       // wall-clock on arrival — no on-device timestamp exists, document this
    let chip: Chip              // .u10 / .u2
    let stream: StreamType     // .ppg / .accel / .gyro / .wakeup
    let tag: Int
    let value: Int
    let slotIdx: Int
}
```

Two consumers of the parsed stream, kept separate on purpose:
- **Live display buffers** — bounded ring buffers per channel (~300–500
  samples, same idea as the HTML's `MAX_PTS`), feed the charts, discarded
  when the window rolls
- **Active recording** — every `ParsedSample` also goes to `SessionRecorder`
  if one is active, independent of what's currently on screen

This split is what prevents the "plot freezes on long recordings" failure
mode called out in the checklist — charts never hold more than the display
window, no matter how long the recording runs.

### Session / recording state machine

```
idle → participantEntry → ready → recording → stopped
```

- Start button only enabled once participant ID is captured (§5)
- Recording state gates navigation/exit warnings (§6)
- Disconnect/reconnect during `recording` must not touch the active
  `RecordingSession` — only the data source's connection resets, not session
  state (fixes the current code's "channels = [:] on disconnect" behavior,
  which would otherwise look like data loss to the user even though nothing
  was actually lost)

### Storage

Stream-to-disk, not buffer-in-memory-then-write. One folder per recording:

```
Documents/Sessions/{participantID}_{sessionID}_{yyyyMMdd-HHmmss}/
  raw.csv        appended line-by-line as samples arrive
  metadata.json  participant ID, session ID, start/end time, measured sample
                 rate, settings
```

Streaming append (open `FileHandle`, write as you go) means a crash mid-
recording loses at most the last unflushed buffer, not the whole session —
required for §10 ("existing recorded data protected if an error occurs") and
§11 (long-duration recording test).

Export = share sheet on the session folder (or zipped), not a custom upload
flow — simplest thing that satisfies §8.

### Visualization

Ported panel-by-panel from `ppg_monitor.html` (per the "match the HTML
exactly" call): multi-channel waveform with toggle chips, 24-slot heatmap,
accel X/Y/Z chart, HR/SpO2 cards using the same peak-detection and
ratio-of-ratios formulas. Swift Charts, bounded display buffers as above. No
code ports over from the HTML — only the visual spec and the math.

### Error handling

- CoreBluetooth state observer (`centralManagerDidUpdateState`) surfaces
  poweredOff/unauthorized as a real UI message, not silent failure
- Malformed lines increment a visible error counter instead of being silently
  dropped (current Swift parser just `return`s on a bad line — port the
  HTML's `cntErr` pattern)
- Sample-rate instrumentation (packets/sec, per stream) lives here too — this
  is what actually answers "is 25 SPS real" for §2/§11, independent of
  whatever the firmware is doing

---

## Build order

**Phase A — no hardware required.** Xcode project scaffold → data-source
protocol + MockReplayDataSource → parser/model layer → session state machine
→ storage/export → full UI build-out. All of this runs in Simulator against
mock data. This is Tier 1 + most of Tier 2.

**Phase B — needs a physical iPad + something to connect to.** BLEDataSource
wired in, device-name filtering, real reconnect/BT-off handling, and the
§11 test matrix (strong/weak signal, motion, repeated connect/disconnect) —
first against real hardware once available, or a stand-in BLE peripheral if
that unblocks earlier.

---

## Open items

- Waiting on Rutendo for 3 raw BLE logs (good/motion/poor contact, with
  timing) — unblocks Phase A with realistic data instead of synthetic
- Professor/Phoebe: confirm 90–120 hr scope (revised ~68–100 hr Tier 1+2, plus
  Tier 3 heatmap/HR/SpO2 now back in scope per "match HTML exactly") is
  acceptable for Sept 4, or agree on what moves
