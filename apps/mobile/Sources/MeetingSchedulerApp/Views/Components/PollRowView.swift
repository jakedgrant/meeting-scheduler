//
//  PollRowView.swift
//  MeetingScheduler
//
//  Created by Jake Grant on 3/2/26.
//

import SwiftUI
import Shared

struct PollRowView: View {
    @Environment(\.pollService) var pollService
    let poll: Poll
    let participantCount: Int
    var isOwner: Bool = false
    let timeRange: (earliest: Date, latest: Date)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(poll.title)
                    .font(.headline)

                if isOwner {
                    OwnerBadge()
                }

                Spacer()

                StatusBadge(status: poll.status)
            }

            if let description = poll.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                if let range = timeRange {
                    Text(pollService.formatTimeRange(earliest: range.earliest, latest: range.latest))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No time options")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text("^[\(participantCount) participant](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Previews

#Preview("Active - Owner") {
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

    PollRowView(
        poll: Poll(
            creatorId: UUID(),
            title: "Team Standup",
            description: "Weekly sync meeting",
            status: .active,
            shareCode: "ABC123"
        ),
        participantCount: 5,
        isOwner: true,
        timeRange: (
            earliest: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!,
            latest: Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow)!
        )
    )
    .environment(\.pollService, MockPollService.withSamplePolls)
    .padding()
}

#Preview("Closed") {
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

    PollRowView(
        poll: Poll(
            creatorId: UUID(),
            title: "Sprint Planning",
            description: "Q2 sprint planning session",
            status: .closed,
            shareCode: "DEF456"
        ),
        participantCount: 12,
        isOwner: false,
        timeRange: (
            earliest: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!,
            latest: Calendar.current.date(bySettingHour: 11, minute: 30, second: 0, of: tomorrow)!
        )
    )
    .environment(\.pollService, MockPollService.withSamplePolls)
    .padding()
}

#Preview("Draft - No Time Options") {
    PollRowView(
        poll: Poll(
            creatorId: UUID(),
            title: "Design Review",
            status: .draft,
            shareCode: "GHI789"
        ),
        participantCount: 0,
        isOwner: true,
        timeRange: nil
    )
    .environment(\.pollService, MockPollService.withSamplePolls)
    .padding()
}

#Preview("Archived") {
    PollRowView(
        poll: Poll(
            creatorId: UUID(),
            title: "Retrospective",
            description: "End-of-quarter team retrospective with action items",
            status: .archived,
            shareCode: "JKL012"
        ),
        participantCount: 8,
        isOwner: false,
        timeRange: nil
    )
    .environment(\.pollService, MockPollService.withSamplePolls)
    .padding()
}
