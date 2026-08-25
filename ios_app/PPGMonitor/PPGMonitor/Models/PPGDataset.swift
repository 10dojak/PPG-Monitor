//
//  PPGDataset.swift
//  PPGMonitor
//
//  Ported from ppg_monitor.html's DATASETS array — same 24 channels (4 PDs x
//  6 LED/wavelength combos), same colors, same tag/chip mapping. Visual spec
//  only, not the HTML's code.
//

import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// u10 tags key display buffers directly by tag (1-12); u2 tags are offset
// far past the IMU's raw-slotIdx keys (200-222) so neither range can ever
// collide with the other. (Previously offset by +200, which collided with
// slotIdx 200-212 — u2 tags 1/2/10/11/12 landed on the same channel keys as
// accel X/Y/Z and gyro X/Y/Z.)
let u2ChannelKeyOffset = 1000

struct PPGDataset: Identifiable {
    let id: Int
    let label: String
    let chip: Chip
    let tag: Int
    let color: Color
    let dashed: Bool
    let groupIndex: Int

    var channelKey: Int { chip == .u10 ? tag : tag + u2ChannelKeyOffset }
}

private struct RawDataset {
    let label: String
    let chip: Chip
    let tag: Int
    let hex: String
    let dashed: Bool
}

private let rawDatasets: [RawDataset] = [
    // IR/LED1 — visible by default
    RawDataset(label: "IR·LED1 PD1", chip: .u10, tag: 3,  hex: "#93c5fd", dashed: false),
    RawDataset(label: "IR·LED1 PD2", chip: .u10, tag: 9,  hex: "#2563eb", dashed: true),
    RawDataset(label: "IR·LED1 PD3", chip: .u2,  tag: 3,  hex: "#fbbf24", dashed: false),
    RawDataset(label: "IR·LED1 PD4", chip: .u2,  tag: 9,  hex: "#d97706", dashed: true),
    // IR/LED2
    RawDataset(label: "IR·LED2 PD1", chip: .u10, tag: 4,  hex: "#818cf8", dashed: false),
    RawDataset(label: "IR·LED2 PD2", chip: .u10, tag: 10, hex: "#4338ca", dashed: true),
    RawDataset(label: "IR·LED2 PD3", chip: .u2,  tag: 4,  hex: "#c084fc", dashed: false),
    RawDataset(label: "IR·LED2 PD4", chip: .u2,  tag: 10, hex: "#7c3aed", dashed: true),
    // Red/LED1
    RawDataset(label: "Red·LED1 PD1", chip: .u10, tag: 1, hex: "#fca5a5", dashed: false),
    RawDataset(label: "Red·LED1 PD2", chip: .u10, tag: 7, hex: "#dc2626", dashed: true),
    RawDataset(label: "Red·LED1 PD3", chip: .u2,  tag: 1, hex: "#f87171", dashed: false),
    RawDataset(label: "Red·LED1 PD4", chip: .u2,  tag: 7, hex: "#991b1b", dashed: true),
    // Red/LED2
    RawDataset(label: "Red·LED2 PD1", chip: .u10, tag: 2,  hex: "#fb923c", dashed: false),
    RawDataset(label: "Red·LED2 PD2", chip: .u10, tag: 8,  hex: "#c2410c", dashed: true),
    RawDataset(label: "Red·LED2 PD3", chip: .u2,  tag: 2,  hex: "#fdba74", dashed: false),
    RawDataset(label: "Red·LED2 PD4", chip: .u2,  tag: 8,  hex: "#ea580c", dashed: true),
    // Grn/LED1
    RawDataset(label: "Grn·LED1 PD1", chip: .u10, tag: 5,  hex: "#6ee7b7", dashed: false),
    RawDataset(label: "Grn·LED1 PD2", chip: .u10, tag: 11, hex: "#059669", dashed: true),
    RawDataset(label: "Grn·LED1 PD3", chip: .u2,  tag: 5,  hex: "#a7f3d0", dashed: false),
    RawDataset(label: "Grn·LED1 PD4", chip: .u2,  tag: 11, hex: "#047857", dashed: true),
    // Grn/LED2
    RawDataset(label: "Grn·LED2 PD1", chip: .u10, tag: 6,  hex: "#d9f99d", dashed: false),
    RawDataset(label: "Grn·LED2 PD2", chip: .u10, tag: 12, hex: "#65a30d", dashed: true),
    RawDataset(label: "Grn·LED2 PD3", chip: .u2,  tag: 6,  hex: "#bbf7d0", dashed: false),
    RawDataset(label: "Grn·LED2 PD4", chip: .u2,  tag: 12, hex: "#16a34a", dashed: true),
]

let ppgGroupLabels = ["IR/LED1", "IR/LED2", "Red/LED1", "Red/LED2", "Grn/LED1", "Grn/LED2"]

let ppgDatasets: [PPGDataset] = rawDatasets.enumerated().map { index, raw in
    PPGDataset(
        id: index,
        label: raw.label,
        chip: raw.chip,
        tag: raw.tag,
        color: Color(hex: raw.hex),
        dashed: raw.dashed,
        groupIndex: index / 4
    )
}

// MARK: - Heatmap tag names + coloring (2 chips x 12 slots)

let tagNamesU10: [Int: String] = [
    1: "Red·LED1 PD1", 2: "Red·LED2 PD1", 3: "IR·LED1 PD1",  4: "IR·LED2 PD1",
    5: "Grn·LED1 PD1", 6: "Grn·LED2 PD1", 7: "Red·LED1 PD2", 8: "Red·LED2 PD2",
    9: "IR·LED1 PD2",  10: "IR·LED2 PD2", 11: "Grn·LED1 PD2", 12: "Grn·LED2 PD2",
]
let tagNamesU2: [Int: String] = [
    1: "Red·LED1 PD3", 2: "Red·LED2 PD3", 3: "IR·LED1 PD3",  4: "IR·LED2 PD3",
    5: "Grn·LED1 PD3", 6: "Grn·LED2 PD3", 7: "Red·LED1 PD4", 8: "Red·LED2 PD4",
    9: "IR·LED1 PD4",  10: "IR·LED2 PD4", 11: "Grn·LED1 PD4", 12: "Grn·LED2 PD4",
]
let heatSlotOrder = [1, 7, 2, 8, 3, 9, 4, 10, 5, 11, 6, 12]

// Ported verbatim from updateHeatCell in ppg_monitor.html, including its
// isIR/isRed/isGreen tag groupings — those don't match tagNamesU10/U2's own
// wavelength labels (e.g. isIR checks tag 2/8, but tag 2/8 is labelled
// Red·LED2 above). Kept as-is since the brief was to match the HTML exactly.
func heatmapColor(tag: Int, value: Int?) -> Color {
    let defaultColor = Color(red: 243.0 / 255, green: 244.0 / 255, blue: 246.0 / 255)
    guard let value, value > 0 else { return defaultColor }

    let pct = min(Double(value) / 300_000, 1.0)
    let isIR = tag == 2 || tag == 8
    let isRed = tag == 1 || tag == 7
    let isGreen = tag == 3 || tag == 9

    var r = 243.0, g = 244.0, b = 246.0
    if isIR {
        r = 219 - (219 - 59) * pct
        g = 234 - (234 - 130) * pct
        b = 254 - (254 - 246) * pct
    } else if isRed {
        r = 239
        g = 68 * (1 - pct) + 243 * pct
        b = 68 * (1 - pct) + 244 * pct
    } else if isGreen {
        r = 16 + (243 - 16) * pct
        g = 185 + (244 - 185) * pct
        b = 129 + (246 - 129) * pct
    }
    return Color(red: r / 255, green: g / 255, blue: b / 255)
}

func fmtHeatVal(_ v: Int?) -> String {
    guard let v else { return "—" }
    return v > 999 ? String(format: "%.1fk", Double(v) / 1000) : "\(v)"
}
