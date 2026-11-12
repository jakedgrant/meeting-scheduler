import SwiftUI
import Shared

/// Shows which calendar events make a poll option busy, from the "Busy" badge.
struct CalendarConflictsView: View {
    let option: PollTimeOption
    let pollTimeZone: String
    let sources: [CalendarSource]
    let loadConflicts: () async -> [CalendarConflict]

    @Environment(\.dismiss) private var dismiss
    @State private var conflicts: [CalendarConflict] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section("Proposed time") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.displayDate(pollTimeZone: pollTimeZone), style: .date)
                            .font(.headline)
                        Text(timeText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if sources.contains(.appleCalendar) {
                    appleSection
                }
                if sources.contains(.googleCalendar) {
                    Section("Google Calendar (primary calendar)") {
                        Text("Google Calendar says you're busy during this time. It doesn't share which event.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Calendar Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if sources.contains(.appleCalendar) { conflicts = await loadConflicts() }
                isLoading = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var appleSection: some View {
        Section("Apple Calendar") {
            if isLoading {
                ProgressView()
            } else if conflicts.isEmpty {
                Text("The conflicting event is no longer on your calendar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conflict.title.isEmpty ? String(localized: "Untitled event") : conflict.title)
                            .font(.headline)
                        Text(timeText(of: conflict))
                            .font(.subheadline)
                        Text(conflict.calendarName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var timeText: String {
        option.isAllDay
            ? String(localized: "All day")
            : "\(option.startTime.formatted(date: .omitted, time: .shortened)) - \(option.endTime.formatted(date: .omitted, time: .shortened))"
    }

    private func timeText(of conflict: CalendarConflict) -> String {
        if conflict.isAllDay { return String(localized: "All day") }
        let sameDay = Calendar.current.isDate(conflict.start, inSameDayAs: conflict.end)
        let start = conflict.start.formatted(date: .abbreviated, time: .shortened)
        let end = conflict.end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return "\(start) - \(end)"
    }
}

#Preview("Apple and Google") {
    let start = Date()
    return CalendarConflictsView(
        option: PollTimeOption(
            id: UUID(), pollId: UUID(), startTime: start, endTime: start.addingTimeInterval(3600),
            isAllDay: false, createdAt: start),
        pollTimeZone: "UTC",
        sources: [.appleCalendar, .googleCalendar],
        loadConflicts: {
            [CalendarConflict(
                title: "Design review", calendarName: "Work", start: start.addingTimeInterval(-900),
                end: start.addingTimeInterval(1800), isAllDay: false)]
        }
    )
}
