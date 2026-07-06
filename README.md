# PPG Monitor

**Developed by Rutendo Jakachira (rutendo_jakachira@brown.edu) · July 2026**

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
    ├── BluetoothManager.swift   # Core Bluetooth BLE manager
    └── ContentView.swift        # SwiftUI live waveform display
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

### Key Configuration (Rutendo Jakachira, July 2026)

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

## iOS App (`ios_app/`)

Native iPad/iPhone app built with SwiftUI and Core Bluetooth.

**Requirements:** Xcode 15+, iOS 16+, physical device (BLE not available in simulator)

**Setup:**
1. Create a new Xcode project named `PPG Monitor`
2. Replace `ContentView.swift` and add `BluetoothManager.swift` with the files in `ios_app/`
3. Add `NSBluetoothAlwaysUsageDescription` to `Info.plist`
4. Build and run on a physical device

**Features:**
- Auto-scans and connects to `PPG_DK_2026A` on launch
- 6-panel live waveform grid (Red, IR, Green × 2 photodiodes)
- Auto-scaling Y axis per channel
- Rolling 200-sample window

---

## Device Name

The firmware advertises as: **`PPG_DK_2026A`**
