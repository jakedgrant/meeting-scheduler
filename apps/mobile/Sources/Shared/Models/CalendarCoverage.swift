import EventKit
import Foundation

/// The outcome of one calendar check across the enabled sources (F16).
/// See docs/calendar-coverage.md.
public struct CalendarCheckResult: Equatable, Sendable {
    /// Options a checked source reports as busy.
    public private(set) var busyIds: Set<UUID> = []
    /// Options that are not busy but that a failed source could not cover.
    public private(set) var uncheckedIds: Set<UUID> = []
    public private(set) var checkedSources: [CalendarSource] = []
    public private(set) var failedSources: [CalendarSource] = []

    public static let none = CalendarCheckResult()

    public init() {}

    /// Combines per-source results: nil means the source could not be checked.
    public init(optionIds: Set<UUID>, sources: [(CalendarSource, Set<UUID>?)]) {
        for (source, busy) in sources {
            if let busy {
                checkedSources.append(source)
                busyIds.formUnion(busy.intersection(optionIds))
            } else {
                failedSources.append(source)
            }
        }
        if !failedSources.isEmpty { uncheckedIds = optionIds.subtracting(busyIds) }
    }
}

/// A period a device calendar event makes busy.
public enum DeviceBusyPeriod: Hashable, Sendable {
    /// A timed event, as instants.
    case timed(start: Date, end: Date)
    /// An all-day event from its first date to its end date (exclusive), floating in the device zone.
    case allDay(first: CalendarDay, end: CalendarDay)

    /// The busy period of an EventKit event, or nil when the event does not count as busy.
    ///
    /// Free, cancelled and declined events never count. An all-day event counts unless it has no
    /// availability or comes from a birthday or subscribed calendar, which hold birthdays and holidays.
    public static func of(
        isAllDay: Bool,
        start: Date,
        end: Date,
        availability: EKEventAvailability,
        status: EKEventStatus,
        declined: Bool,
        calendarType: EKCalendarType,
        in deviceZone: TimeZone
    ) -> DeviceBusyPeriod? {
        guard end > start, availability != .free, status != .canceled, !declined else { return nil }
        guard isAllDay else { return .timed(start: start, end: end) }
        guard availability != .notSupported, calendarType != .birthday, calendarType != .subscription else { return nil }
        // EventKit ends an all-day event at 23:59:59 on its last date; some sources use the next midnight.
        let last = CalendarDay(end.addingTimeInterval(-1), in: deviceZone)
        return .allDay(first: CalendarDay(start, in: deviceZone), end: last.adding(days: 1))
    }

    /// Option IDs that overlap any busy period.
    ///
    /// All-day options and all-day events compare calendar dates; otherwise an all-day event covers
    /// its dates in the device zone and an all-day option covers its stored interval.
    public static func busyOptionIds(
        _ options: [PollTimeOption],
        pollTimeZone: String?,
        periods: [DeviceBusyPeriod],
        deviceZone: TimeZone
    ) -> Set<UUID> {
        Set(options.filter { option in
            periods.contains { period in
                switch period {
                case let .allDay(first, end) where option.isAllDay:
                    let date = option.allDayDate(pollTimeZone: pollTimeZone)
                    return first <= date && date < end
                case let .allDay(first, end):
                    return first.start(in: deviceZone) < option.endTime && end.start(in: deviceZone) > option.startTime
                case let .timed(start, end):
                    return start < option.endTime && end > option.startTime
                }
            }
        }.map(\.id))
    }
}
