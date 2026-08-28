# App Development Checklist — TODO

Mirrors the live checklist doc (owned by rutendo_jakachira@brown.edu, shared
2026-08-18) line-by-line. Deadline: **September 4, 2026**.

Check an item only once it's actually demonstrated working — not just coded.
Priority tiering / what to build first: see `PLANNING.md`.

## Progress log

**2026-08-19** — No checklist items checked yet, intentionally: everything
below depends on real hardware behavior, and nothing's been run against real
hardware yet. What's real so far:
- `PPGDataSource` protocol + `BLEDataSource`/`MockReplayDataSource` split
  built and compiling; app runs end-to-end against mock data (live 6-channel
  waveform, connection-status reporting)
- Two bugs fixed while doing this: BLE scan wasn't filtering by device name
  (`PPG_DK_2026A`); channel display was wiped on every disconnect
- Verified actual firmware throughput against Rutendo's real capture log:
  **4.2–4.3 SPS observed vs. 25 SPS spec** (§2 "sampling rate is correct" —
  currently failing, root cause identified and sent to Rutendo: per-sample
  `bt_nus_send()` calls flooding the BLE queue; fix is firmware-side, not
  something this app can address)
- Next: swap real capture data into the mock source, then build
  participant/session, recording workflow, storage/export

**2026-08-20** — Session/participant layer, built as a guided
concept-by-concept learning exercise (redone from scratch after an initial
pass, so the underlying ideas are actually understood, not just present in
the repo). Not wired into any screen yet — still not demonstrated running,
so nothing below is checklist-checkable either. What's real so far:
- `Models/ParsedSample.swift` — `Chip` (`.u10`/`.u2`/`.imu`) and
  `StreamType` (`.ppg`/`.accel`/`.gyro`/`.wakeup`) enums, plus the
  `ParsedSample` struct (`receivedAt`, `chip`, `stream`, `tag`, `value`,
  `slotIdx`)
- `Parsing/PacketParser.swift` — `parseLine(_:) -> ParsedSample?`, decodes
  one wire line by switching on `slotIdx`'s range; returns `nil` on
  anything malformed (wrong token count, unrecognized `slotIdx`)
- `Session/SessionController.swift` — `SessionState` enum
  (`participantEntry → ready → recording → stopped`) and
  `SessionController: ObservableObject` with guard-protected transition
  methods: `beginSession(participantID:)`, `startRecording()`,
  `stopRecording()`, `changeParticipant()` (refuses to run while
  `state == .recording`, so participants can't get mixed mid-session)
- Fixed the missing `NSBluetoothAlwaysUsageDescription` Info.plist key —
  would have crashed the app on the first real BLE scan attempt; kept from
  the earlier pass since it's an unrelated correctness fix, not part of the
  lesson
- Everything above builds clean (verified via `xcodebuild`) but
  **`ContentView` is still unchanged** — just the waveform grid, no
  participant entry or recording controls on screen yet
- `PPG_Monitor_Progress.pptx` (repo root) has the fuller build history as
  slides — July 6 pre-Xcode prototype → Aug 19 Xcode project creation →
  this session — plus a placeholder slide for a running-app screenshot
- Next: `Session/SessionRecorder.swift` (streams samples to `raw.csv` +
  `metadata.json`, one folder per recording), then
  `ParticipantEntryView`/`RecordingControlsView`, then wire
  `SessionController` into `ContentView` so the state machine actually
  drives a screen

**2026-08-25** — Built as a guided concept-by-concept learning exercise
(FileHandle, Codable, @State/Binding, @ObservedObject vs @StateObject,
Timer/.onReceive). Verified end-to-end via `xcodebuild` after every file plus
a Simulator screenshot of the participant-entry screen (Continue button
correctly disabled on empty input). Not yet checklist-checkable — recorded
data isn't real yet, see gap below. What's real so far:
- `Models/SessionMetadata.swift` — `Codable` struct (`participantID`,
  `sessionID`, `startTime`, `endTime: Date?`, `measuredSampleRate: Double?`)
- `Session/SessionRecorder.swift` — owns one recording's `raw.csv` (streamed
  via `FileHandle`, one line per sample, header written on `start()`) and
  `metadata.json` (written twice: once on `start()` with `endTime = nil` for
  crash safety, once on `close()` with final `endTime`/measured rate)
- `Views/ParticipantEntryView.swift` — text field + Continue button, calls
  `sessionController.beginSession(participantID:)`
- `Views/RecordingControlsView.swift` — Start/Stop buttons wired to
  `SessionController`, live elapsed-time display (recomputed from a fixed
  start `Date` each tick, not accumulated, so it can't drift)
- `ContentView.swift` now switches on `sessionController.state`:
  `.participantEntry` shows `ParticipantEntryView`, everything else shows
  the waveform grid + `RecordingControlsView`, with a participant-ID /
  "Change" control in the toolbar (disabled mid-recording, matching
  `changeParticipant()`'s own guard)
- **Known gap, not yet closed:** `SessionRecorder` isn't fed by real
  samples yet. `BluetoothManager.parseLine` still does its own inline
  parsing straight to `DataPoint`s for the live charts — it never goes
  through the shared `Parsing/PacketParser.swift` / `ParsedSample`, and
  there's no active-recorder hookup, so tapping Start/Stop today only
  drives the UI state and timer, nothing lands on disk yet. Next real step:
  give `BluetoothManager` a second output (parsed `ParsedSample`s, not just
  display `DataPoint`s) and have `SessionController` own/feed a
  `SessionRecorder` from that stream while `state == .recording`.

**2026-08-25 (cont'd)** — Closed the gap above, then rebuilt the UI to match
`ppg_monitor.html` panel-for-panel (per PLANNING.md's "match the HTML
exactly" call, Tier 3 reinstated) — same 24 channels/colors, same HR/SpO2
math, same heatmap, same recorder-bar semantics, not just the same look.
Verified via a real `xcodebuild test` UI-automation run (types into the
participant field, taps Start/Stop, switches all 3 tabs, screenshots each
step) plus an XCTest that drives mock data through the full pipeline and
asserts on the actual `raw.csv`/`metadata.json` written to disk — not just
"it compiles." What's real:
- `BluetoothManager` now parses every line through the shared
  `PacketParser`/`ParsedSample` (removed its own duplicate inline parser),
  publishes `onParsedSample` for `SessionController.recordSample(_:)` to
  consume, and tracks `cntU10`/`cntU2`/`cntErr`/measured sample rate, plus
  HR (peak-detection on U2 IR·LED1 PD4) and SpO2 (ratio-of-ratios) — ported
  formula-for-formula from the HTML
- `Models/PPGDataset.swift` — the 24-channel dataset table (label/chip/tag/
  color/dash), ported verbatim from the HTML's `DATASETS`, plus the heatmap
  tag-name tables and its color-intensity function
- `Views/MetricCardsView.swift`, `ChannelSelectView.swift`,
  `WaveformChartView.swift`, `HeatmapView.swift`, `AccelView.swift` — the 4
  metric cards, grouped toggle chips, 24-series waveform chart, 2×12-slot
  heatmap, and accel X/Y/Z panel; `ContentView` now runs a 3-tab layout
  (Waveforms / All 24 Channels / Acceleration) instead of the old fixed
  6-channel grid
- `SessionController` gained `recordedSampleCount`/`recordingStartedAt`/
  `lastSessionFolder`; `RecordingControlsView` now shows the same live
  status text as the HTML's recorder bar and a real `ShareLink` export
  (iOS's equivalent of the HTML's Download CSV button, per PLANNING.md's
  "export = share sheet" call)
- **Two real bugs found by actually running it, not just reading the
  diff:** (1) the elapsed-recording timer never ticked, because
  `Timer.publish(...).autoconnect()` was a plain `let` on a SwiftUI
  `View` struct — those structs get recreated on every parent redraw
  (here, up to ~100×/sec from streaming mock data), so the timer never
  survived long enough to fire; fixed by making it `@State`. (2) `u2`
  channel keys (`tag + 200`) collided with the IMU's raw-slotIdx keys
  (200-222) — `u2` tags 1/2/10/11/12 landed on the same dictionary keys as
  accel/gyro X/Y/Z, so the new Accel tab showed scrambled PPG counts
  mislabeled as hundreds-of-m/s² acceleration. Fixed by moving `u2` to a
  `+1000` offset that can't collide with either range. This was latent
  since the very first BLE-wiring session (2026-08-19) — just never visible
  before because nothing displayed slotIdx 200+ data until today.
- Ported two visual quirks from the HTML **as-is**, not "fixed": the
  heatmap's IR/Red/Green tag groupings for color intensity don't actually
  match the tag→wavelength labels used everywhere else in the same file,
  and the "IR Signal — 4 PDs" card is fed by tag 2/8 (which the tag-name
  tables label Red·LED2, not IR). Worth flagging to whoever owns the HTML —
  not changed here since the brief was to match it exactly.
- Not yet done: physical iPad hasn't been connected this session
  (`xcrun devicectl list devices` only sees a disconnected iPhone) — still
  waiting on that to confirm the real-device build/run/signing path before
  tomorrow's BLE hardware session
- `DataSource/MockReplayDataSource.swift` now interleaves a synthetic accel
  signal (small wobble + one motion burst) into Rutendo's real capture —
  the capture itself has zero IMU samples, so the accel parse → unit
  convert → magnitude/motion → chart path had never actually executed
  before this. Verified via UI-test screenshot: real converted units
  (~-0.1/-0.2/10.05 m/s², sane for a ~1g-resting device), correct magnitude,
  correct "Still" badge, and visible chart motion during the synthetic
  burst.

**2026-08-25 (cont'd again)** — Worked through the remaining checklist gaps
from the list above, all verified via `xcodebuild test` (not just built):
- §7 "relevant calculated metrics are saved" — `SessionMetadata` gained
  `finalHeartRateBPM`/`finalSpo2Percent`; `RecordingControlsView` passes
  `bt.heartRateBPM`/`bt.spo2Percent` into `stopRecording(...)` on Stop &
  Save. Verified by `mockRecordingWritesRealFiles` asserting both are
  non-nil after enough mock data has flowed.
- §2 "starting/stopping multiple sessions does not require restarting the
  app" — new test `backToBackRecordingsProduceSeparateFolders`: start,
  stop, start again on the same controller/BluetoothManager instances (no
  relaunch), confirms two distinct, non-empty session folders.
- §1 "clear error message when the device cannot be found" —
  `BLEDataSource` now times out a scan after 15s with no peripheral found
  and reports "Device not found — check PPG_DK_2026A is powered on and in
  range" instead of sitting on "Scanning..." forever.
- §6 "warns the user before exiting an active recording" — iOS has no way
  to actually block backgrounding/navigation, so this is the honest
  version: `ContentView` watches `scenePhase`, and shows an alert the
  moment the app starts to resign active (before it's actually hidden) if
  `state == .recording`.
- §8 "exported data can be opened and analyzed in Python/MATLAB without
  additional cleanup" — actually verified with `pandas.read_csv()` (no args
  needed, correct dtypes inferred, zero NaNs) against a file built from the
  exact format string `SessionRecorder.append()` uses. This caught a real
  bug: **`metadata.json`'s `startTime`/`endTime` were encoded as seconds
  since Apple's 2001 reference date** (JSONEncoder's default
  `.deferredToDate`), not Unix epoch like `raw.csv` — anyone doing
  `datetime.fromtimestamp(startTime)` in Python would silently get a date
  ~31 years wrong, no error, no hint anything was off. Fixed by setting
  `encoder.dateEncodingStrategy = .secondsSince1970` in
  `SessionRecorder.writeMetadata()`.
- Real robustness bug found while adding the back-to-back test: running
  the full test suite together (vs. one test at a time) made
  `MockReplayDataSource`'s `Timer.scheduledTimer` never fire — it schedules
  onto "whatever run loop is current," which isn't guaranteed to be
  actively spinning on whatever thread Swift Testing happens to run a test
  on. Replaced with an explicit `DispatchSourceTimer` on `.main`, which
  doesn't depend on that assumption. This is a genuine correctness fix, not
  a test-only workaround — the same implicit-run-loop assumption could bite
  in real app usage too, not just tests.
- Also added `UIBackgroundModes = bluetooth-central` to the Xcode project
  (both Debug/Release configs) so BLE data keeps flowing if the app is
  backgrounded mid-recording, instead of silently going quiet.
- Still open: none of these five items required real hardware, so nothing
  new is blocked on tomorrow's BLE session — the remaining checklist items
  (§3 long-duration/no-freeze testing, §11 strong/weak signal/motion
  testing, actual device connect/reconnect) all genuinely need the
  physical setup.

**2026-08-25 (cont'd once more)** — Swept the rest of the checklist for
anything still implementable without the iPad. §9's "signal-quality
indicator" had no HTML equivalent to port, so that one specific item was a
scope decision (kept to a simple packet/error-rate heuristic — Good/Fair/
Poor/No Signal — rather than inventing a real amplitude-based metric).
Everything else below was found, fixed, and proven via `xcodebuild test`:
- §1 "user can disconnect" / "can reconnect" — `BluetoothManager` gained
  `reconnect()`; toolbar now has a real Disconnect/Reconnect toggle.
  Surfaced a real bug in the process: `BLEDataSource`'s existing
  auto-reconnect-on-disconnect logic would have immediately undone a
  deliberate user disconnect. Fixed with a `userInitiatedDisconnect` flag
  so `didDisconnectPeripheral` only auto-rescans for *unexpected* drops.
- §9 signal-quality indicator — added per the packet/error-rate heuristic
  above, shown next to connection status (always visible, not buried in a
  tab).
- §10 "handles corrupted/incomplete packets" — added
  `parseLineRejectsCorruptedPackets`/`parseLineHandlesWellFormedPackets`.
  **Found a real parser bug**: `parseLine` checked token count *after*
  `compactMap`-filtering out non-numeric tokens, so `"3 481 3 garbage"`
  silently parsed as the clean 3-token line underneath it instead of being
  rejected — a corrupted line could pass through undetected. Fixed by
  checking raw token count first.
- §10 "existing recorded data protected if an error occurs" — added
  `dataWrittenBeforeUncleanShutdownSurvives`: writes samples via
  `SessionRecorder`, never calls `close()` (simulating a crash), confirms
  the data already on disk survives.
- §11 "saved data compared against real-time display" / "exported data
  checked against original" — added
  `recordedCsvValuesExactlyMatchInputSamples`: exact field-by-field
  round-trip check, not just row counts.
- §2 "no samples unintentionally dropped" — added
  `partialLinesSplitAcrossCallbacksAreNotDropped`, exercising the
  line-buffering logic directly via a `TestDataSource` test double (no
  timer/mock-replay pacing needed).
- §3/§11 "plot doesn't freeze" / "long-duration recording tested" — added
  `displayBuffersStayBoundedUnderHighThroughput` (20,000 synthetic samples
  fed synchronously). **This caught a real EXC_BAD_ACCESS crash**:
  `BluetoothManager.handle()` read `counters`/`channels` synchronously on
  whatever thread called it, but only wrote them via a deferred
  `DispatchQueue.main.async` — safe only because both current data sources
  happen to already call in on main, an unstated and fragile invariant.
  Under concurrent access this reproducibly segfaulted in
  `Dictionary.subscript.getter`. Fixed by hopping onto main once, at the
  top of `receive()`, so every read and write downstream is strictly
  serialized regardless of caller's thread — real hardening, not a
  test-only workaround, since BLE callback threading is exactly the kind
  of thing that can differ from mock behavior in edge cases.
- §12 README — confirmed genuinely stale (predates the Xcode project;
  describes a 2-file app, manual project setup, says BLE-in-Simulator isn't
  possible without mentioning the app now runs fully against mock data
  there). **Not yet rewritten** — flagging instead of silently doing it,
  since it's a meaningful rewrite and lower urgency than the correctness
  fixes above.
- Full suite: 9 unit tests + the UI screenshot flow, all passing.
  `tagToName` (dead code left over from the pre-Tier-3 6-channel grid) and
  a stale comment about the old `+200` u2 key offset were also cleaned up
  in `BluetoothManager.swift` while in there.

**2026-08-25 (real hardware)** — iPad connected, Developer Mode + device
trust set up, provisioning profile auto-registered the device, app built/
installed/launched successfully via `xcodebuild`/`devicectl` on physical
hardware for the first time. Checked GitHub's `peripheral_uart_test` branch
(1 commit ahead: `1ad49bc`) for firmware accel changes — confirmed the
actual accel wire encoding (`+20000` offset, cm/s² scale, slotIdx 200-202)
is unchanged, so our parsing is still correct. Worth flagging: that commit
temporarily disables wake-up events (slotIdx 220, commented out pending
accel/gyro-only testing) and adds IMU I2C "WHO_AM_I" debug probing both
0x6A/0x6B — reads like active troubleshooting of whether the IMU responds
at all. Worth confirming with Rutendo that real accel data is actually
flowing reliably before relying on it in testing.
- Corrected a scope drift from earlier: the "Share Session" single-button
  redesign didn't actually match `ppg_monitor.html`'s two separate
  Download CSV / Download JSON buttons — reverted to two buttons
  (`RecordingControlsView`) to match the HTML layout exactly, while keeping
  the earlier fix's intent (participant/session context traveling with the
  export): each share now copies its file to a temp path renamed after the
  session folder (e.g. `phoebeTest_abc123_..._2026....csv`) instead of
  sharing the generically-named `raw.csv`/`metadata.json` directly.
- Renamed the ambiguous "Change" participant-toolbar button to "Switch
  Participant."
- Added a real app icon — SwiftUI-rendered gradient background with a
  stylized pulse waveform, installed into `Assets.xcassets/AppIcon.
  appiconset` (single 1024×1024 image covering all three appearance
  variants — default/dark/tinted).
- All changes verified: full build + 10 unit tests passing, then installed
  and running live on Phoebe's physical iPad (not just Simulator).
- Changed app icon gradient from blue to teal/green per request.

**2026-08-25 (real BLE was never actually wired up)** — Caught a
significant gap while double-checking the connect flow against
`ppg_monitor.html`'s explicit "Live → Connect modal → Scan & Connect"
pattern: **`ContentView` always constructed `BluetoothManager()` with no
argument, which defaults to `MockReplayDataSource`.** Everything installed
and running on the physical iPad up to this point — including the earlier
"confirmed running on real hardware" checks — was streaming *mock* data,
not attempting a real BLE connection at all. There was no in-app way to
switch to `BLEDataSource`; it required editing source and rebuilding.
Fixed properly, not just patched:
- `BluetoothManager.init` now resolves its data source based on
  environment when none is explicitly passed: real `BLEDataSource` on a
  physical device, `MockReplayDataSource` in Simulator (which has no real
  Bluetooth radio to test against). `dataSource` is now a `var` (was
  `let`) with a new `switchDataSource(useMock:)` method that stops the old
  source, clears all stream state (channels, counters, HR/SpO2, error
  counts — a half-mock/half-real dataset would be meaningless), and starts
  the new one — all at runtime, no rebuild.
- Added `Views/SettingsView.swift` — a sheet reachable from a new gear icon
  in the toolbar, with a "Use Mock Data" toggle bound to the above. This is
  the actual answer to "is there supposed to be a connect screen": the
  HTML's explicit modal is about *initiating* a BLE scan by hand (its app
  has no mock mode, so that's its only path in); our app already
  auto-scans via `BLEDataSource`'s existing `centralManagerDidUpdateState`
  logic once BLE is selected, so the missing piece wasn't a connect
  button, it was a way to select real-BLE at all.
- Verified: build succeeds for both Simulator and the physical iPad, full
  10-test suite still passes (tests inject `TestDataSource`/mock
  explicitly, unaffected by the new environment-based default), then
  installed and launched on the iPad — this time actually attempting a
  real BLE scan by default, confirmed via the toolbar status text.
- This is the kind of thing that would have been a bad surprise walking
  into tomorrow's hardware session — worth double-checking status text on
  the iPad now reads a real scanning/connection state, not "Replaying mock
  data," before considering device-side setup done.

**2026-08-25 (final sweep)** — One more real gap plus the README:
- §5 — `changeParticipant()` wasn't clearing `lastSessionFolder`/
  `recordedSampleCount`, so switching participants left the *previous*
  participant's "Last saved..." summary showing in the recorder bar until
  the new one recorded something. Not actual data mixing, but stale state
  that could read as the wrong session. Fixed + new test
  `changeParticipantClearsPreviousSessionSummary`.
- README.md rewritten — it predated the Xcode project entirely (described
  a 2-file app, manual project creation, claimed BLE-in-Simulator wasn't
  possible without mentioning mock-data mode). Now has the real file
  structure, actual `xcodebuild build`/`test` commands, and — since §12
  explicitly wants it — a documented `raw.csv` column reference,
  `metadata.json` field reference, and a "Tunable thresholds" pointer
  (HR/SpO2 ranges, motion threshold, signal-quality cutoffs, heatmap max,
  BLE scan timeout) so changing any of those later doesn't require
  re-reading the source to find them.
- Full suite (10 unit tests + UI flow) passing, final build clean.
- Everything left on the checklist now genuinely needs the physical
  iPad + BLE hardware — nothing else identified as implementable/testable
  without it.

**2026-08-25 (one more pass)** — `BLEDataSource` had three genuinely missing
error paths that a code-review pass (not a test, since Simulator has no
real BLE to exercise this against) turned up:
- No `centralManager(_:didFailToConnect:error:)` handler at all — a failed
  connection attempt (distinct from a later unexpected disconnect, which
  *was* handled) left the app stuck on "Connecting to X…" forever, no
  error, no retry.
- `didDiscoverServices`/`didDiscoverCharacteristicsFor` ignored their
  `error` parameters and silently no-op'd if the expected service/
  characteristic wasn't found — same failure mode: "Connected" shown
  forever, zero data, zero explanation.

  All three now surface a clear status message and reuse the existing
  auto-retry path (disconnecting non-user-initiated triggers
  `didDisconnectPeripheral`'s auto-rescan) rather than adding a second retry
  mechanism. Build + full test suite (10 tests) still clean after this.
- This is a code-review-only fix — Simulator can't run real CoreBluetooth,
  so it's verified by build/logic review, not a runtime test, unlike
  everything else fixed today. Flagging that distinction explicitly.
- At this point I've been through every checklist section more than once.
  I don't have anything further to propose without hardware — the honest
  status is "done until the iPad connects," not "still searching."

**2026-08-25 (full checklist audit)** — Went through all 85 checklist lines
(§1-13) explicitly, one by one, classifying each as demonstrated / coded-
but-hardware-blocked / genuine gap, instead of only opportunistically
hunting for bugs. Found two more real gaps and one non-code item:
- §8 "participant/session information is included" — **the Share button
  only shared `raw.csv`**, not `metadata.json`. Participant ID/session ID/
  timestamps only ever lived in the folder name, which doesn't travel with
  a share — AirDrop or save-to-Files would hand someone a generic
  "raw.csv" with no participant/session context anywhere in it. Fixed:
  `RecordingControlsView` now shares both files together via
  `ShareLink(items:)`, renamed "Share CSV" → "Share Session" to reflect
  that.
- §3 "plot axes are appropriately labeled" — waveform and accel charts had
  `.chartXAxis(.hidden)`, so only the Y axis was ever labeled. Added
  labeled X-axis gridlines to both. Honest caveat: it labels the rolling
  sample index, not wall-clock time like the HTML's x-axis — `DataPoint`
  only ever stored an `Int` index, not a per-point timestamp, so matching
  the HTML exactly here would need a small data-model change. Flagged
  rather than silently doing a bigger change or overclaiming parity.
- §12 "latest working version is pushed to the repository" — **currently
  false**. Everything from today is uncommitted locally. Not committing/
  pushing without being asked — that's Phoebe's call, flagging it plainly.
- Full audit otherwise confirmed the checklist is in the state described
  across the entries above: everything demonstrable without hardware has
  been demonstrated (via the 10 unit tests + UI flow), everything else
  (§1 real BLE connect/discover/stability, §4 real accel sampling rate,
  §11 strong/weak-signal/motion/repeated-disconnect testing) is
  genuinely blocked on the physical iPad + device.
- Full suite still passing (10 unit tests + UI flow) after this round.

**2026-08-26 (lab session — testing & validation)** — In the lab today to run
the real-hardware test matrix planned yesterday (§1/§2/§4/§11 items that
needed the physical iPad + board — repeated BLE connect/disconnect,
Bluetooth-off handling, long-duration recording, strong/weak signal, motion,
measured PPG/accel sample rate vs. spec). Results land in this log as they
come in.

Two new backlog items raised during today's session:
- **Toggle top panels on/off** — implemented. A "Hide Metrics"/"Show Metrics"
  disclosure control now sits above `MetricCardsView` in `ContentView`,
  collapsing the metric-cards row (animated) to free up screen space for the
  waveform/heatmap/accel views during a live session. Verified by actually
  running it, not just building: extended `PPGMonitorUITests` to tap
  `app.buttons["Hide Metrics"]` then `app.buttons["Show Metrics"]` mid-flow —
  both resolved and tapped successfully in the real running app. Marked the
  chevron icon `.accessibilityHidden(true)` so the button's accessibility
  label stays exactly "Hide/Show Metrics" (an SF Symbol otherwise adds its
  own spoken description, e.g. "chevron up," to the label, which would have
  broken exact-string lookup in the UI test too).
- **Wide-format CSV, 24 columns (one per channel)** — implemented, then
  significantly reworked same day per feedback: the first pass added a
  *third* file (`raw_wide.csv`) alongside `raw.csv`/`metadata.json`, which
  was the wrong shape entirely — collapsed to **one file, one export
  button**. `SessionRecorder` now writes a single `session.csv`:
  participant/session/settings info lives in a `#`-prefixed comment header
  (written at `start()`), 28 columns (`timestamp` + 24 PPG channels + accel
  X/Y/Z, each column self-labeled with its chip/tag/slotIdx right in the
  header — no separate legend needed), then a `#`-prefixed comment footer
  (measured rates, HR/SpO2, written at `close()`). `pandas.read_csv(path,
  comment='#')` skips both comment blocks automatically — no second file, no
  manual line-skipping.
  - Timestamp switched from a raw Unix-epoch float to ISO 8601
    (`2026-08-26T15:00:00.101Z`) — was flagged as confusing to read; both
    pandas and MATLAB parse it directly, no cleanup lost.
  - Fixed real duplication, not just the file count: writing one row per
    incoming sample meant ~27 near-identical rows per actual "reading" (24
    PPG + 3 accel columns each updating independently). Rows are now batched
    into ~200ms buckets (matching the firmware's own per-cycle transmit
    tick) with last-known-value carried forward — one row per real cycle,
    not per sample. Caught a real ordering bug while building this: a
    sample's value was being merged into the running state *before* the
    previous bucket's row got flushed, which would have leaked the new
    sample's value into the wrong row. Fixed by flushing first, updating
    state after.
  - Re-confirmed the gyro/wake-up-bitmask exclusion decision (asked
    directly: "are we displaying the useful info, like binary and?") — still
    excluded, same reasoning as before (never in a real capture / not in
    checklist scope / disabled on `peripheral_uart_test`), now stated
    explicitly in the README rather than left implicit.
  - Verified twice, not just via unit tests: compiled `SessionRecorder` +
    its dependencies standalone (outside the simulator sandbox, real
    unsandboxed process) and ran a realistic mixed PPG/accel/gyro/wakeup/
    corrupted-line sequence through it, then loaded the real output file in
    pandas — confirmed both comment blocks are skipped automatically, dtypes
    are clean, timestamp parses to a real datetime, and all 20 metadata
    lines are still recoverable by anyone who wants them.
  - Tests rewritten for the new format:
    `sessionCsvCarriesForwardLastKnownValuesAndExcludesGyroWakeup` (replaces
    the two old fidelity tests — deterministic synthetic timestamps prove
    the exact carry-forward sequence row-by-row, and that gyro/wakeup add no
    columns at all) and a rewritten `dataWrittenBeforeUncleanShutdownSurvives`
    (proves the header block + completed buckets survive a simulated crash,
    only the one not-yet-flushed bucket is at risk — an explicit, accepted
    tradeoff, not a silent gap). `RecordingControlsView` now has exactly one
    "Download CSV" button. Full 10-test suite passing.

**2026-08-27 (lab session — first real-hardware run + UI fixes)** — Built and
installed on the physical iPad for the first time this session (found the
right `devicectl` destination ID after some trial and error — differs from
the one `xcodebuild -destination` lists). Two real bugs found and fixed
along the way, both verified on-device, not just in Simulator:
- **Dark panel bug** — `ParticipantEntryView` had no explicit background at
  all, so it rendered as solid black on a Dark Mode iPad; the rest of the
  UI is a mix of hardcoded light colors and adaptive system colors, so the
  overall look was a jarring half-light/half-dark mismatch depending on the
  device's Appearance setting. Since the whole UI is a fixed-palette port of
  `ppg_monitor.html` and was never designed with dark mode in mind, fixed by
  locking the app to light mode app-wide (`.preferredColorScheme(.light)` in
  `PPGMonitorApp.swift`) rather than patching individual view backgrounds.
- **Metric-cards toggle** — added a "Hide Metrics"/"Show Metrics" control
  above `MetricCardsView` to free up screen space for the live views during
  a session. Verified by actually tapping it via `PPGMonitorUITests`, not
  just building — also caught and fixed an accessibility-label bug in the
  process (an un-hidden SF Symbol was appending its own spoken description
  to the button's label, which would have broken both VoiceOver and the
  exact-string UI-test lookup).

**First real BLE connection — diagnosed, not yet fixed:** app connects to
`PPG_DK_2026A` successfully (status, discovery, connect all work as
designed), but signal quality reads "No Signal" — `0` U10 packets, `0` U2
packets, and a parse-error count climbing in real time (166 → 173 across a
few seconds). So data *is* arriving over BLE, but 100% of it fails to parse.
Traced this into the actual `peripheral_uart_test` firmware source (not just
guessed): both the real PPG transmit path (`al_transmit_data()`) and a
generic UART→BLE bridge thread funnel through the same queue
(`fifo_uart_rx_data`) before hitting `bt_nus_send()` (`main.c:973–991`).
That branch also added new IMU I2C debug logging (`debug_imu_i2c()`,
`WHO_AM_I` probing on `0x6A`/`0x6B`) — if that log output shares the same
serial path, it would interleave with real PPG lines and corrupt the
framing, which would produce exactly this symptom (real connection, 100%
and climbing parse-error rate, zero valid samples). This is a firmware-side
issue, not an app bug — the app is correctly rejecting the malformed lines
instead of crashing or showing garbage, which is the intended behavior.

**Next session (picking back up on firmware):** isolate/disable the new
debug logging on `peripheral_uart_test` and confirm parse errors clear;
once real packets are flowing, run the full hardware test matrix from
yesterday's plan (repeated connect/disconnect, Bluetooth-off handling,
strong/weak signal, motion, long-duration recording) that's been blocked on
this the whole time. Everything on the software side is otherwise
demonstrated and stable — this firmware fix is the one thing standing
between here and full checklist validation.

Also rebuilt `PPG_Monitor_Progress.pptx` as a stakeholder-facing version
(plain-language, no commit hashes/function names) and drafted a cover email
to the professor, cc'ing Rutendo — covering what's fixed, in progress, and
next. Not yet confirmed sent.

## 1. Device Connection & Bluetooth
- [ ] App provides a clear error message when the device cannot be found
- [ ] Connection remains stable during a full data-collection session
- [ ] App can discover the PPG device via Bluetooth
- [ ] App can connect to the correct device
- [ ] App clearly displays connection status
- [ ] User can disconnect from the device
- [ ] App can reconnect after an unexpected disconnection
- [ ] App handles Bluetooth being turned off appropriately

## 2. Real-Time PPG Data Acquisition
- [ ] App receives PPG data continuously from the device
- [ ] Sampling rate is correct (25 samples/second)
- [ ] No samples are unintentionally dropped during normal operation
- [ ] Raw PPG values are accessible
- [ ] Data from each PPG channel/wavelength is correctly identified
- [ ] Timestamps are recorded correctly
- [ ] Data acquisition begins when the user presses Start
- [ ] Data acquisition stops when the user presses Stop
- [ ] Starting/stopping multiple sessions does not require restarting the app

## 3. Real-Time PPG Visualization
- [ ] PPG waveform is displayed in real time
- [ ] Plot updates smoothly during acquisition
- [ ] Plot axes are appropriately labeled
- [ ] Different PPG channels/wavelengths can be distinguished
- [ ] Plot scaling allows the waveform to remain visible when signal amplitude changes
- [ ] User can select which signals/channels are displayed
- [ ] Plot does not freeze during long recordings
- [ ] Displayed waveform accurately represents the recorded raw data
- [ ] Accelerometer data can be viewed in real time
- [ ] X, Y, and Z acceleration can be distinguished

## 4. Accelerometer Data Acquisition
- [ ] Accelerometer data remain correctly aligned with PPG data during long recordings
- [ ] App receives accelerometer data continuously from the device
- [ ] Raw X-axis acceleration is recorded
- [ ] Raw Y-axis acceleration is recorded
- [ ] Raw Z-axis acceleration is recorded
- [ ] Accelerometer sampling rate is correct
- [ ] Accelerometer units are clearly defined (e.g., g or m/s²)
- [ ] Accelerometer range/settings are documented
- [ ] Accelerometer timestamps are recorded
- [ ] Accelerometer and PPG data are synchronized to a common time reference
- [ ] Accelerometer recording starts and stops with the PPG recording
- [ ] No accelerometer samples are unintentionally dropped during normal operation

## 5. Participant / Session Information
- [ ] User can enter a participant ID
- [ ] Recording/session ID is generated or entered
- [ ] Date and time of recording are automatically stored
- [ ] Participant ID is associated with the correct recording
- [ ] App prevents accidental mixing of data between participants
- [ ] Required information is entered before a recording begins
- [ ] No unnecessary personally identifiable information is stored

## 6. Recording Workflow
- [ ] Clear Start Recording button
- [ ] Clear Stop Recording button
- [ ] App clearly indicates when recording is active
- [ ] Recording duration is displayed
- [ ] User receives confirmation when recording has stopped
- [ ] User can start another recording without restarting the app
- [ ] Accidental navigation does not cause loss of an active recording
- [ ] App warns the user before exiting an active recording

## 7. Data Storage
- [ ] Each recording is saved successfully
- [ ] Raw PPG data are saved
- [ ] Processed PPG data are saved
- [ ] Relevant calculated metrics are saved
- [ ] Timestamps are saved
- [ ] Participant/session ID is saved with the data
- [ ] Sampling rate and relevant acquisition settings are saved
- [ ] Files have consistent and understandable naming conventions
- [ ] Previously recorded data are not accidentally overwritten
- [ ] Raw X, Y, and Z accelerometer data are saved

## 8. Data Export
- [ ] User can export recorded data
- [ ] Data can be exported in the agreed format (e.g., CSV)
- [ ] Raw PPG channels are included
- [ ] Participant/session information is included
- [ ] Timestamps are included
- [ ] Exported data can be opened and analyzed in Python/MATLAB without additional cleanup

## 9. User Interface
- [ ] Main recording screen is easy to understand
- [ ] Device connection status is always visible
- [ ] Start/Stop controls are easy to identify
- [ ] PPG waveform is clearly visible
- [ ] Signal-quality indicator is clearly visible

## 10. Error Handling
- [ ] App handles Bluetooth disconnection without crashing
- [ ] App handles loss of PPG data without crashing
- [ ] App handles corrupted/incomplete packets appropriately
- [ ] App provides understandable error messages
- [ ] App recovers appropriately after an error
- [ ] Existing recorded data are protected if an error occurs

## 11. Testing & Validation
- [ ] Bluetooth connection tested repeatedly
- [ ] Long-duration recording tested
- [ ] Multiple consecutive recording sessions tested
- [ ] App tested with strong PPG signals
- [ ] App tested with weak PPG signals
- [ ] App tested during motion
- [ ] App tested after unexpected Bluetooth disconnection
- [ ] Saved data compared against the real-time display
- [ ] Exported data checked against the original recorded values

## 12. Documentation & Handoff
- [ ] Source code is stored in the agreed repository
- [ ] Latest working version is pushed to the repository
- [ ] README includes instructions for running/building the app
- [ ] Bluetooth communication protocol is documented
- [ ] Data packet structure is documented
- [ ] Exported file structure and column definitions are documented
- [ ] Instructions are provided for changing parameters/thresholds in the future
- [ ] Final version can be built and run by someone other than the developer

## 13. Final Acceptance
- [ ] All required features have been demonstrated
- [ ] All critical bugs have been resolved
- [ ] App completes a full participant recording workflow
- [ ] Recorded data can be successfully exported and analyzed
- [ ] Source code and documentation have been handed over
- [ ] Final version/release has been clearly identified in the repository
