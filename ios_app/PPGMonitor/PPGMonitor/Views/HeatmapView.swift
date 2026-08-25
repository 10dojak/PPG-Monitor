//
//  HeatmapView.swift
//  PPGMonitor
//
//  All-24-channel heatmap, ported from ppg_monitor.html's "All 24 Channels"
//  tab — one 12-slot grid per chip, color intensity driven by live value.
//

import SwiftUI

struct HeatmapView: View {
    @ObservedObject var bt: BluetoothManager

    var body: some View {
        VStack(spacing: 16) {
            chipCard(title: "U10 — Primary MAX86141", sub: "12 slots · CSB1 (P0.17)", chip: .u10)
            chipCard(title: "U2 — Secondary MAX86141", sub: "12 slots · CSB2 (P0.27) · MAX4783 mux ctrl", chip: .u2)
        }
    }

    private func chipCard(title: String, sub: String, chip: Chip) -> some View {
        let tagNames = chip == .u10 ? tagNamesU10 : tagNamesU2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(sub).font(.caption2).foregroundColor(.secondary)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(heatSlotOrder, id: \.self) { tag in
                    let key = chip == .u10 ? tag : tag + u2ChannelKeyOffset
                    let value = bt.channels[key]?.last.map { Int($0.y) }

                    VStack(spacing: 2) {
                        Text(tagNames[tag] ?? "")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8)
                        Text(fmtHeatVal(value))
                            .font(.system(size: 11, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(heatmapColor(tag: tag, value: value))
                    .cornerRadius(8)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(16)
    }
}
