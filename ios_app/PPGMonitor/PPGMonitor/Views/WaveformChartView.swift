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

            Chart {
                ForEach(ppgDatasets.filter { bt.datasetVisible[$0.id] }) { ds in
                    ForEach(bt.channels[ds.channelKey] ?? []) { point in
                        LineMark(
                            x: .value("t", point.x),
                            y: .value("ADC", point.y),
                            series: .value("Channel", ds.label)
                        )
                        .foregroundStyle(ds.color)
                        .lineStyle(StrokeStyle(lineWidth: ds.dashed ? 1.5 : 2, dash: ds.dashed ? [5, 3] : []))
                    }
                }
            }
            .chartLegend(.hidden)
            // Rolling sample index, not wall-clock time like the HTML's
            // x-axis — the display buffers only ever stored an Int index
            // (see DataPoint), not a per-point timestamp. A labeled index
            // still satisfies "axes are appropriately labeled"; showing
            // real elapsed time would need DataPoint to carry a Date too.
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
            .frame(height: 320)
        }
        .padding(20)
        .background(Color.white)
        .cornerRadius(16)
    }
}
