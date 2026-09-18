//
//  WaveformChartView.swift
//  PPGMonitor
//
//  24-channel PPG waveform chart with toggle chips, ported from
//  ppg_monitor.html's "Waveforms" tab.
//

import SwiftUI
import Charts

struct WaveformChartView: View {
    @ObservedObject var bt: BluetoothManager

    // nil = "zoomed out": y-axis fits every selected channel. A specific
    // dataset id zooms the y-axis in on just that one (others keep drawing,
    // so they may clip off the top/bottom — that's the point of zooming in).
    @State private var zoomedDatasetID: Int?
    @State private var showZoomPicker = false

    // How much of the retained history the chart shows at once. Retention
    // itself (BluetoothManager.maxHistorySeconds) is the ceiling on how far
    // back a user can drag past this.
    private let windowSeconds: TimeInterval = 30

    // Leading (oldest-visible) edge of the chart's visible domain — bound
    // two-way to the chart via chartScrollPosition, so both our own
    // auto-follow writes AND the user's drag gestures land here.
    //
    // A hand-rolled chartOverlay + GeometryReader + DragGesture was tried
    // first (to sidestep a since-disproven CPU worry about the native
    // scrolling API — see BluetoothManager's history for that dead end).
    // It caused a real, worse bug: GeometryReader isn't reliably clipped to
    // the chart's plot area, and its content visibly painted outside the
    // chart's own frame, over sibling views above it (the channel chips).
    // Native scrolling has no such overlay to escape its bounds.
    @State private var windowStart: Date = Date()

    // Distinguishes our own programmatic writes to windowStart (auto-follow)
    // from the user's drag, since chartScrollPosition's binding fires for both.
    @State private var isProgrammaticScroll = false

    // true = auto-follow the newest sample (the default "latest 30s"
    // behavior). Dragging backwards drops into history-review mode; tapping
    // "Back to current" jumps back to following the newest data.
    @State private var isLive = true

    private var visibleDatasets: [PPGDataset] {
        ppgDatasets.filter { bt.datasetVisible[$0.id] }
    }

    private var focusedDatasets: [PPGDataset] {
        if let zoomedDatasetID, let ds = visibleDatasets.first(where: { $0.id == zoomedDatasetID }) {
            return [ds]
        }
        return visibleDatasets
    }

    // Anchored on the newest sample actually received, not literal
    // wall-clock Date() — keeps auto-follow from drifting ahead of the data
    // during a stall/disconnect.
    private var latestTimestamp: Date {
        let latest = visibleDatasets.compactMap { bt.channels[$0.channelKey]?.last?.t }.max()
        return latest ?? Date()
    }

    private var earliestTimestamp: Date {
        let earliest = visibleDatasets.compactMap { bt.channels[$0.channelKey]?.first?.t }.min()
        return earliest ?? latestTimestamp
    }

    private var visibleRange: ClosedRange<Date> {
        windowStart...windowStart.addingTimeInterval(windowSeconds)
    }

    // Only the points currently on screen — so "fit all" / zoom-in scale to
    // what's actually visible, not the whole 120s retained history.
    //
    // Computed fresh every render, NOT cached/throttled: a cached version
    // that only refreshed every 0.5s let a new sample land outside the
    // stale range within that gap, clipping the line at the top/bottom
    // until the next refresh. The line points themselves are filtered
    // fresh every render (see the Chart body below); the y-scale needs to
    // match that, not lag behind it.
    private var yDomain: ClosedRange<Double> {
        let range = visibleRange
        let values = focusedDatasets.flatMap { ds in
            (bt.channels[ds.channelKey] ?? [])
                .filter { range.contains($0.t) }
                .map(\.y)
        }
        guard let lo = values.min(), let hi = values.max(), lo < hi else {
            return 0...1
        }
        let padding = (hi - lo) * 0.08
        return (lo - padding)...(hi + padding)
    }

    // Can't auto-follow to a position before the oldest retained sample —
    // only matters right at startup before much history has accumulated.
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PPG Waveforms")
                    .font(.title3.bold())
                Text("Live · 24 channels (4 PDs × 6 LEDs: 3 wavelengths × 2 LEDs each) · tap chips to toggle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ChannelSelectView(bt: bt)

            HStack {
                liveIndicator
                Spacer()
                zoomMenu
            }

            Chart {
                ForEach(visibleDatasets) { ds in
                    ForEach(bt.channels[ds.channelKey] ?? []) { point in
                        LineMark(
                            x: .value("Time", point.t),
                            y: .value("ADC", point.y),
                            series: .value("Channel", ds.label)
                        )
                        .foregroundStyle(ds.color)
                        .lineStyle(StrokeStyle(lineWidth: ds.dashed ? 1.5 : 2, dash: ds.dashed ? [5, 3] : []))
                    }
                }
            }
            .chartLegend(.hidden)
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
            .frame(height: 320)
        }
        .padding(20)
        .background(Color.white)
        .cornerRadius(16)
        .onAppear { snapToLive() }
        // Re-anchors the visible window to the newest sample twice a second
        // while live — not on every incoming sample (data arrives at up to
        // ~100/sec with mock data), since writing chartScrollPosition that
        // often measurably pegs the main thread without benefit; twice a
        // second is imperceptible as "live" and far cheaper.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if isLive {
                    isProgrammaticScroll = true
                    windowStart = clamped(latestTimestamp.addingTimeInterval(-windowSeconds))
                }
            }
        }
        // chartScrollPosition's binding fires for our own writes above AND
        // for the user's drag — the flag tells them apart.
        .onChange(of: windowStart) { _ in
            if isProgrammaticScroll {
                isProgrammaticScroll = false
            } else {
                isLive = false
            }
        }
        // If the zoomed-in channel gets toggled off (or nothing is selected
        // at all), fall back to the all-channels fit instead of freezing on
        // a dataset that's no longer drawn.
        .onChange(of: bt.datasetVisible) { _ in
            if let zoomedDatasetID, !visibleDatasets.contains(where: { $0.id == zoomedDatasetID }) {
                self.zoomedDatasetID = nil
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

    // A native Menu can't do this: SwiftUI/UIKit forces standard black text
    // on menu item labels regardless of .foregroundColor, so there's no way
    // to color-code entries by channel there. A popover with our own rows
    // gives full control — styled like ChannelSelectView's chips so the
    // color association is the same one already learned from the chips.
    private var zoomMenu: some View {
        Button {
            showZoomPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text(zoomedDatasetID.flatMap { id in visibleDatasets.first { $0.id == id }?.label } ?? "Zoom: All")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(zoomedDatasetID.flatMap { id in visibleDatasets.first { $0.id == id }?.color } ?? .secondary)
        }
        .disabled(visibleDatasets.isEmpty)
        .popover(isPresented: $showZoomPicker) {
            zoomPickerContent
                .presentationCompactAdaptation(.popover)
        }
    }

    private var zoomPickerContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            zoomPickerRow(label: "All selected (fit all)", color: .secondary, isSelected: zoomedDatasetID == nil) {
                zoomedDatasetID = nil
            }
            Divider()
            ForEach(visibleDatasets) { ds in
                zoomPickerRow(label: ds.label, color: ds.color, isSelected: zoomedDatasetID == ds.id) {
                    zoomedDatasetID = ds.id
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
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
}
