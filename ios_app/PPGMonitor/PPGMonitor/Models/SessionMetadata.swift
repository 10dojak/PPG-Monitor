//
//  SessionMetadata.swift
//  PPGMonitor
//

import Foundation

// Fixed hardware configuration (README's "Key Configuration" table + IMU
// spec) — not user-adjustable from the app, recorded per-session so a
// recording is self-describing without cross-referencing the README.
struct AcquisitionSettings: Codable {
    let nominalPPGSampleRateHz: Double
    let adcRangeNanoamps: Double
    let integrationTimeMicroseconds: Double
    let redLEDCurrentMA: Double
    let irLEDCurrentMA: Double
    let greenLEDCurrentMA: Double
    let accelRangeG: Double
    let accelNominalODRHz: Double

    static let current = AcquisitionSettings(
        nominalPPGSampleRateHz: 25,
        adcRangeNanoamps: 8192,
        integrationTimeMicroseconds: 58.7,
        redLEDCurrentMA: 14.53,
        irLEDCurrentMA: 29.06,
        greenLEDCurrentMA: 14.53,
        accelRangeG: 2,
        accelNominalODRHz: 26
    )
}

struct SessionMetadata: Codable {
    let participantID: String
    let sessionID: String
    let startTime: Date
    var endTime: Date?
    var measuredSampleRate: Double?        // all streams (ppg+accel+gyro+wakeup) combined
    var measuredPPGSampleRate: Double?
    var measuredAccelSampleRate: Double?
    let acquisitionSettings: AcquisitionSettings
    var finalHeartRateBPM: Int?
    var finalSpo2Percent: Int?
}
