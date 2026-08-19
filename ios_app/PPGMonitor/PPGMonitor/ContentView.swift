//
//  ContentView.swift
//  PPG Monitor
//

import SwiftUI
import Charts

// MARK: - Channel configuration (what to display)

struct ChannelConfig: Identifiable {
    let id: Int         // matches BluetoothManager channel key
    let name: String
    let color: Color
}

let displayChannels: [ChannelConfig] = [
    ChannelConfig(id: 9,  name: "IR   · PD2  (U10)", color: .blue),
    ChannelConfig(id: 7,  name: "Red  · PD2  (U10)", color: .red),
    ChannelConfig(id: 11, name: "Green· PD2  (U10)", color: .green),
    ChannelConfig(id: 3,  name: "IR   · PD1  (U10)", color: Color(red: 0.3, green: 0.3, blue: 0.9)),
    ChannelConfig(id: 1,  name: "Red  · PD1  (U10)", color: .orange),
    ChannelConfig(id: 5,  name: "Green· PD1  (U10)", color: Color(red: 0.1, green: 0.7, blue: 0.3)),
]

// MARK: - Single waveform panel

struct WaveformPanel: View {
    let config: ChannelConfig
    let points: [DataPoint]

    private var yRange: ClosedRange<Double> {
        guard points.count > 1 else { return 0...1000 }
        let vals = points.map(\.y)
        let lo   = vals.min()!
        let hi   = vals.max()!
        let pad  = max((hi - lo) * 0.1, 50)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(config.color)
                    .frame(width: 14, height: 4)
                Text(config.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let last = points.last {
                    Text(String(format: "%.0f", last.y))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(config.color)
                }
            }

            if points.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                    Text("Waiting…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(height: 90)
            } else {
                Chart(points) { p in
                    LineMark(
                        x: .value("t", p.x),
                        y: .value("ADC", p.y)
                    )
                    .foregroundStyle(config.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: yRange)
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine()
                        AxisValueLabel()
                            .font(.system(size: 9))
                    }
                }
                .frame(height: 90)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var bt = BluetoothManager()

    // Two-column grid on iPad
    let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(displayChannels) { ch in
                        WaveformPanel(
                            config: ch,
                            points: bt.channels[ch.id] ?? []
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("PPG Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bt.isConnected ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(bt.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
