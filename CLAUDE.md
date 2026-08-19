# CLAUDE.md

## Scope

`ios_app/` is the only thing being built/fixed here. `src/`, `boards/`,
`*.conf`, `*.overlay`, `WARP.md` are firmware — reference-only, not touched.
`ppg_monitor.html` is a working reference implementation (JS/Web
Bluetooth/Chart.js) — its UI and math get ported, none of its code is reused
directly (different stack entirely).

Deadline: Sept 4, 2026. Full requirements: `App Development Checklist.pdf` in
`/Users/tsaichenlo/Documents/claude-md/PPG Project/`. Objectives and
architecture decisions: `PLANNING.md` in this repo — read that before making
new architectural calls, don't re-derive decisions already made there.

## Device & protocol

- Firmware advertises as **`PPG_DK_2026A`** — filter BLE scans by name, not
  just service UUID.
- Nordic UART Service: service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, TX
  characteristic `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`.
- Wire format, one line per sample: `tag value slotIdx\r\n`
  - `tag` (1-12): MAX86141 FIFO tag — LED+photodiode combination
  - `value`: 19-bit ADC optical count
  - `slotIdx`: which chip / stream —
    - `0-11` = U10 (primary chip)
    - `128-139` = U2 (secondary chip, mux-routed)
    - `200/201/202` = IMU accel X/Y/Z — `tag` is always 0, `value` is
      `accel_cm_s2 + 20000` (offset to keep unsigned)
    - `210/211/212` = IMU gyro X/Y/Z — same tag=0 framing, `mrad/s + 50000`
      offset
    - `220` = IMU wake-up event — `value` is a bitmask (bit0=X, bit1=Y,
      bit2=Z)
- **No on-device timestamp exists in the wire format.** Every timestamp the
  app records is receive-time (`Date()` on arrival), not sample-time. This is
  a known limitation, not a bug in the parser — document it, don't try to
  "fix" it by inventing a timestamp.

## Known limitations (firmware side, not ours to fix)

- The firmware's transmit loop (`src/main.c`) sends only the most recent
  12-sample cycle per 200ms tick and discards the rest of whatever
  accumulated in the FIFO that cycle — real throughput may be well under the
  nominal 25 SPS. The app must **measure and report actual received rate**,
  not assume the spec number. See PLANNING.md's error-handling section.
- Waiting on raw BLE capture logs (good/motion/poor sensor contact, with
  timing) from the firmware author, for use as realistic mock/replay data
  instead of synthetic test signals.

## Architecture (see PLANNING.md for full detail)

- `PPGDataSource` protocol abstracts "how lines arrive" — `BLEDataSource`
  (CoreBluetooth, physical device only) and `MockReplayDataSource` (replays a
  captured log, runs in Simulator) both feed the same parser/session
  pipeline. Build and test against mock data first; real BLE is a later,
  isolated phase.
- Storage is plain files (CSV + JSON metadata per session), not a database —
  recordings need to be directly portable to Python/MATLAB.
- `ObservableObject` / `@Published`, not `@Observable` — target is iOS 16+.

## Build/run

TBD — filled in once the Xcode project exists.
