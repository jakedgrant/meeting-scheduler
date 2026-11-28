import Foundation
import Shared
import Testing

@Suite("Time option labels")
struct TimeOptionLabelTests {
    // Foundation separates an hour from AM/PM with a narrow no-break space (U+202F).
    private let locale = Locale(identifier: "en_US")
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func instant(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func option(_ start: Date, _ end: Date) -> PollTimeOption {
        PollTimeOption(id: UUID(), pollId: UUID(), startTime: start, endTime: end, isAllDay: false, createdAt: start)
    }

    @Test func dateShowsTheYearOnlyOutsideTheCurrentYear() {
        let thisYear = option(instant(12, 1, 18), instant(12, 1, 20))
        let nextYear = option(instant(1, 5, 18, year: 2027), instant(1, 5, 20, year: 2027))
        let now = instant(11, 27, 9)

        #expect(TimeOptionLabel.date(of: thisYear, pollTimeZone: "UTC", now: now, calendar: calendar, locale: locale)
            == "Tue, Dec 1")
        #expect(TimeOptionLabel.date(of: nextYear, pollTimeZone: "UTC", now: now, calendar: calendar, locale: locale)
            .contains("2027"))
    }

    @Test func wholeHoursDropTheMinutesAndShareTheDayPeriod() {
        #expect(TimeOptionLabel.timeRange(from: instant(12, 1, 18), to: instant(12, 1, 20), calendar: calendar, locale: locale)
            == "6–8\u{202F}PM")
        #expect(TimeOptionLabel.timeRange(from: instant(12, 1, 11), to: instant(12, 1, 13), calendar: calendar, locale: locale)
            == "11\u{202F}AM–1\u{202F}PM")
    }

    @Test func aRangeOffTheHourKeepsItsMinutes() {
        #expect(TimeOptionLabel.timeRange(
            from: instant(12, 1, 17, 30), to: instant(12, 1, 19), calendar: calendar, locale: locale) == "5:30–7\u{202F}PM")
        #expect(TimeOptionLabel.timeRange(
            from: instant(12, 1, 18, 5), to: instant(12, 1, 19), calendar: calendar, locale: locale) == "6:05–7\u{202F}PM")
    }

    @Test func aRangeAcrossMidnightNamesTheEndDate() {
        #expect(TimeOptionLabel.timeRange(from: instant(12, 1, 23), to: instant(12, 2, 1), calendar: calendar, locale: locale)
            == "11\u{202F}PM – 1\u{202F}AM (Dec 2)")
    }

    @Test func aRangeEndingAtMidnightStaysOnItsDay() {
        #expect(TimeOptionLabel.timeRange(from: instant(12, 1, 22), to: instant(12, 2, 0), calendar: calendar, locale: locale)
            == "10\u{202F}PM – 12\u{202F}AM")
    }

    @Test func aTwentyFourHourLocaleKeepsMinutes() {
        #expect(TimeOptionLabel.timeRange(
            from: instant(12, 1, 18), to: instant(12, 1, 20), calendar: calendar, locale: Locale(identifier: "en_GB"))
            == "18:00–20:00")
    }

    @Test func conflictNamesTheFirstEventAndCountsTheRest() {
        let rehearsal = CalendarConflict(
            title: "Kids' winter concert rehearsal", calendarName: "Family",
            start: instant(12, 2, 17, 30), end: instant(12, 2, 19), isAllDay: false)
        let dinner = CalendarConflict(
            title: "Dinner", calendarName: "Home", start: instant(12, 2, 19), end: instant(12, 2, 20), isAllDay: false)

        #expect(TimeOptionLabel.conflict([rehearsal], calendar: calendar, locale: locale)
            == "Conflicts with Kids' winter concert rehearsal, 5:30–7\u{202F}PM")
        #expect(TimeOptionLabel.conflict([rehearsal, dinner], calendar: calendar, locale: locale)
            == "Conflicts with Kids' winter concert rehearsal and 1 more")
        #expect(TimeOptionLabel.conflict([], calendar: calendar, locale: locale)
            == "Conflicts with an event on your calendar")
    }

    @Test func tallySegmentsSkipEmptyCountsInOrder() {
        let summary = ResponseSummary(available: 3, maybe: 0, unavailable: 1)
        #expect(summary.tallySegments.map(\.status) == [.available, .unavailable])
        #expect(ResponseSummary(available: 0, maybe: 0, unavailable: 0).tallySegments.isEmpty)
    }
}
