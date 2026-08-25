//
//  ParsedSample.swift
//  PPGMonitor
//

import Foundation

enum Chip: Equatable {
    case u10
    case u2
    case imu
}

enum StreamType: Equatable {
    case ppg
    case accel
    case gyro
    case wakeup
}

struct ParsedSample {
    let receivedAt: Date
    let chip: Chip
    let stream: StreamType
    let tag: Int
    let value: Int
    let slotIdx: Int
}
