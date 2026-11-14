import XCTest
import SwiftUI
import UIKit
@testable import MeetingSchedulerApp
@testable import Shared

@MainActor
private final class MemoryDraftStore: PollCreationDraftStore {
    var data: [UUID: Data] = [:]
    func read(accountId: UUID) throws -> Data? { data[accountId] }
    func write(_ value: Data?, accountId: UUID) throws { data[accountId] = value }
}

@MainActor
final class PollCreationModelTests: XCTestCase {
    private let account = UUID()
    private let zone = TimeZone(identifier: "America/Chicago")!
    /// 2026-11-02 15:30 in Chicago.
    private let now = Date(timeIntervalSince1970: 1_793_655_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func model(
        polls: MockPollService = MockPollService(), store: MemoryDraftStore = MemoryDraftStore()
    ) -> PollCreationModel {
        let calendar = calendar
        let model = PollCreationModel(
            auth: MockAuthService(isAuthenticated: true, currentUserId: account), polls: polls, clock: .fixed(now),
            calendar: { calendar }, editor: PollCreationEditor(store: store))
        XCTAssertTrue(model.options.isEmpty)
        model.selectCurrentAccount()
        return model
    }

    private func wallTime(_ date: Date) -> [Int] {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!]
    }

    func testNewFormStartsWithoutTimeOptionsAndAddsOneOnRequest() {
        let model = model()
        XCTAssertTrue(model.options.isEmpty)
        model.addOption()
        XCTAssertEqual(model.options.count, 1)
        XCTAssertEqual(wallTime(model.options[0].startTime), [2026, 11, 2, 9, 0])
        XCTAssertEqual(wallTime(model.options[0].endTime), [2026, 11, 2, 10, 0])
        XCTAssertEqual(model.startOfToday, calendar.startOfDay(for: now))
        XCTAssertFalse(model.canSubmit)
    }

    func testTimedPollWithNoOptionsDoesNotSubmit() async {
        let polls = MockPollService()
        var dispatched = false
        polls.creator = { _ in dispatched = true; throw CancellationError() }
        let model = model(polls: polls)
        model.title = "Planning"

        await model.create {}?.value

        XCTAssertFalse(dispatched)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.options.isEmpty)
    }

    func testDateRangeAddsOneSortedOptionPerDayAndRejectsInvalidRanges() {
        let model = model()
        model.rangeStartDate = now.addingTimeInterval(2 * 86_400)
        model.rangeEndDate = now
        model.addDateRange()
        XCTAssertEqual(model.errorMessage, "Start date must be before or equal to end date")
        XCTAssertTrue(model.options.isEmpty)

        model.rangeEndDate = now.addingTimeInterval(2 * 86_400)
        model.rangeStartTime = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: now)!
        model.rangeEndTime = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        model.addDateRange()
        XCTAssertEqual(model.errorMessage, "End time must be after start time")
        XCTAssertTrue(model.options.isEmpty)

        model.rangeStartDate = now
        model.rangeStartTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        model.addDateRange()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.options.map { calendar.component(.day, from: $0.date) }, [2, 3, 4])
        // The range fields return to today's defaults.
        XCTAssertEqual(model.rangeEndDate, now)
        XCTAssertEqual(wallTime(model.rangeStartTime), [2026, 11, 2, 9, 0])
    }

    func testRemovingTheLastOptionIsIgnored() {
        let model = model()
        model.addOption()
        model.removeOption(id: model.options[0].id)
        XCTAssertEqual(model.options.count, 1)
        model.addOption()
        model.removeOption(id: model.options[0].id)
        XCTAssertEqual(model.options.count, 1)
    }

    func testDateRangePickersAndSubmissionKeepSelectedWallTimesOnEveryDay() async throws {
        let polls = MockPollService()
        var submitted: [CreatePollRequest] = []
        polls.creator = { request in
            submitted.append(request)
            return PollCreationResult(poll: Poll(creatorId: self.account, title: request.payload.title, status: .active), timeOptions: [])
        }
        let model = model(polls: polls)
        model.title = "Afternoon planning"
        model.rangeStartDate = calendar.date(byAdding: .day, value: 3, to: now)!
        model.rangeEndDate = calendar.date(byAdding: .day, value: 5, to: now)!
        model.rangeStartTime = calendar.date(bySettingHour: 14, minute: 15, second: 0, of: now)!
        model.rangeEndTime = calendar.date(bySettingHour: 16, minute: 45, second: 0, of: now)!
        model.addDateRange()

        // Render the real option rows: bounds on a time-only picker can clamp its
        // displayed time even when the model still contains the selected wall time.
        let rows = VStack {
            ForEach(model.options.indices, id: \.self) { index in
                TimeOptionView(option: Binding(
                    get: { model.options[index] }, set: { model.options[index] = $0 }
                ), number: index + 1, now: self.now, calendar: self.calendar)
            }
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, zone)
        let host = UIHostingController(rootView: rows)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()

        func pickers(in view: UIView) -> [UIDatePicker] {
            (view as? UIDatePicker).map { [$0] } ?? view.subviews.flatMap { pickers(in: $0) }
        }
        let times = pickers(in: host.view).filter { $0.datePickerMode == .time }
        XCTAssertEqual(times.count, 6)
        XCTAssertEqual(times.map { Array(wallTime($0.date).suffix(2)) }, [
            [14, 15], [16, 45], [14, 15], [16, 45], [14, 15], [16, 45],
        ])

        await model.create {}?.value

        let options = try XCTUnwrap(submitted.first?.payload.timeOptions)
        XCTAssertEqual(options.map { wallTime($0.startTime) }, [
            [2026, 11, 5, 14, 15], [2026, 11, 6, 14, 15], [2026, 11, 7, 14, 15],
        ])
        XCTAssertEqual(options.map { wallTime($0.endTime) }, [
            [2026, 11, 5, 16, 45], [2026, 11, 6, 16, 45], [2026, 11, 7, 16, 45],
        ])
        XCTAssertTrue(options.allSatisfy { !$0.isAllDay })
    }

    func testEditingRangeOptionsStillRejectsEqualAndReversedEndTimesBeforeSubmission() {
        let model = model()
        model.title = "Planning"
        model.rangeStartDate = calendar.date(byAdding: .day, value: 3, to: now)!
        model.rangeEndDate = model.rangeStartDate
        model.addDateRange()

        for endHour in [9, 8] {
            model.options[0].endTime = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: now)!
            XCTAssertNil(model.create {})
            XCTAssertEqual(model.errorMessage, CalendarTimeError.endNotAfterStart.localizedDescription)
        }
    }

    func testOptionEndingOnALaterDaySubmitsItsEndOnThatDay() async throws {
        let polls = MockPollService()
        var submitted: [CreatePollRequest] = []
        polls.creator = { request in
            submitted.append(request)
            return PollCreationResult(poll: Poll(creatorId: self.account, title: request.payload.title, status: .active), timeOptions: [])
        }
        let model = model(polls: polls)
        model.title = "Overnight"
        model.addOption()
        model.options[0].date = now.addingTimeInterval(3 * 86_400)
        model.options[0].startTime = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: now)!
        model.options[0].endTime = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: now)!

        XCTAssertNil(model.create {})
        XCTAssertEqual(model.errorMessage, CalendarTimeError.endNotAfterStart.localizedDescription)

        model.options[0].endDayOffset = 1
        await model.create {}?.value

        let option = try XCTUnwrap(submitted.first?.payload.timeOptions.first)
        XCTAssertEqual(wallTime(option.startTime), [2026, 11, 5, 22, 0])
        XCTAssertEqual(wallTime(option.endTime), [2026, 11, 6, 2, 0])
    }

    func testUnresolvedOvernightSubmissionRestoresItsEndDay() async {
        let store = MemoryDraftStore()
        let polls = MockPollService()
        polls.creator = { _ in throw PollCreationError.transport }
        let first = model(polls: polls, store: store)
        first.title = "Overnight"
        first.addOption()
        first.options[0].startTime = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: now)!
        first.options[0].endTime = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: now)!
        first.options[0].endDayOffset = 1
        await first.create {}?.value

        let restored = model(polls: polls, store: store)

        XCTAssertEqual(restored.options.count, 1)
        XCTAssertEqual(restored.options[0].endDayOffset, 1)
    }

    func testRangeContainingASkippedWallTimeDoesNotSubmit() {
        let model = model()
        model.title = "Planning"
        model.rangeStartDate = calendar.date(from: DateComponents(year: 2027, month: 3, day: 13))!
        model.rangeEndDate = calendar.date(from: DateComponents(year: 2027, month: 3, day: 15))!
        model.rangeStartTime = calendar.date(bySettingHour: 2, minute: 30, second: 0, of: now)!
        model.rangeEndTime = calendar.date(bySettingHour: 3, minute: 30, second: 0, of: now)!
        model.addDateRange()

        XCTAssertEqual(model.options.count, 3)
        XCTAssertNil(model.create {})
        XCTAssertEqual(model.errorMessage, CalendarTimeError.nonexistentLocalTime.localizedDescription)
    }

    func testCreateSubmitsWallTimesInTheCalendarZoneAndDismissesOnSuccess() async throws {
        let polls = MockPollService()
        var submitted: [CreatePollRequest] = []
        polls.creator = { request in
            submitted.append(request)
            let poll = Poll(creatorId: self.account, title: request.payload.title, status: .active)
            return PollCreationResult(poll: poll, timeOptions: [])
        }
        let model = model(polls: polls)
        model.title = "Planning"
        model.hasDueDate = true
        model.dueDate = now.addingTimeInterval(86_400)
        model.addOption()
        model.options[0].date = now.addingTimeInterval(3 * 86_400)
        var created = false

        await model.create { created = true }?.value

        XCTAssertTrue(created)
        let payload = try XCTUnwrap(submitted.first?.payload)
        XCTAssertEqual(payload.timezone, "America/Chicago")
        XCTAssertEqual(payload.title, "Planning")
        XCTAssertNil(payload.description)
        XCTAssertEqual(payload.closesAt.map(wallTime), [2026, 11, 4, 0, 0])
        XCTAssertEqual(payload.timeOptions.count, 1)
        XCTAssertEqual(wallTime(payload.timeOptions[0].startTime), [2026, 11, 5, 9, 0])
        XCTAssertEqual(wallTime(payload.timeOptions[0].endTime), [2026, 11, 5, 10, 0])
    }

    func testTappedAllDayDatesAreSubmittedAsSortedAllDayOptionsWithoutAnExtraStep() async throws {
        let polls = MockPollService()
        var submitted: [CreatePollRequest] = []
        polls.creator = { request in
            submitted.append(request)
            return PollCreationResult(poll: Poll(creatorId: self.account, title: "x", status: .active), timeOptions: [])
        }
        let model = model(polls: polls)
        model.title = "Offsite"
        model.isAllDay = true
        model.selectedDates = [
            DateComponents(calendar: calendar, year: 2026, month: 11, day: 12),
            DateComponents(calendar: calendar, year: 2026, month: 11, day: 5),
        ]

        await model.create {}?.value

        let options = try XCTUnwrap(submitted.first?.payload.timeOptions)
        XCTAssertEqual(options.map { wallTime($0.startTime) }, [[2026, 11, 5, 0, 0], [2026, 11, 12, 0, 0]])
        XCTAssertTrue(options.allSatisfy(\.isAllDay))
    }

    func testAllDayWithNoDaysSelectedExplainsAndDoesNotSubmit() async {
        let polls = MockPollService()
        var dispatched = false
        polls.creator = { _ in dispatched = true; throw CancellationError() }
        let model = model(polls: polls)
        model.title = "Offsite"
        model.isAllDay = true

        let task = model.create {}

        XCTAssertNil(task)
        XCTAssertEqual(model.errorMessage, "Select at least one day.")
        XCTAssertFalse(dispatched)
    }

    func testUnresolvedSubmissionIsRestoredAndRetriedUnchanged() async throws {
        let store = MemoryDraftStore()
        let polls = MockPollService()
        var submitted: [CreatePollRequest] = []
        polls.creator = { request in
            submitted.append(request)
            throw PollCreationError.transport
        }
        let first = model(polls: polls, store: store)
        first.title = "Planning"
        first.location = "Room 4"
        first.addOption()
        await first.create {}?.value
        XCTAssertTrue(first.mustResolvePending)
        XCTAssertTrue(first.isFormLocked)

        let restored = model(polls: polls, store: store)
        XCTAssertTrue(restored.mustResolvePending)
        XCTAssertEqual(restored.title, "Planning")
        XCTAssertEqual(restored.location, "Room 4")
        restored.title = "Edited while locked"
        await restored.create {}?.value

        XCTAssertEqual(submitted.count, 2)
        XCTAssertEqual(submitted[0].operationId, submitted[1].operationId)
        XCTAssertEqual(submitted[1].payload.title, "Planning")
    }

    func testUnresolvedAllDaySubmissionRestoresItsDaysOnTheCalendar() async {
        let store = MemoryDraftStore()
        let polls = MockPollService()
        polls.creator = { _ in throw PollCreationError.transport }
        let first = model(polls: polls, store: store)
        first.title = "Offsite"
        first.isAllDay = true
        first.selectedDates = [DateComponents(calendar: calendar, year: 2026, month: 11, day: 5)]
        await first.create {}?.value

        let restored = model(polls: polls, store: store)

        XCTAssertTrue(restored.isAllDay)
        XCTAssertEqual(restored.selectedDates.compactMap { calendar.date(from: $0) }, [calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))])
    }
}
