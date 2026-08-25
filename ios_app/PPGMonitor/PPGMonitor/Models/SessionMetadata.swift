//
//  SessionMetadata.swift
//  PPGMonitor
//

import Foundation

struct SessionMetadata: Codable {
    let participantID: String
    let sessionID: String
    let startTime: Date
    var endTime: Date?
    var measuredSampleRate: Double?
    var finalHeartRateBPM: Int?
    var finalSpo2Percent: Int?
}
