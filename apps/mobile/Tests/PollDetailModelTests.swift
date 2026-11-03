import XCTest
@testable import Shared

@MainActor
final class PollDetailModelTests: XCTestCase {
    private let account = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let model: PollDetailModel
        let auth: MockAuthService
        let polls: MockPollService
        let calendar: MockCalendarService
        let poll: Poll
        let options: [PollTimeOption]
        let participant: PollParticipant
    }

    private func fixture(
        closesAt: Date? = nil, status: PollStatus = .active, creatorId: UUID? = nil, allDay: Bool = false,
        finalized: Bool = false
    ) -> Fixture {
        var poll = Poll(
            creatorId: creatorId ?? UUID(), title: "Planning", description: "Agenda", location: "Room 4",
            status: status, timezone: "America/Chicago", closesAt: closesAt, shareCode: "ABC123")
        let options = (0..<3).map { index in
            PollTimeOption(
                pollId: poll.id, startTime: now.addingTimeInterval(Double(index + 1) * 86_400),
                endTime: now.addingTimeInterval(Double(index + 1) * 86_400 + 3_600), isAllDay: allDay)
        }
        if finalized {
            poll.selectedStartTime = options[0].startTime
            poll.selectedEndTime = options[0].endTime
        }
        let participant = PollParticipant(pollId: poll.id, userId: account)
        let other = PollParticipant(pollId: poll.id, anonymousName: "Guest")
        let polls = MockPollService(
            createdPolls: [poll], sampleTimeOptions: options, sampleParticipants: [participant, other],
            sampleResponses: [
                AvailabilityResponse(participantId: other.id, timeOptionId: options[2].id, status: .available),
                AvailabilityResponse(participantId: other.id, timeOptionId: options[1].id, status: .maybe),
            ])
        let auth = MockAuthService(isAuthenticated: true, currentUserId: account)
        let calendar = MockCalendarService(appleCalendarEnabled: true)
        let model = PollDetailModel(pollId: poll.id, auth: auth, polls: polls, calendar: calendar, clock: .fixed(now))
        return Fixture(
            model: model, auth: auth, polls: polls, calendar: calendar, poll: poll, options: options,
            participant: participant)
    }

    func testDeadlineAndResponseWindowAreJudgedAgainstTheInjectedClock() async {
        let cases: [(Date?, ResponseDeadlineStatus?, Bool)] = [
            (nil, nil, true),
            (now.addingTimeInterval(2 * 86_400), .open, true),
            (now.addingTimeInterval(3_600), .closingSoon, true),
            (now, .pastDue, false),
            (now.addingTimeInterval(-1), .pastDue, false),
        ]
        for (closesAt, status, accepts) in cases {
            let fixture = fixture(closesAt: closesAt)
            await fixture.model.load()
            XCTAssertEqual(fixture.model.deadlineStatus, status, "\(String(describing: closesAt))")
            XCTAssertEqual(fixture.model.acceptsResponses, accepts, "\(String(describing: closesAt))")
            XCTAssertEqual(fixture.model.canEditAvailability, accepts)
        }
    }

    func testLoadShowsTheAccountsDetailAndRanksOptionsByAvailability() async {
        let fixture = fixture()
        XCTAssertTrue(fixture.model.showsLoading)
        await fixture.model.load()

        XCTAssertFalse(fixture.model.showsLoading)
        XCTAssertTrue(fixture.model.displaysCurrentAccount)
        XCTAssertEqual(fixture.model.poll?.id, fixture.poll.id)
        XCTAssertEqual(fixture.model.myParticipant?.id, fixture.participant.id)
        XCTAssertNotNil(fixture.model.editor.saved)
        XCTAssertEqual(fixture.model.rankedTimeOptions.map(\.id), [2, 1, 0].map { fixture.options[$0].id })
        XCTAssertEqual(
            fixture.model.responseSummary(for: fixture.options[1].id),
            ResponseSummary(available: 0, maybe: 1, unavailable: 0))
    }

    func testSignedOutVisitWaitsForTheFirstLoadBeforeShowingContent() async {
        let fixture = fixture()
        fixture.auth.currentUserId = nil
        XCTAssertTrue(fixture.model.showsLoading)
        await fixture.model.load()
        XCTAssertFalse(fixture.model.showsLoading)
        XCTAssertNil(fixture.model.myParticipant)
    }

    func testBusyOptionsBecomeUnavailableSuggestionsWithoutReplacingAnswers() async {
        let fixture = fixture()
        let busy: Set<UUID> = [fixture.options[0].id, fixture.options[1].id]
        fixture.calendar.conflictChecker = { options, zone in
            XCTAssertEqual(zone, "America/Chicago")
            return CalendarCheckResult(
                optionIds: Set(options.map(\.id)), sources: [(.appleCalendar, busy), (.googleCalendar, nil)])
        }
        fixture.polls.sampleResponses.append(
            AvailabilityResponse(participantId: fixture.participant.id, timeOptionId: fixture.options[1].id, status: .available))

        await fixture.model.load()

        XCTAssertEqual(fixture.model.calendarCheck.busyIds, busy)
        XCTAssertEqual(fixture.model.calendarCheck.uncheckedIds, [fixture.options[2].id])
        XCTAssertEqual(fixture.model.editor.responses[fixture.options[0].id], .unavailable)
        XCTAssertEqual(fixture.model.editor.responses[fixture.options[1].id], .available)
        XCTAssertNil(fixture.model.editor.responses[fixture.options[2].id])
    }

    func testCalendarResultAfterAnAccountChangeIsDropped() async {
        let fixture = fixture()
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "calendar check started")
        fixture.calendar.conflictChecker = { options, _ in
            await withCheckedContinuation {
                release = $0
                started.fulfill()
            }
            return CalendarCheckResult(optionIds: Set(options.map(\.id)), sources: [(.appleCalendar, [options[0].id])])
        }
        let loading = Task { await fixture.model.load() }
        await fulfillment(of: [started], timeout: 5)
        fixture.auth.currentUserId = UUID()
        XCTAssertNotNil(release)
        release?.resume()
        await loading.value

        XCTAssertEqual(fixture.model.calendarCheck, .none)
        XCTAssertNil(fixture.model.editor.responses[fixture.options[0].id])
        XCTAssertFalse(fixture.model.displaysCurrentAccount)
        XCTAssertTrue(fixture.model.showsLoading)
    }

    func testSaveAppliesTheCommandResultToTheDisplayedResponses() async {
        let fixture = fixture()
        await fixture.model.load()
        fixture.model.setResponse(.available, for: fixture.options[0].id)
        fixture.model.updateComment("Works for me")

        await fixture.model.save()?.value

        XCTAssertTrue(fixture.model.editor.didSave)
        XCTAssertEqual(fixture.model.responseSummary(for: fixture.options[0].id).available, 1)
        XCTAssertEqual(fixture.model.myParticipant?.comment, "Works for me")
    }

    func testSaveResultAfterTheScreenLeavesIsNotApplied() async {
        let fixture = fixture()
        await fixture.model.load()
        fixture.model.setResponse(.available, for: fixture.options[0].id)
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "save started")
        fixture.polls.availabilitySaver = { request in
            await withCheckedContinuation {
                release = $0
                started.fulfill()
            }
            return AvailabilitySnapshot(
                participantId: request.participantId, pollId: request.pollId, version: 1, comment: nil,
                responses: request.responses.map { SavedAvailabilityAnswer(timeOptionId: $0.timeOptionId, status: $0.status) })
        }
        guard let task = fixture.model.save() else { return XCTFail("Save did not start") }
        await fulfillment(of: [started], timeout: 5)
        fixture.model.suspend()
        XCTAssertNotNil(release)
        release?.resume()
        await task.value

        XCTAssertEqual(fixture.model.responseSummary(for: fixture.options[0].id).available, 0)
    }

    func testCommentOverTheLimitIsRejected() async {
        let fixture = fixture()
        await fixture.model.load()
        fixture.model.updateComment(String(repeating: "a", count: PollDetailModel.maxCommentLength))
        XCTAssertNil(fixture.model.commentError)
        fixture.model.updateComment(String(repeating: "a", count: PollDetailModel.maxCommentLength + 1))
        XCTAssertNotNil(fixture.model.commentError)
        XCTAssertEqual(fixture.model.editor.comment.count, PollDetailModel.maxCommentLength)
    }

    func testFinalizeAppliesTheFinalizedPollAndReportsFailure() async {
        let fixture = fixture(status: .closed, creatorId: account)
        await fixture.model.load()
        XCTAssertTrue(fixture.model.isCreator)

        fixture.polls.finalizer = { _, _ in throw PollError.pollNotFound }
        await fixture.model.finalize(with: fixture.options[0])?.value
        XCTAssertNotNil(fixture.model.actionError)
        XCTAssertFalse(fixture.model.isSelectingFinalDate)
        XCTAssertNil(fixture.model.poll?.selectedStartTime)

        fixture.polls.finalizer = nil
        await fixture.model.finalize(with: fixture.options[0])?.value
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.poll?.selectedStartTime, fixture.options[0].startTime)
        XCTAssertFalse(fixture.model.isSelectingFinalDate)
    }

    func testCloseMarksThePollClosed() async {
        let fixture = fixture(creatorId: account)
        await fixture.model.load()
        await fixture.model.close()?.value
        XCTAssertEqual(fixture.model.poll?.status, .closed)
        XCTAssertFalse(fixture.model.acceptsResponses)
    }

    // MARK: - Device calendar

    /// A loaded fixture poll that was finalized on the first option, which starts at
    /// 2027-01-16T08:00:00Z: 02:00 on January 16 in Chicago. The poll is stored finalized so a
    /// later `load()` keeps its final time.
    private func finalizedFixture(allDay: Bool = false) async -> Fixture {
        let fixture = fixture(status: .closed, creatorId: account, allDay: allDay, finalized: true)
        await fixture.model.load()
        return fixture
    }

    func testFinalEventIsTheFinalizedTimeWithThePollsDetails() async {
        let fixture = fixture(status: .closed, creatorId: account)
        await fixture.model.load()
        XCTAssertNil(fixture.model.finalEvent)
        XCTAssertNil(fixture.model.addFinalTimeToCalendar())

        await fixture.model.finalize(with: fixture.options[0])?.value
        XCTAssertEqual(
            fixture.model.finalEvent,
            DeviceCalendarEvent(
                title: "Planning", start: fixture.options[0].startTime, end: fixture.options[0].endTime,
                allDayDate: nil, notes: "Agenda", location: "Room 4"))
    }

    func testAllDayFinalEventUsesTheDateInThePollsZone() async {
        let fixture = await finalizedFixture(allDay: true)
        XCTAssertEqual(fixture.model.finalEvent?.allDayDate, CalendarDay("2027-01-16"))
    }

    func testAddingToTheCalendarReportsEachOutcomeUntilAcknowledged() async throws {
        let fixture = await finalizedFixture()
        await fixture.model.addFinalTimeToCalendar()?.value
        XCTAssertEqual(fixture.model.calendarAdd, .finished(.added))
        XCTAssertEqual(fixture.calendar.addedEvents, [try XCTUnwrap(fixture.model.finalEvent)])

        fixture.model.acknowledgeCalendarAdd()
        XCTAssertEqual(fixture.model.calendarAdd, .idle)

        for result in [DeviceCalendarAddResult.accessDenied, .failed] {
            fixture.calendar.eventAdder = { _ in result }
            await fixture.model.addFinalTimeToCalendar()?.value
            XCTAssertEqual(fixture.model.calendarAdd, .finished(result))
            fixture.model.acknowledgeCalendarAdd()
        }
    }

    func testAddRunsOnceAtATimeAndItsResultIsDroppedAfterTheScreenLeaves() async {
        let fixture = await finalizedFixture()
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "add started")
        fixture.calendar.eventAdder = { _ in
            await withCheckedContinuation {
                release = $0
                started.fulfill()
            }
            return .added
        }
        guard let task = fixture.model.addFinalTimeToCalendar() else { return XCTFail("Add did not start") }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(fixture.model.calendarAdd, .adding)
        XCTAssertNil(fixture.model.addFinalTimeToCalendar())

        fixture.model.suspend()
        XCTAssertNotNil(release)
        release?.resume()
        await task.value

        // The stale task neither reports its result nor clears the state; the next visit does.
        XCTAssertEqual(fixture.model.calendarAdd, .adding)
        fixture.calendar.eventAdder = nil
        await fixture.model.load()
        XCTAssertEqual(fixture.model.calendarAdd, .idle)
        await fixture.model.addFinalTimeToCalendar()?.value
        XCTAssertEqual(fixture.model.calendarAdd, .finished(.added))
    }
}
