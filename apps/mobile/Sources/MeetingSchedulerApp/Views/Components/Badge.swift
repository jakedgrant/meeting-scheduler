//
//  Badge.swift
//  MeetingScheduler
//
//  Created by Jake Grant on 3/2/26.
//

import SwiftUI
import Shared

struct Badge: View {
    let title: String
    let color: Color
    var foregroundColor: Color?
    var backgroundOpacity: Double = 0.15

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(backgroundOpacity))
            .foregroundStyle(foregroundColor ?? color)
            .clipShape(Capsule())
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let status: PollStatus

    private var color: Color {
        switch status {
        case .draft: return .gray
        case .active: return .green
        case .closed: return .orange
        case .archived: return .gray
        }
    }

    private var foregroundColor: Color? {
        switch status {
        case .draft, .archived: return .secondary
        default: return nil
        }
    }

    private var backgroundOpacity: Double {
        switch status {
        case .archived: return 0.3
        default: return 0.2
        }
    }

    var body: some View {
        Badge(
            title: status.rawValue.capitalized,
            color: color,
            foregroundColor: foregroundColor,
            backgroundOpacity: backgroundOpacity
        )
    }
}

// MARK: - OwnerBadge

struct OwnerBadge: View {
    var body: some View {
        Badge(title: "Owner", color: .blue)
    }
}

// MARK: - Previews

#Preview("Badge Variants") {
    VStack(spacing: 12) {
        Badge(title: "Custom", color: .purple)
        Badge(title: "With Override", color: .red, foregroundColor: .pink, backgroundOpacity: 0.3)
        OwnerBadge()
        StatusBadge(status: .draft)
        StatusBadge(status: .active)
        StatusBadge(status: .closed)
        StatusBadge(status: .archived)
    }
    .padding()
}
