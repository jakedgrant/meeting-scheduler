import SwiftUI
import Shared

/// One time option in a poll: its date and time, the viewer's Yes/Maybe/No answer, any calendar
/// conflict, and optionally a tally of everyone's responses.
struct TimeOptionRow: View {
    /// What the viewer's calendars say about this option.
    enum CalendarStatus {
        case free
        /// Busy, with the device events behind it; empty when a source doesn't name its events.
        case busy([CalendarConflict])
        /// A failed source couldn't cover this option.
        case unchecked
    }

    let option: PollTimeOption
    let pollTimeZone: String
    let now: Date
    let calendarStatus: CalendarStatus
    let responses: ResponseSummary
    let showsResponseTallies: Bool
    /// The viewer's answer, nil until they answer.
    let response: AvailabilityStatus?
    /// Nil hides the response control, such as for a closed poll.
    let onRespond: ((AvailabilityStatus) -> Void)?
    let onShowResponses: () -> Void
    let onShowConflicts: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            mainLine
            calendarLine
            if showsResponseTallies {
                ResponseTallyBar(summary: responses)
            }
        }
        .padding(.vertical, 14)
    }

    private var mainLine: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return layout {
            Button(action: onShowResponses) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(TimeOptionLabel.date(of: option, pollTimeZone: pollTimeZone, now: now))
                        .font(.body)
                        .fontWeight(.semibold)
                    Text(timeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows everyone's responses")

            if let onRespond {
                ResponseControl(selection: response, onSelect: onRespond, scalesWithText: stacked)
            }
        }
    }

    private var timeText: String {
        option.isAllDay
            ? String(localized: "All day")
            : TimeOptionLabel.timeRange(from: option.startTime, to: option.endTime)
    }

    @ViewBuilder
    private var calendarLine: some View {
        switch calendarStatus {
        case .free:
            EmptyView()
        case let .busy(conflicts):
            ConflictRow(conflicts: conflicts, action: onShowConflicts)
        case .unchecked:
            Label("Couldn't check", systemImage: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ResponseControl

/// Yes, Maybe and No as one single-selection control. Once answered, an option stays answered.
struct ResponseControl: View {
    let selection: AvailabilityStatus?
    let onSelect: (AvailabilityStatus) -> Void
    /// Under the date at accessibility text sizes, the buttons grow with the text and share the row's width.
    var scalesWithText = false
    /// Counts changes the person makes, so the haptic follows their choice and not a loaded or
    /// suggested answer.
    @State private var changes = 0

    private static let statuses: [AvailabilityStatus] = [.available, .maybe, .unavailable]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.statuses, id: \.self) { status in
                ResponseButton(status: status, isSelected: selection == status, scalesWithText: scalesWithText) {
                    guard selection != status else { return }
                    onSelect(status)
                    changes += 1
                }
            }
        }
        .sensoryFeedback(.selection, trigger: changes)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your response")
        .accessibilityValue(selection.map(\.answerLabel) ?? String(localized: "No response"))
    }
}

private struct ResponseButton: View {
    let status: AvailabilityStatus
    let isSelected: Bool
    let scalesWithText: Bool
    let action: () -> Void

    /// How much the body text has grown from its default size.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        let scale = scalesWithText ? textScale : 1
        Button(action: action) {
            Image(systemName: status.symbolName)
                .font(.system(size: (isSelected ? 18 : 16) * scale, weight: .medium))
                .foregroundStyle(isSelected ? status.tint : .secondary)
                .frame(minWidth: 44, maxWidth: scalesWithText ? .infinity : nil, minHeight: 36 * scale)
                .background(isSelected ? status.tint.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
                .overlay {
                    if !isSelected {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5)
                    }
                }
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.answerLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - ConflictRow

/// The calendar event that overlaps an option. Tapping it shows the conflict details.
private struct ConflictRow: View {
    let conflicts: [CalendarConflict]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 16))
                Text(TimeOptionLabel.conflict(conflicts))
                    .font(.footnote)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.orange)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.orange.opacity(0.15), in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TimeOptionLabel.conflictAccessibilityLabel(conflicts))
        .accessibilityHint("Shows conflict details")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - ResponseTallyBar

/// Everyone's answers as green, orange and red segments sized by count.
struct ResponseTallyBar: View {
    let summary: ResponseSummary

    var body: some View {
        GeometryReader { proxy in
            let segments = summary.tallySegments
            let total = segments.reduce(0) { $0 + $1.count }
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            HStack(spacing: 2) {
                if segments.isEmpty {
                    RoundedRectangle(cornerRadius: 2).fill(.separator)
                } else {
                    ForEach(segments, id: \.status) { segment in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segment.status.tint)
                            .frame(width: (proxy.size.width - gaps) * CGFloat(segment.count) / CGFloat(total))
                    }
                }
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(
            "\(summary.available) yes, \(summary.maybe) maybe, \(summary.unavailable) no")
    }
}

// MARK: - AvailabilityStatus

private extension AvailabilityStatus {
    var symbolName: String {
        switch self {
        case .available: "checkmark"
        case .maybe: "questionmark"
        case .unavailable: "xmark"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .maybe: .orange
        case .unavailable: .red
        }
    }
}

extension AvailabilityStatus {
    /// "Yes", "Maybe" or "No".
    var answerLabel: String {
        switch self {
        case .available: String(localized: "Yes")
        case .maybe: String(localized: "Maybe")
        case .unavailable: String(localized: "No")
        }
    }
}

#Preview("Rows") {
    let start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now)!
    let option = PollTimeOption(
        id: UUID(), pollId: UUID(), startTime: start, endTime: start.addingTimeInterval(7200),
        isAllDay: false, createdAt: start)
    return List {
        Section("Time options") {
            TimeOptionRow(
                option: option, pollTimeZone: "UTC", now: .now, calendarStatus: .free,
                responses: ResponseSummary(available: 7, maybe: 0, unavailable: 1), showsResponseTallies: true,
                response: .available, onRespond: { _ in }, onShowResponses: {}, onShowConflicts: {})
            TimeOptionRow(
                option: option, pollTimeZone: "UTC", now: .now,
                calendarStatus: .busy([CalendarConflict(
                    title: "Kids' winter concert rehearsal", calendarName: "Family",
                    start: start.addingTimeInterval(-1800), end: start.addingTimeInterval(3600), isAllDay: false)]),
                responses: ResponseSummary(available: 4, maybe: 2, unavailable: 2), showsResponseTallies: true,
                response: .maybe, onRespond: { _ in }, onShowResponses: {}, onShowConflicts: {})
            TimeOptionRow(
                option: option, pollTimeZone: "UTC", now: .now, calendarStatus: .unchecked,
                responses: ResponseSummary(available: 0, maybe: 0, unavailable: 0), showsResponseTallies: true,
                response: nil, onRespond: { _ in }, onShowResponses: {}, onShowConflicts: {})
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
    }
}
