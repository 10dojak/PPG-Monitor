//
//  BadgeView.swift
//  PPGMonitor
//

import SwiftUI

enum BadgeStyle {
    case ok, warn, err, neutral
}

struct BadgeView: View {
    let text: String
    let style: BadgeStyle

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch style {
        case .ok:      return Color(hex: "#dcfce7")
        case .warn:    return Color(hex: "#fef3c7")
        case .err:     return Color(hex: "#fee2e2")
        case .neutral: return Color(.systemGray6)
        }
    }

    private var foreground: Color {
        switch style {
        case .ok:      return Color(hex: "#16a34a")
        case .warn:    return Color(hex: "#d97706")
        case .err:     return Color(hex: "#dc2626")
        case .neutral: return .secondary
        }
    }
}
