import XCTest
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
        model.selectCurrentAccount()
        return model
    }

    private func wallTime(_ date: Date) -> [Int] {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!]
    }

    func testNewFormStartsWithOneOptionTodayFromNineToTen() {
        let model = model()
        XCTAssertEqual(model.options.count, 1)
        XCTAssertEqual(wallTime(model.options[0].startTime), [2026, 11, 2, 9, 0])
        XCTAssertEqual(wallTime(model.options[0].endTime), [2026, 11, 2, 10, 0])
        XCTAssertEqual(model.startOfToday, calendar.startOfDay(for: now))
        XCTAssertFalse(model.canSubmit)
    }

    func testDateRangeAddsOneSortedOptionPerDayAndRejectsInvalidRanges() {
        let model = model()
        model.options = []
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
        model.removeOption(id: model.options[0].id)
        XCTAssertEqual(model.options.count, 1)
        model.addOption()
        model.removeOption(id: model.options[0].id)
        XCTAssertEqual(model.options.count, 1)
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
}
