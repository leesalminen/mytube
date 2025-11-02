//
//  PlaybackMetricRow.swift
//  MyTube
//
//  Created by Assistant on 11/27/25.
//

import SwiftUI

struct PlaybackMetricRow: View {
    let accent: Color
    let plays: Int?
    let completionRate: Double?
    let replayRate: Double?

    var body: some View {
        HStack(spacing: 16) {
            MetricChip(
                title: "Plays",
                value: plays.map(String.init) ?? "—",
                accent: accent
            )
            MetricChip(
                title: "Completion",
                value: formatPercentage(completionRate),
                accent: accent
            )
            MetricChip(
                title: "Replay",
                value: formatPercentage(replayRate),
                accent: accent
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatPercentage(_ value: Double?) -> String {
        guard let value else { return "—" }
        let clamped = min(max(value, 0.0), 1.0)
        return String(format: "%.0f%%", clamped * 100)
    }
}

private struct MetricChip: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(value)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .shadow(color: accent.opacity(0.25), radius: 8, y: 4)
    }
}
