//
//  AccelView.swift
//  PPGMonitor
//
//  Acceleration tab, ported from ppg_monitor.html's "Acceleration" panel —
//  X/Y/Z readouts, magnitude/motion badge, and a 3-series line chart.
//
//  The chart mirrors WaveformChartView's navigation: a rolling 30s live
//  window, native drag-back through retained history with "Back to
//  current", and a y-axis zoom onto a single axis (others greyed out).
//  See WaveformChartView for why each piece is built the way it is.
//

import SwiftUI
import Charts

private let accelOffset = 20000.0
private let accelScale  = 100.0

private struct AccelAxis: Identifiable {
    let id: Int        // raw slotIdx channel key (200/201/202)
    let label: String
    let color: Color
}

private let accelAxes: [AccelAxis] = [
    AccelAxis(id: 200, label: "X", color: .blue),
    AccelAxis(id: 201, label: "Y", color: Color(hex: "#10b981")),
    AccelAxis(id: 202, label: "Z", color: Color(hex: "#f59e0b")),
]

struct AccelView: View {
    @ObservedObject var bt: BluetoothManager

    // nil = fit all three axes; otherwise the y-axis fits just that one.
    @State private var zoomedAxisID: Int?
    @State private var showZoomPicker = false

    private let windowSeconds: TimeInterval = 30
    @State private var windowStart: Date = Date()
    @State private var isProgrammaticScroll = false
    @State private var isLive = true

    private func converted(_ key: Int) -> [DataPoint] {
        (bt.channels[key] ?? []).map { DataPoint(x: $0.x, y: ($0.y - accelOffset) / accelScale, t: $0.t) }
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

    private func isDimmed(_ axis: AccelAxis) -> Bool {
        zoomedAxisID != nil && axis.id != zoomedAxisID
    }

    // Zoomed axis drawn last so the grey ones never cover it.
    private var drawOrder: [AccelAxis] {
        accelAxes.filter(isDimmed) + accelAxes.filter { !isDimmed($0) }
    }

    private var latestTimestamp: Date {
        accelAxes.compactMap { bt.channels[$0.id]?.last?.t }.max() ?? Date()
    }

    private var earliestTimestamp: Date {
        accelAxes.compactMap { bt.channels[$0.id]?.first?.t }.min() ?? latestTimestamp
    }

    private var visibleRange: ClosedRange<Date> {
        windowStart...windowStart.addingTimeInterval(windowSeconds)
    }

    // Fit to on-screen points only, recomputed every render (same reasoning
    // as WaveformChartView.yDomain).
    private var yDomain: ClosedRange<Double> {
        let range = visibleRange
        let keys = zoomedAxisID.map { [$0] } ?? accelAxes.map(\.id)
        let values = keys.flatMap { key in
            converted(key).filter { range.contains($0.t) }.map(\.y)
        }
        guard let lo = values.min(), let hi = values.max(), lo < hi else {
            return -1...1
        }
        let padding = (hi - lo) * 0.08
        return (lo - padding)...(hi + padding)
    }

    private func clamped(_ date: Date) -> Date {
        let minStart = earliestTimestamp
        let maxStart = max(minStart, latestTimestamp.addingTimeInterval(-windowSeconds))
        return min(max(date, minStart), maxStart)
    }

    private func snapToLive() {
        isLive = true
        isProgrammaticScroll = true
        windowStart = clamped(latestTimestamp.addingTimeInterval(-windowSeconds))
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
                ForEach(accelAxes) { axis in
                    axisCell("\(axis.label) axis", converted(axis.id).last?.y, axis.color)
                }
            }

            HStack(spacing: 6) {
                Text("Magnitude: ") + Text(magnitude.map { String(format: "%.2f", $0) } ?? "—").fontWeight(.semibold) + Text(" m/s²")
                Spacer()
                BadgeView(text: magnitude == nil ? "Waiting..." : (inMotion ? "Motion detected" : "Still"),
                          style: magnitude == nil ? .neutral : (inMotion ? .warn : .ok))
            }
            .font(.caption)
            .foregroundColor(.secondary)

            HStack {
                liveIndicator
                Spacer()
                zoomMenu
            }

            Chart {
                ForEach(drawOrder) { axis in
                    ForEach(converted(axis.id)) { p in
                        LineMark(x: .value("Time", p.t), y: .value("m/s²", p.y), series: .value("axis", axis.label))
                            .foregroundStyle(isDimmed(axis) ? Color(.systemGray3) : axis.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
            }
            .chartYScale(domain: yDomain)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: windowSeconds)
            .chartScrollPosition(x: $windowStart)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute().second(), centered: true)
                        .font(.system(size: 9))
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
        .onAppear { snapToLive() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if isLive {
                    isProgrammaticScroll = true
                    windowStart = clamped(latestTimestamp.addingTimeInterval(-windowSeconds))
                }
            }
        }
        .onChange(of: windowStart) { _ in
            if isProgrammaticScroll {
                isProgrammaticScroll = false
            } else {
                isLive = false
            }
        }
    }

    private var liveIndicator: some View {
        Button(action: snapToLive) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isLive ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(isLive ? "Live" : "Back to current")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isLive ? .green : .secondary)
        }
        .disabled(isLive)
    }

    private var zoomedAxis: AccelAxis? {
        zoomedAxisID.flatMap { id in accelAxes.first { $0.id == id } }
    }

    private var zoomMenu: some View {
        Button {
            showZoomPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text(zoomedAxis.map { "\($0.label) axis" } ?? "Zoom: All")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(zoomedAxis?.color ?? .secondary)
        }
        .popover(isPresented: $showZoomPicker) {
            zoomPickerContent
                .presentationCompactAdaptation(.popover)
        }
    }

    private var zoomPickerContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            zoomPickerRow(label: "All axes (fit all)", color: .secondary, isSelected: zoomedAxisID == nil) {
                zoomedAxisID = nil
            }
            Divider()
            ForEach(accelAxes) { axis in
                zoomPickerRow(label: "\(axis.label) axis", color: axis.color, isSelected: zoomedAxisID == axis.id) {
                    zoomedAxisID = axis.id
                }
            }
        }
        .padding(12)
        .frame(minWidth: 180, alignment: .leading)
    }

    private func zoomPickerRow(label: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showZoomPicker = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                    .foregroundColor(color)
                    .font(.system(size: 10))
                Text(label)
                    .foregroundColor(color)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isSelected ? color.opacity(0.12) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
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
