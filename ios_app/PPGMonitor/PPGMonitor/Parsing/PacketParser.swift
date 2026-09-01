//
//  PacketParser.swift
//  PPGMonitor
//

import Foundation

/// Sentinel `slotIdx` for a line that arrived without one (`"tag value"`).
/// Downstream only ever reads `slotIdx` for `.imu` samples, so a PPG sample
/// carrying this value never uses it as a key — it just records "not on the wire."
let slotIdxAbsent = -1

func parseLine(_ line: String) -> ParsedSample? {
    // Split on any run of whitespace, matching ppg_monitor.html's
    // `line.split(/\s+/)`. Two reasons the port has to be this lenient:
    //   1. A line can legitimately arrive as "tag value" with no slotIdx
    //      (older firmware / the pre-slotIdx transmit format).
    //   2. A valid triplet can have trailing junk after it; the HTML
    //      reference ignores anything past the third token.
    // Being stricter than the HTML here is what produced a 100%-parse-error
    // run against real hardware — every line that isn't exactly 3 tokens was
    // being thrown away.
    let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
    guard tokens.count >= 2 else { return nil }

    guard let tag = Int(tokens[0]), let value = Int(tokens[1]) else { return nil }

    // slotIdx is optional. If present it must be a valid integer (a
    // non-numeric third token means the line is genuinely garbled, not a
    // 2-token line); if absent we fall through to the bare-PPG case below.
    let slotIdx: Int?
    if tokens.count >= 3 {
        guard let parsed = Int(tokens[2]) else { return nil }
        slotIdx = parsed
    } else {
        slotIdx = nil
    }

    let chip: Chip
    let stream: StreamType
    switch slotIdx {
    case .none:
        // No slotIdx on the wire: the only thing that's meaningful is a PPG
        // FIFO tag (1...12). Anything else ("0 3", a stray pair of numbers)
        // is a malformed line, not a sample — reject it rather than invent a
        // channel for it.
        guard (1...12).contains(tag) else { return nil }
        chip = .u10
        stream = .ppg
    case .some(0...11):
        chip = .u10
        stream = .ppg
    case .some(128...139):
        chip = .u2
        stream = .ppg
    case .some(200...202):
        chip = .imu
        stream = .accel
    case .some(210...212):
        chip = .imu
        stream = .gyro
    case .some(220):
        chip = .imu
        stream = .wakeup
    default:
        // An explicit slotIdx that maps to no known stream is still a
        // reject — unlike the HTML, we don't silently treat slotIdx 999 as
        // "U2 because it's >= 128."
        return nil
    }

    return ParsedSample(
        receivedAt: Date(),
        chip: chip,
        stream: stream,
        tag: tag,
        value: value,
        slotIdx: slotIdx ?? slotIdxAbsent
    )
}
