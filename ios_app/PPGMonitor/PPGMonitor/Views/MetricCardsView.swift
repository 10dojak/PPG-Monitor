//
//  MetricCardsView.swift
//  PPGMonitor
//
//  4 top-level metric cards (Heart Rate, SpO2, IR-4PD comparison, Chip
//  Status), ported from ppg_monitor.html's .cards section.
//

import SwiftUI

struct MetricCardsView: View {
    @ObservedObject var bt: BluetoothManager

    private func latest(_ key: Int) -> Int? { bt.channels[key]?.last.map { Int($0.y) } }

    private func fmt(_ v: Int?) -> String {
        guard let v else { return "—" }
        return v > 999 ? "\(Int((Double(v) / 1000).rounded()))k" : "\(v)"
    }

    private var bothActive: Bool { bt.cntU10 > 0 && bt.cntU2 > 0 }
    private var onlyU10: Bool { bt.cntU10 > 0 && bt.cntU2 == 0 }
    private var chipStatusText: String {
        bothActive ? "Both chips OK" : onlyU10 ? "U2 silent!" : bt.cntU2 > 0 ? "U10 silent!" : "No data"
    }
    private var ppgStreaming: Bool { bt.cntU10 + bt.cntU2 > 0 }

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            card(icon: "heart.fill", title: "Heart Rate", sub: "IR·LED1 PD4 (U2 tag 9)") {
                VStack(alignment: .leading, spacing: 12) {
                    (Text(bt.heartRateBPM.map { "\($0)" } ?? "—").font(.system(size: 32, weight: .bold))
                        + Text(" BPM").font(.subheadline).foregroundColor(.secondary))
                        .foregroundColor(Color(hex: "#16a34a"))
                    BadgeView(
                        text: bt.heartRateBPM == nil ? "Waiting..." : (bt.hrInRange ? "Normal Range" : "Out of Range"),
                        style: bt.heartRateBPM == nil ? .neutral : (bt.hrInRange ? .ok : .warn)
                    )
                }
            }

            card(icon: "drop.fill", title: "SpO₂", sub: "Red·LED1 PD4 / IR·LED1 PD4 (U2 tags 7 & 9)") {
                VStack(alignment: .leading, spacing: 12) {
                    (Text(bt.spo2Percent.map { "\($0)" } ?? "—").font(.system(size: 32, weight: .bold))
                        + Text(" %").font(.subheadline).foregroundColor(.secondary))
                        .foregroundColor(Color(hex: "#16a34a"))
                    BadgeView(
                        text: bt.spo2Percent == nil ? "Waiting..." : (bt.spo2InRange ? "Normal Range" : "Low — check sensor"),
                        style: bt.spo2Percent == nil ? .neutral : (bt.spo2InRange ? .ok : .warn)
                    )
                }
            }

            card(icon: "waveform.path.ecg", title: "IR Signal — 4 PDs", sub: "Counts across both chips") {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        chipCell("U10 · PD1", fmt(latest(2)), .blue)
                        chipCell("U10 · PD2", fmt(latest(8)), .blue)
                        chipCell("U2 · PD1", fmt(latest(2 + u2ChannelKeyOffset)), Color(hex: "#f59e0b"))
                        chipCell("U2 · PD2", fmt(latest(8 + u2ChannelKeyOffset)), Color(hex: "#f59e0b"))
                    }
                    BadgeView(text: ppgStreaming ? "Streaming" : "Waiting...", style: ppgStreaming ? .ok : .neutral)
                }
            }

            card(icon: "bolt.fill", title: "Chip Status", sub: "Packet counts since connect") {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        chipCell("U10 packets", "\(bt.cntU10)", .blue)
                        chipCell("U2 packets", "\(bt.cntU2)", Color(hex: "#f59e0b"))
                        chipCell("Parse errors", "\(bt.cntErr)", .red)
                        chipCell("Sample rate", bt.samplesPerSecond > 0 ? "\(bt.samplesPerSecond)/s" : "—", .secondary)
                    }
                    BadgeView(text: chipStatusText, style: bothActive ? .ok : .err)
                }
            }
        }
    }

    private func chipCell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Text(value).font(.subheadline.bold()).foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    private func card<Content: View>(icon: String, title: String, sub: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(.secondary)
                Text(title).font(.headline)
            }
            Text(sub).font(.system(size: 11)).foregroundColor(Color(.systemGray3))
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }
}
