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
