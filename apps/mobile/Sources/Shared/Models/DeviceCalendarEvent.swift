import Foundation

/// A finalized poll's meeting as the device calendar records it.
public struct DeviceCalendarEvent: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    /// Set when the final option is all-day: its calendar date in the poll's zone. The device
    /// calendar stores it as a floating date rather than the `start`–`end` instants.
    public let allDayDate: CalendarDay?
    public let notes: String?
    public let location: String?

    public init(
        title: String, start: Date, end: Date, allDayDate: CalendarDay?, notes: String?, location: String?
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDayDate = allDayDate
        self.notes = notes
        self.location = location
    }

    /// The finalized meeting of `poll`, or nil until the poll has a final time.
    ///
    /// Finalization copies the chosen option's interval onto the poll, so the all-day option is
    /// the one with that interval.
    public init?(finalTimeOf poll: Poll, options: [PollTimeOption]) {
        guard let start = poll.selectedStartTime, let end = poll.selectedEndTime else { return nil }
        let allDayOption = options.first { $0.startTime == start && $0.endTime == end && $0.isAllDay }
        self.init(
            title: poll.title, start: start, end: end,
            allDayDate: allDayOption?.allDayDate(pollTimeZone: poll.timezone),
            notes: poll.description, location: poll.location)
    }
}

/// The outcome of adding an event to the device calendar.
public enum DeviceCalendarAddResult: Equatable, Sendable {
    case added
    /// The person hasn't allowed calendar access, or a restriction prevents it.
    case accessDenied
    /// Access was allowed but the calendar didn't save the event.
    case failed
}
