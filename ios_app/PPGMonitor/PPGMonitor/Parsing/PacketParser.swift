//
//  PacketParser.swift
//  PPGMonitor
//

import Foundation

func parseLine(_ line: String) -> ParsedSample? {
    let rawTokens = line.split(separator: " ")
    guard rawTokens.count == 3 else { return nil }   // check token count BEFORE parsing —
    // compactMap on its own would silently drop a non-numeric trailing
    // token (e.g. "3 481 3 garbage") and let a corrupted line parse as if
    // it were the clean 3-token line underneath it.
    let parts = rawTokens.compactMap { Int($0) }
    guard parts.count == 3 else { return nil }

    let tag = parts[0]
    let value = parts[1]
    let slotIdx = parts[2]

    let chip: Chip
    let stream: StreamType
    switch slotIdx {
    case 0...11:
        chip = .u10
        stream = .ppg
    case 128...139:
        chip = .u2
        stream = .ppg
    case 200...202:
        chip = .imu
        stream = .accel
    case 210...212:
        chip = .imu
        stream = .gyro
    case 220:
        chip = .imu
        stream = .wakeup
    default:
        return nil
    }

    return ParsedSample(
        receivedAt: Date(),
        chip: chip,
        stream: stream,
        tag: tag,
        value: value,
        slotIdx: slotIdx
    )
}
