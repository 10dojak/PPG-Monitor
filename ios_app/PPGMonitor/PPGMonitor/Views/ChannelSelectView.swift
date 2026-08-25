//
//  ChannelSelectView.swift
//  PPGMonitor
//
//  Toggle chips for the 24 PPG datasets, grouped 4-at-a-time by
//  LED/wavelength — tapping a chip actually shows/hides that series on the
//  waveform chart via BluetoothManager.datasetVisible.
//

import SwiftUI

struct ChannelSelectView: View {
    @ObservedObject var bt: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<6, id: \.self) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ppgGroupLabels[group])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    HStack(spacing: 6) {
                        ForEach(ppgDatasets.filter { $0.groupIndex == group }) { ds in
                            chip(ds)
                        }
                    }
                }
            }
        }
    }

    private func chip(_ ds: PPGDataset) -> some View {
        let isOn = bt.datasetVisible[ds.id]
        return Text(ds.label)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(ds.color)
            .background(ds.color.opacity(0.12))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(isOn ? ds.color : .clear, lineWidth: 1.5)
            )
            .opacity(isOn ? 1.0 : 0.4)
            .onTapGesture {
                bt.datasetVisible[ds.id].toggle()
            }
    }
}
