import XCTest
@testable import Shared

/// F21: CalendarDay and the creation encoders match packages/shared-config/date-time-fixtures.json.
final class DateTimeContractTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Range: Decodable { let name, start, end: String; let dates: [String] }
        struct Timed: Decodable {
            let name, zone, date, start, end: String
            let start_time, end_time, error: String?
        }
        struct AllDay: Decodable { let name, zone, date, start_time, end_time: String }
        struct Deadline: Decodable { let name, zone, date, closes_at: String }
        struct OptionDate: Decodable { let name, zone, start_time, end_time, date: String }
        let date_ranges: [Range]
        let timed_options: [Timed]
        let all_day_options: [AllDay]
        let deadlines: [Deadline]
        let option_dates: [OptionDate]
    }

    private static let fixtures: Fixtures = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("packages/shared-config/date-time-fixtures.json")
        return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }()

    private func day(_ value: String) -> CalendarDay { CalendarDay(value)! }
    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }
    private func instant(_ value: String) -> Date { try! Date(value, strategy: .iso8601) }
    private func hm(_ value: String) -> (hour: Int, minute: Int) {
        let parts = value.split(separator: ":").map { Int($0)! }
        return (parts[0], parts[1])
    }

    func testDateRangesContainEachCalendarDateOnce() {
        for range in Self.fixtures.date_ranges {
            XCTAssertEqual(CalendarDay.range(from: day(range.start), through: day(range.end)).map(\.description), range.dates, range.name)
        }
    }

    func testTimedOptionsRejectGapsAndUseFirstRepeatedTime() {
        for c in Self.fixtures.timed_options {
            let result = Result { () throws(CalendarTimeError) in
                try PollCreationOption.timed(on: day(c.date), start: hm(c.start), end: hm(c.end), in: zone(c.zone))
            }
            switch (result, c.error) {
            case let (.success(option), nil):
                XCTAssertEqual(option.startTime, instant(c.start_time!), c.name)
                XCTAssertEqual(option.endTime, instant(c.end_time!), c.name)
                XCTAssertFalse(option.isAllDay)
            case let (.failure(error), "nonexistent_local_time"?): XCTAssertEqual(error, .nonexistentLocalTime, c.name)
            case let (.failure(error), "end_not_after_start"?): XCTAssertEqual(error, .endNotAfterStart, c.name)
            default: XCTFail("\(c.name): \(result) expected \(c.error ?? "success")")
            }
        }
    }

    func testAllDayOptionsUseExclusiveNextDayStart() {
        for c in Self.fixtures.all_day_options {
            let option = PollCreationOption.allDay(on: day(c.date), in: zone(c.zone))
            XCTAssertEqual(option.startTime, instant(c.start_time), c.name)
            XCTAssertEqual(option.endTime, instant(c.end_time), c.name)
            XCTAssertTrue(option.isAllDay)
        }
    }

    func testDeadlinesCoverTheWholeDueDateAndRestoreToIt() {
        for c in Self.fixtures.deadlines {
            let deadline = day(c.date).deadline(in: zone(c.zone))
            XCTAssertEqual(deadline, instant(c.closes_at), c.name)
            XCTAssertEqual(CalendarDay.dueDate(for: deadline, in: zone(c.zone)), day(c.date), c.name)
        }
    }

    func testAllDayDatesAreReadInThePollZoneForEveryViewer() {
        for c in Self.fixtures.option_dates {
            let option = PollTimeOption(id: UUID(), pollId: UUID(), startTime: instant(c.start_time), endTime: instant(c.end_time), isAllDay: true, createdAt: Date())
            XCTAssertEqual(option.allDayDate(pollTimeZone: c.zone), day(c.date), c.name)
            for viewer in ["Pacific/Honolulu", "Pacific/Kiritimati", "America/Chicago", "UTC"] {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone(viewer)
                XCTAssertEqual(CalendarDay(option.displayDate(pollTimeZone: c.zone, calendar: calendar), in: zone(viewer)), day(c.date), "\(c.name) for \(viewer)")
            }
        }
    }

    func testPayloadEncodesCanonicalInstants() throws {
        let c = Self.fixtures.all_day_options.first { $0.name == "Chicago 25-hour day" }!
        let payload = PollCreationPayload(title: "Dates", timezone: c.zone, closesAt: day(c.date).deadline(in: zone(c.zone)),
                                          timeOptions: [.allDay(on: day(c.date), in: zone(c.zone))])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        let option = (json["time_options"] as! [[String: Any]])[0]
        XCTAssertEqual(option["start_time"] as? String, c.start_time)
        XCTAssertEqual(option["end_time"] as? String, c.end_time)
        XCTAssertEqual(option["is_all_day"] as? Bool, true)
        XCTAssertEqual(json["closes_at"] as? String, "2026-11-02T06:00:00Z")
    }

    func testInvalidCalendarDatesAreRejected() {
        for value in ["2026-02-29", "2026-13-01", "2026-1-01", ""] { XCTAssertNil(CalendarDay(value), value) }
        XCTAssertEqual(day("2028-02-28").adding(days: 1), day("2028-02-29"))
        XCTAssertThrowsError(try day("2026-11-01").instant(hour: 24, minute: 0, in: zone("UTC")))
    }
}
