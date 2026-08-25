//
//  AccelView.swift
//  PPGMonitor
//
//  Acceleration tab, ported from ppg_monitor.html's "Acceleration" panel —
//  X/Y/Z readouts, magnitude/motion badge, and a 3-series line chart.
//

import SwiftUI
import Charts

private let accelOffset = 20000.0
private let accelScale  = 100.0

struct AccelView: View {
    @ObservedObject var bt: BluetoothManager

    private func converted(_ key: Int) -> [DataPoint] {
        (bt.channels[key] ?? []).map { DataPoint(x: $0.x, y: ($0.y - accelOffset) / accelScale) }
    }

    private var latestX: Double? { converted(200).last?.y }
    private var latestY: Double? { converted(201).last?.y }
    private var latestZ: Double? { converted(202).last?.y }

    private var magnitude: Double? {
        guard let x = latestX, let y = latestY, let z = latestZ else { return nil }
        return (x * x + y * y + z * z).squareRoot()
    }

    private var inMotion: Bool {
        guard let m = magnitude else { return false }
        return abs(m - 9.81) > 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Acceleration — LSM6DSOTR").font(.title3.bold())
                Text("±2g @ 26 Hz accel on 200..202 · gyro on 210..212 · wake-up event on 220")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                axisCell("X axis", latestX, .blue)
                axisCell("Y axis", latestY, Color(hex: "#10b981"))
                axisCell("Z axis", latestZ, Color(hex: "#f59e0b"))
            }

            HStack(spacing: 6) {
                Text("Magnitude: ") + Text(magnitude.map { String(format: "%.2f", $0) } ?? "—").fontWeight(.semibold) + Text(" m/s²")
                Spacer()
                BadgeView(text: magnitude == nil ? "Waiting..." : (inMotion ? "Motion detected" : "Still"),
                          style: magnitude == nil ? .neutral : (inMotion ? .warn : .ok))
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Chart {
                ForEach(converted(200)) { p in
                    LineMark(x: .value("t", p.x), y: .value("m/s²", p.y), series: .value("axis", "X"))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(converted(201)) { p in
                    LineMark(x: .value("t", p.x), y: .value("m/s²", p.y), series: .value("axis", "Y"))
                        .foregroundStyle(Color(hex: "#10b981"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(converted(202)) { p in
                    LineMark(x: .value("t", p.x), y: .value("m/s²", p.y), series: .value("axis", "Z"))
                        .foregroundStyle(Color(hex: "#f59e0b"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .frame(height: 280)
        }
        .padding(20)
        .background(Color.white)
        .cornerRadius(16)
    }

    private func axisCell(_ label: String, _ value: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value.map { String(format: "%.2f m/s²", $0) } ?? "— m/s²")
                .font(.subheadline.bold())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}
