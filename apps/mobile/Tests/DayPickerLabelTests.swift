import XCTest
@testable import MeetingSchedulerApp

final class DayPickerLabelTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testLabelUsesWeekdayShortMonthDayYear() {
        let calendar = calendar("America/New_York")
        let date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 22, hour: 9))!
        XCTAssertEqual(DayPicker.label(for: date, calendar: calendar), "Tue. Dec 22, 2026")
    }

    func testLabelReadsTheDayInTheCalendarsZone() {
        let calendar = calendar("Pacific/Auckland")
        let date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 26, hour: 1))!
        XCTAssertEqual(DayPicker.label(for: date, calendar: calendar), "Sat. Dec 26, 2026")
    }
}
