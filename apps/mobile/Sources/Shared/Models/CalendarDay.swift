import Foundation

/// A calendar date with no zone (F21). See docs/date-time-contract.md.
///
/// Wall times and all-day boundaries are resolved in an explicit IANA zone with
/// the same rules as the web and Android clients and the shared fixtures.
public struct CalendarDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public init?(year: Int, month: Int, day: Int) {
        guard let date = Self.utc.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = Self.utc.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// Parses `YYYY-MM-DD`.
    public init?(_ value: String) {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The calendar date of an instant in zone.
    public init(_ instant: Date, in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        self.year = parts.year!; self.month = parts.month!; self.day = parts.day!
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private var utcMidnight: Date { Self.utc.date(from: DateComponents(year: year, month: month, day: day))! }

    public func adding(days: Int) -> CalendarDay {
        CalendarDay(Self.utc.date(byAdding: .day, value: days, to: utcMidnight)!, in: Self.utc.timeZone)
    }

    /// Every date from start through end inclusive; empty when end precedes start.
    public static func range(from start: CalendarDay, through end: CalendarDay) -> [CalendarDay] {
        var dates: [CalendarDay] = []
        var current = start
        while current <= end { dates.append(current); current = current.adding(days: 1) }
        return dates
    }

    private func candidates(hour: Int, minute: Int, in zone: TimeZone) -> (matches: [Date], all: [Date]) {
        let naive = utcMidnight.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        let offsets = Set([-86_400.0, 0, 86_400].map { zone.secondsFromGMT(for: naive.addingTimeInterval($0)) })
        let all = offsets.map { naive.addingTimeInterval(TimeInterval(-$0)) }.sorted()
        let matches = all.filter { $0.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: $0))) == naive }
        return (matches, all)
    }

    /// A wall time in zone. A time skipped by a clock change is rejected; a repeated time uses its first occurrence.
    public func instant(hour: Int, minute: Int, in zone: TimeZone) throws(CalendarTimeError) -> Date {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { throw .invalidTime }
        guard let first = candidates(hour: hour, minute: minute, in: zone).matches.first else { throw .nonexistentLocalTime }
        return first
    }

    /// The first instant of this date in zone; after a skipped midnight, the first time after the gap.
    public func start(in zone: TimeZone) -> Date {
        let found = candidates(hour: 0, minute: 0, in: zone)
        return found.matches.first ?? found.all.last!
    }

    /// One calendar date: its start through the next date's start (exclusive).
    public func allDayInterval(in zone: TimeZone) -> (start: Date, end: Date) {
        (start(in: zone), adding(days: 1).start(in: zone))
    }

    /// A response due date accepts responses through the end of that date in zone.
    public func deadline(in zone: TimeZone) -> Date { adding(days: 1).start(in: zone) }

    /// The due date a stored deadline represents (the date its final moment falls on).
    public static func dueDate(for deadline: Date, in zone: TimeZone) -> CalendarDay {
        CalendarDay(deadline.addingTimeInterval(-1), in: zone)
    }

    /// The local noon of this date in the device calendar, for date pickers and labels.
    public func pickerDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? utcMidnight
    }
}

public enum CalendarTimeError: Error, Equatable, LocalizedError {
    case invalidTime, nonexistentLocalTime, endNotAfterStart
    public var errorDescription: String? {
        switch self {
        case .invalidTime: "Choose a valid time."
        case .nonexistentLocalTime: "A selected time is skipped by a clock change in this time zone. Choose another time."
        case .endNotAfterStart: "End time must be after start time."
        }
    }
}

public extension PollCreationOption {
    /// A timed option on a calendar date, resolved in zone.
    static func timed(on day: CalendarDay, start: (hour: Int, minute: Int), end: (hour: Int, minute: Int),
                      in zone: TimeZone) throws(CalendarTimeError) -> PollCreationOption {
        guard end.hour * 60 + end.minute > start.hour * 60 + start.minute else { throw .endNotAfterStart }
        return PollCreationOption(startTime: try day.instant(hour: start.hour, minute: start.minute, in: zone),
                                  endTime: try day.instant(hour: end.hour, minute: end.minute, in: zone), isAllDay: false)
    }

    static func allDay(on day: CalendarDay, in zone: TimeZone) -> PollCreationOption {
        let interval = day.allDayInterval(in: zone)
        return PollCreationOption(startTime: interval.start, endTime: interval.end, isAllDay: true)
    }
}

public extension PollTimeOption {
    /// The calendar date of an all-day option, read in its poll's zone (legacy 23:59 ends included).
    func allDayDate(pollTimeZone identifier: String?) -> CalendarDay {
        CalendarDay(startTime, in: identifier.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!)
    }

    /// The date to show: the poll-zone calendar date for all-day options, otherwise the start instant.
    func displayDate(pollTimeZone identifier: String?, calendar: Calendar = .current) -> Date {
        isAllDay ? allDayDate(pollTimeZone: identifier).pickerDate(calendar: calendar) : startTime
    }
}
