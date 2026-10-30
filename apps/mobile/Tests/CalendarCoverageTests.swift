import EventKit
import Foundation
import Synchronization
import XCTest
@testable import Shared

/// Replies to calendar Edge Function calls with canned responses keyed by function name.
private final class CoverageURLProtocol: URLProtocol {
    static let replies = Mutex<[String: (status: Int, body: String)]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let function = request.url?.lastPathComponent ?? ""
        guard let reply = Self.replies.withLock({ $0[function] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// F16 calendar coverage; see docs/calendar-coverage.md.
@MainActor
final class CalendarCoverageTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func day(_ value: String) -> CalendarDay { CalendarDay(value)! }
    private func instant(_ value: String) -> Date { try! Date(value, strategy: .iso8601) }

    private func allDay(_ date: String, in zone: String) -> PollTimeOption {
        let interval = day(date).allDayInterval(in: TimeZone(identifier: zone)!)
        return PollTimeOption(id: UUID(), pollId: UUID(), startTime: interval.start, endTime: interval.end, isAllDay: true, createdAt: Date())
    }

    private func timed(_ date: String, _ start: (Int, Int), _ end: (Int, Int), in zone: TimeZone) -> PollTimeOption {
        PollTimeOption(id: UUID(), pollId: UUID(),
                       startTime: try! day(date).instant(hour: start.0, minute: start.1, in: zone),
                       endTime: try! day(date).instant(hour: end.0, minute: end.1, in: zone), isAllDay: false, createdAt: Date())
    }

    private func period(
        allDay: Bool = false, start: Date, end: Date, availability: EKEventAvailability = .busy,
        status: EKEventStatus = .confirmed, declined: Bool = false, calendarType: EKCalendarType = .calDAV
    ) -> DeviceBusyPeriod? {
        DeviceBusyPeriod.of(isAllDay: allDay, start: start, end: end, availability: availability, status: status,
                            declined: declined, calendarType: calendarType, in: chicago)
    }

    func testFreeCancelledDeclinedAndHolidayEventsAreNotBusy() {
        let start = instant("2026-11-02T15:00:00Z"), end = instant("2026-11-02T16:00:00Z")
        XCTAssertNil(period(start: start, end: end, availability: .free))
        XCTAssertNil(period(start: start, end: end, status: .canceled))
        XCTAssertNil(period(start: start, end: end, declined: true))
        XCTAssertEqual(period(start: start, end: end, availability: .tentative), .timed(start: start, end: end))
        // Timed events keep counting when the source reports no availability.
        XCTAssertEqual(period(start: start, end: end, availability: .notSupported), .timed(start: start, end: end))

        // EventKit all-day events run from local midnight to 23:59:59 on the last date.
        let dayStart = day("2026-11-02").start(in: chicago)
        let dayEnd = day("2026-11-03").start(in: chicago).addingTimeInterval(-1)
        XCTAssertEqual(period(allDay: true, start: dayStart, end: dayEnd), .allDay(first: day("2026-11-02"), end: day("2026-11-03")))
        XCTAssertEqual(period(allDay: true, start: dayStart, end: day("2026-11-03").start(in: chicago)),
                       .allDay(first: day("2026-11-02"), end: day("2026-11-03")))
        XCTAssertNil(period(allDay: true, start: dayStart, end: dayEnd, availability: .free))
        XCTAssertNil(period(allDay: true, start: dayStart, end: dayEnd, availability: .notSupported))
        XCTAssertNil(period(allDay: true, start: dayStart, end: dayEnd, calendarType: .birthday))
        XCTAssertNil(period(allDay: true, start: dayStart, end: dayEnd, calendarType: .subscription))
    }

    func testBusyAllDayEventsMatchAllDayOptionsByDateInEveryPollZone() {
        let event = DeviceBusyPeriod.allDay(first: day("2026-11-02"), end: day("2026-11-03"))
        for zone in ["Pacific/Auckland", "America/Chicago", "America/Santiago", "UTC"] {
            let before = allDay("2026-11-01", in: zone), same = allDay("2026-11-02", in: zone), after = allDay("2026-11-03", in: zone)
            XCTAssertEqual(DeviceBusyPeriod.busyOptionIds([before, same, after], pollTimeZone: zone, periods: [event], deviceZone: chicago),
                           [same.id], zone)
        }
    }

    func testAllDayEventsCoverTheirDatesInTheDeviceZoneForTimedOptions() {
        // A two-date event (Nov 2 and 3) after the Chicago fall-back day, Nov 1.
        let event = DeviceBusyPeriod.allDay(first: day("2026-11-02"), end: day("2026-11-04"))
        let lateBefore = timed("2026-11-01", (23, 0), (23, 59), in: chicago)
        let firstMorning = timed("2026-11-02", (0, 0), (1, 0), in: chicago)
        let lastNight = timed("2026-11-03", (23, 0), (23, 59), in: chicago)
        let after = timed("2026-11-04", (0, 0), (1, 0), in: chicago)
        // 08:00 Nov 3 in Auckland is mid-afternoon Nov 2 in Chicago.
        let otherZone = timed("2026-11-03", (8, 0), (9, 0), in: TimeZone(identifier: "Pacific/Auckland")!)
        XCTAssertEqual(
            DeviceBusyPeriod.busyOptionIds([lateBefore, firstMorning, lastNight, after, otherZone], pollTimeZone: "UTC",
                                           periods: [event], deviceZone: chicago),
            [firstMorning.id, lastNight.id, otherZone.id])
    }

    func testTimedEventsOverlapStoredOptionIntervalsWithExclusiveEnds() {
        let meeting = DeviceBusyPeriod.timed(start: instant("2026-11-02T15:00:00Z"), end: instant("2026-11-02T16:00:00Z"))
        let touchingBefore = timed("2026-11-02", (8, 0), (9, 0), in: chicago)
        let overlapping = timed("2026-11-02", (9, 30), (10, 30), in: chicago)
        let touchingAfter = timed("2026-11-02", (10, 0), (11, 0), in: chicago)
        let sameDate = allDay("2026-11-02", in: "America/Chicago")
        let otherDate = allDay("2026-11-03", in: "America/Chicago")
        XCTAssertEqual(
            DeviceBusyPeriod.busyOptionIds([touchingBefore, overlapping, touchingAfter, sameDate, otherDate],
                                           pollTimeZone: "America/Chicago", periods: [meeting], deviceZone: chicago),
            [overlapping.id, sameDate.id])
    }

    func testAFailedSourceLeavesEveryNonBusyOptionUnchecked() {
        let a = UUID(), b = UUID(), c = UUID()
        let checked = CalendarCheckResult(optionIds: [a, b, c], sources: [(.appleCalendar, [a]), (.googleCalendar, [UUID()])])
        XCTAssertEqual(checked.busyIds, [a])
        XCTAssertEqual(checked.uncheckedIds, [])
        XCTAssertEqual(checked.checkedSources, [.appleCalendar, .googleCalendar])

        let partial = CalendarCheckResult(optionIds: [a, b, c], sources: [(.appleCalendar, [a]), (.googleCalendar, nil)])
        XCTAssertEqual(partial.busyIds, [a])
        XCTAssertEqual(partial.uncheckedIds, [b, c])
        XCTAssertEqual(partial.checkedSources, [.appleCalendar])
        XCTAssertEqual(partial.failedSources, [.googleCalendar])
        XCTAssertEqual(CalendarCheckResult(optionIds: [a], sources: []), .none)
    }

    func testGoogleFailuresAndUnrecognizedCoverageAreUncheckedNotConflictFree() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverageURLProtocol.self]
        let api = SupabaseService.apiClient(url: URL(string: "https://calendar-coverage.invalid")!, key: "test-only",
                                            transport: URLSession(configuration: configuration))
        let suite = "calendar-coverage-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            CoverageURLProtocol.replies.withLock { $0 = [:] }
        }
        let account = UUID()
        let service = CalendarService(preferences: preferences, clientFactory: { api },
                                      requestCredentials: { AccountRequestCredentials(accountId: account, generation: 1, accessToken: "token") })
        service.accountDidChange(to: account)
        CoverageURLProtocol.replies.withLock {
            $0["calendar-connection"] = (200, #"{"connected":true,"accountEmail":"a@example.test","requiresReconnect":false,"revocationPending":false}"#)
        }
        await service.refreshGoogleCalendarConnection()
        XCTAssertTrue(service.googleCalendarEnabled)

        let busy = timed("2026-11-02", (9, 0), (10, 0), in: chicago), free = timed("2026-11-02", (11, 0), (12, 0), in: chicago)
        let cases: [(name: String, status: Int, body: String, checked: Bool)] = [
            ("primary", 200, #"{"success":true,"coverage":"primary","conflictingIds":["\#(busy.id.uuidString)"]}"#, true),
            ("provider error", 503, #"{"error":"provider_unavailable"}"#, false),
            ("unrecognized coverage", 200, #"{"success":true,"coverage":"all","conflictingIds":[]}"#, false),
            ("missing coverage", 200, #"{"success":true,"conflictingIds":[]}"#, false),
        ]
        for testCase in cases {
            CoverageURLProtocol.replies.withLock { $0["check-calendar-conflicts"] = (testCase.status, testCase.body) }
            let result = await service.checkConflicts(for: [busy, free], pollTimeZone: "America/Chicago")
            XCTAssertEqual(result.busyIds, testCase.checked ? [busy.id] : [], testCase.name)
            XCTAssertEqual(result.uncheckedIds, testCase.checked ? [] : [busy.id, free.id], testCase.name)
            XCTAssertEqual(result.checkedSources, testCase.checked ? [.googleCalendar] : [], testCase.name)
            XCTAssertEqual(result.failedSources, testCase.checked ? [] : [.googleCalendar], testCase.name)
            XCTAssertFalse(service.googleCalendarLoading, testCase.name)
        }
    }
}
