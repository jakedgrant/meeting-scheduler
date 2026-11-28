import Foundation

/// The text a time option row shows for its date, its time range and its calendar conflict.
public enum TimeOptionLabel {
    /// "Tue, Dec 1", with the year only when the option is not in the current year.
    public static func date(
        of option: PollTimeOption,
        pollTimeZone: String?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let date = option.displayDate(pollTimeZone: pollTimeZone, calendar: calendar)
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }

    /// "6–8 PM": each end drops ":00", and both ends share AM/PM when they match. A 24-hour locale
    /// shows "18:00–20:00". A range that ends on a later day names it: "11 PM – 1 AM (Dec 2)". An end
    /// at the following midnight belongs to the start's day.
    public static func timeRange(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let uses12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false
        let symbols = DateFormatter()
        symbols.locale = locale
        symbols.calendar = calendar
        func time(_ date: Date, period: Bool) -> String {
            guard uses12Hour else { return date.formatted(base.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
            let hour = base.hour(.defaultDigits(amPM: .abbreviated))
            let text = date.formatted(calendar.component(.minute, from: date) == 0 ? hour : hour.minute(.twoDigits))
            guard !period else { return text }
            // `amPM: .omitted` pads the hour ("06") on some OS versions, so the shared AM/PM is removed
            // from the formatted text instead.
            let symbol = calendar.component(.hour, from: date) < 12 ? symbols.amSymbol : symbols.pmSymbol
            guard let symbol, !symbol.isEmpty else { return text }
            return text.replacingOccurrences(of: symbol, with: "").trimmingCharacters(in: .whitespaces)
        }
        guard calendar.isDate(start, inSameDayAs: end) else {
            let range = "\(time(start, period: true)) – \(time(end, period: true))"
            guard !calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) else { return range }
            return "\(range) (\(end.formatted(base.month(.abbreviated).day())))"
        }
        let sharesPeriod = (calendar.component(.hour, from: start) < 12) == (calendar.component(.hour, from: end) < 12)
        return "\(time(start, period: !sharesPeriod))–\(time(end, period: true))"
    }

    /// "Conflicts with Design review, 5:30 – 7 PM", "Conflicts with Design review and 2 more", or a
    /// generic line when no event is known, such as a Google Calendar busy period.
    public static func conflict(_ conflicts: [CalendarConflict], calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let first = conflicts.first else {
            return String(localized: "Conflicts with an event on your calendar")
        }
        let title = eventTitle(first)
        if conflicts.count > 1 {
            return String(localized: "Conflicts with \(title) and \(conflicts.count - 1) more")
        }
        return String(localized: "Conflicts with \(title), \(eventTime(first, calendar: calendar, locale: locale))")
    }

    /// "Conflict: Design review, 5:30 – 7 PM" for VoiceOver.
    public static func conflictAccessibilityLabel(
        _ conflicts: [CalendarConflict],
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let first = conflicts.first else {
            return String(localized: "Conflict: an event on your calendar")
        }
        return String(localized: "Conflict: \(eventTitle(first)), \(eventTime(first, calendar: calendar, locale: locale))")
    }

    public static func eventTitle(_ conflict: CalendarConflict) -> String {
        conflict.title.isEmpty ? String(localized: "Untitled event") : conflict.title
    }

    public static func eventTime(_ conflict: CalendarConflict, calendar: Calendar = .current, locale: Locale = .current) -> String {
        conflict.isAllDay
            ? String(localized: "All day")
            : timeRange(from: conflict.start, to: conflict.end, calendar: calendar, locale: locale)
    }
}

/// One answer's share of a tally bar.
public struct TallySegment: Hashable, Sendable {
    public let status: AvailabilityStatus
    public let count: Int
}

public extension ResponseSummary {
    /// The counts as tally bar segments: yes, maybe, then no, without empty ones.
    var tallySegments: [TallySegment] {
        [
            TallySegment(status: .available, count: available),
            TallySegment(status: .maybe, count: maybe),
            TallySegment(status: .unavailable, count: unavailable),
        ].filter { $0.count > 0 }
    }
}
