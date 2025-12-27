# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

This is a Bluetooth Low Energy (BLE) UART service firmware for Nordic Semiconductor devices, based on the nRF Connect SDK. The project implements a Nordic UART Service (NUS) that bridges UART and BLE communication, designed for PPG (photoplethysmography) sensor data transmission.

**Key characteristics:**
- Based on Nordic nRF Connect SDK peripheral UART sample
- Primary application: Streaming sensor data over BLE UART
- Supports multiple Nordic SoC families (nRF52, nRF53, nRF54 series)
- Uses Zephyr RTOS with CMake build system

## Build System Commands

### Building the Firmware

Build for a specific board:
```bash
west build -b <board_name>
```

Common board targets:
- `nrf5340dk/nrf5340/cpuapp` - nRF5340 DK application core
- `nrf52840dk/nrf52840` - nRF52840 DK
- `thingy53/nrf5340/cpuapp` - Thingy:53

Build with sysbuild (multi-image):
```bash
west build -b <board_name> --sysbuild
```

Clean build:
```bash
west build -b <board_name> -p
```

### Build Variants

Minimal configuration (resource-constrained boards):
```bash
west build -b <board_name> -- -DEXTRA_CONF_FILE=prj_minimal.conf
```

USB CDC ACM variant:
```bash
west build -b <board_name> -- -DEXTRA_CONF_FILE=prj_cdc.conf -DDTC_OVERLAY_FILE=usb.overlay
```

BLE RPC interface:
```bash
west build -b <board_name> --sysbuild -S nordic-bt-rpc -- -DFILE_SUFFIX=bt_rpc
```

### Flashing

Flash the built firmware:
```bash
west flash
```

### Debugging

The project uses RTT (Real-Time Transfer) for debug logging, not UART console (UART is used for data transfer).

View debug logs:
```bash
JLinkRTTClient
```

Or use a dedicated RTT viewer tool from your Nordic SDK installation.

## Architecture Overview

### Core Components

**Main Application (`src/main.c`)**
- Single-file implementation containing all application logic
- Main thread: LED blinking + periodic test data generation
- BLE write thread: Handles BLE transmission of queued data
- Event-driven architecture using Zephyr kernel primitives

**Data Flow:**
```
UART RX → FIFO → BLE Thread → NUS Service → BLE Connection
UART TX ← FIFO ← BLE Callback ← NUS Service ← BLE Connection
Main Loop → Test Data → FIFO → BLE Thread
```

### Key Subsystems

1. **UART Handler** (`uart_cb`): Asynchronous UART event processing
   - Manages TX/RX buffers dynamically
   - Handles buffer allocation/deallocation
   - Uses UART async API with optional adapter for interrupt-only drivers

2. **BLE Connection Manager**: 
   - Advertising/connection state management
   - Security/pairing with MITM protection (configurable)
   - Connection callbacks for state changes

3. **NUS (Nordic UART Service)**:
   - Custom GATT service for serial-over-BLE
   - Bidirectional data transfer
   - Registered callback: `bt_receive_cb`

4. **FIFO Queues**:
   - `fifo_uart_tx_data`: BLE→UART outbound queue
   - `fifo_uart_rx_data`: UART→BLE / generated data queue

### Configuration System

**Kconfig Options** (`Kconfig`):
- `CONFIG_BT_NUS_THREAD_STACK_SIZE`: Thread stack size (default: 1024)
- `CONFIG_BT_NUS_UART_BUFFER_SIZE`: UART buffer size (default: 40)
- `CONFIG_BT_NUS_SECURITY_ENABLED`: BLE security (default: y)
- `CONFIG_BT_NUS_UART_RX_WAIT_TIME`: RX timeout in µs (default: 50000)

**Project Configuration** (`prj.conf`):
- UART async API enabled
- BLE peripheral role
- NUS service enabled
- RTT logging backend (not UART)
- Flash/settings for bonding persistence

**Board-Specific Overlays** (`boards/`):
- Per-board .conf and .overlay files for hardware-specific settings
- Devicetree overlays for pin configurations

### Multi-Core Support

For nRF53 series devices:
- Application runs on CPU app core
- Networking core configuration in `sysbuild/ipc_radio/`
- IPC (Inter-Processor Communication) for BLE stack offloading
- Sysbuild orchestrates multi-image builds

### Test Data Generation

The main loop generates synthetic cosine wave data:
- 50ms intervals
- Format: `<timestamp_ms> <cosine_value>\r\n`
- Simulates sensor readings for testing
- Data placed into `fifo_uart_rx_data` for BLE transmission

## Development Workflow

1. **Modify code** in `src/main.c` or configuration files
2. **Build** with appropriate board target and configuration
3. **Flash** to device via west flash
4. **Monitor** debug output via RTT
5. **Test** BLE connection using nRF Connect for Mobile/Desktop

## Important Notes

- Do not modify UART console settings in `prj.conf` - logging uses RTT, UART is for data
- The async adapter (`CONFIG_UART_ASYNC_ADAPTER`) bridges interrupt-only UART drivers to async API
- LED assignments vary by board (nRF21/52/53: LED1/2, nRF54: LED0/1)
- Security features require button interaction for passkey confirmation
- The device name "Nordic_UART_Service" can be changed via `CONFIG_BT_DEVICE_NAME`
- Test data generation in main loop is custom to this implementation (not standard NUS sample)

## Nordic SDK Context

This project requires:
- nRF Connect SDK installation
- West build tool
- Zephyr SDK toolchain
- J-Link or compatible debugger
- Board-specific devicetree and driver support from SDK

Standard Zephyr/Nordic SDK conventions apply:
- Use `west` for all build/flash operations
- Kconfig for feature configuration
- Devicetree for hardware description
- Logging via `LOG_*` macros from `<zephyr/logging/log.h>`
