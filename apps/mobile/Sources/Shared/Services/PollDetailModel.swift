import Foundation

/// Response counts for one time option.
public struct ResponseSummary: Equatable, Sendable {
    public let available: Int
    public let maybe: Int
    public let unavailable: Int
}

/// How close a poll's response deadline is.
public enum ResponseDeadlineStatus: Equatable, Sendable {
    case open
    case closingSoon
    case pastDue
}

/// Progress of adding a finalized poll's meeting to the device calendar.
public enum CalendarAddState: Equatable, Sendable {
    case idle
    case adding
    /// Stays until the screen acknowledges it with `acknowledgeCalendarAdd()`.
    case finished(DeviceCalendarAddResult)
}

/// One visit to a poll's detail screen: it loads the poll for the signed-in account, edits that
/// account's availability, checks the device and Google calendars, runs the join, save, close
/// and finalize commands, and adds the final time to the device calendar.
///
/// Each `load()` starts a new visit and `suspend()` ends one. A result applies only while the
/// visit and account that started it are still current, so a reply that arrives after the
/// account changes or the screen leaves is dropped.
@MainActor
@Observable
public final class PollDetailModel {
    public static let maxCommentLength = 500

    public let pollId: UUID
    public let editor = AvailabilityEditor()
    public private(set) var poll: Poll?
    public private(set) var timeOptions: [PollTimeOption] = []
    public private(set) var participants: [PollParticipant] = []
    public private(set) var responses: [AvailabilityResponse] = []
    public private(set) var actionError: String?
    public private(set) var commentError: String?
    public private(set) var calendarAdd = CalendarAddState.idle
    public private(set) var calendarCheck = CalendarCheckResult.none
    public private(set) var isCheckingCalendar = false
    public private(set) var isLoading = true
    public private(set) var isSelectingFinalDate = false

    private let auth: any AuthServiceProtocol
    private let polls: any PollServiceProtocol
    private let calendar: any CalendarServiceProtocol
    private let clock: AppClock
    private var generation: UInt64 = 0
    private var myParticipantId: UUID?
    /// The account the displayed data belongs to; nil until the first load starts.
    private var displayed: Visit?

    private struct Visit {
        let accountId: UUID?
    }

    public init(
        pollId: UUID, auth: any AuthServiceProtocol, polls: any PollServiceProtocol,
        calendar: any CalendarServiceProtocol, clock: AppClock
    ) {
        self.pollId = pollId
        self.auth = auth
        self.polls = polls
        self.calendar = calendar
        self.clock = clock
    }

    // MARK: - Derived state

    /// The account whose detail the screen should show.
    public var currentAccountId: UUID? { auth.currentUserId }

    /// Whether the loaded data belongs to the signed-in account.
    public var displaysCurrentAccount: Bool {
        guard let displayed else { return false }
        return displayed.accountId == auth.currentUserId
    }

    /// Whether the screen should show its loading state rather than poll content.
    public var showsLoading: Bool { isLoading || !displaysCurrentAccount }

    public var loadError: String? { polls.pollDetailErrors[pollId] }
    public var calendarError: String? { calendar.googleCalendarError }

    /// The signed-in account's entry in `participants`, once it has joined.
    public var myParticipant: PollParticipant? {
        myParticipantId.flatMap { id in participants.first { $0.id == id } }
    }

    /// The meeting to add to the device calendar, once the poll has a final time.
    public var finalEvent: DeviceCalendarEvent? {
        poll.flatMap { DeviceCalendarEvent(finalTimeOf: $0, options: timeOptions) }
    }

    public var isCreator: Bool {
        poll?.creatorId == auth.currentUserId
    }

    /// Whether the poll still accepts availability: active, before its deadline and not
    /// reported closed by a save.
    public var acceptsResponses: Bool {
        guard let poll else { return false }
        return poll.status == .active && deadlineStatus != .pastDue && !editor.isClosed
    }

    /// Whether the signed-in participant can change their draft now.
    public var canEditAvailability: Bool {
        myParticipant != nil && editor.saved != nil && acceptsResponses && !editor.isSaving && !editor.isLoading
    }

    public var canSave: Bool {
        canEditAvailability && !editor.needsConflictReview
    }

    /// Nil when the poll has no deadline. The deadline instant itself is past due, and closing
    /// soon means within 24 hours.
    public var deadlineStatus: ResponseDeadlineStatus? {
        guard let closesAt = poll?.closesAt else { return nil }
        let remaining = closesAt.timeIntervalSince(clock.now)
        if remaining <= 0 { return .pastDue }
        return remaining < 24 * 60 * 60 ? .closingSoon : .open
    }

    /// Time options with the most available, then most maybe, responses first.
    public var rankedTimeOptions: [PollTimeOption] {
        timeOptions.sorted { optionA, optionB in
            let statsA = responseSummary(for: optionA.id)
            let statsB = responseSummary(for: optionB.id)
            if statsB.available != statsA.available {
                return statsB.available < statsA.available
            }
            return statsB.maybe < statsA.maybe
        }
    }

    public func responseSummary(for optionId: UUID) -> ResponseSummary {
        let optionResponses = responses.filter { $0.timeOptionId == optionId }
        return ResponseSummary(
            available: optionResponses.filter { $0.status == .available }.count,
            maybe: optionResponses.filter { $0.status == .maybe }.count,
            unavailable: optionResponses.filter { $0.status == .unavailable }.count
        )
    }

    public func isCurrentUser(_ participant: PollParticipant) -> Bool {
        participant.userId == auth.currentUserId
    }

    // MARK: - Visit lifecycle

    /// Starts a new visit for the signed-in account: clears what was shown, loads the poll and
    /// the participant's saved availability, then checks calendars.
    public func load() async {
        generation &+= 1
        let generation = generation
        let account = auth.currentUserId
        displayed = Visit(accountId: account)
        editor.selectAccount(account, pollId: pollId)
        poll = nil; timeOptions = []; participants = []; responses = []; myParticipantId = nil
        calendarCheck = .none; isCheckingCalendar = false; actionError = nil; commentError = nil
        calendarAdd = .idle
        isSelectingFinalDate = false
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        guard let detail = await polls.loadPollDetail(id: pollId), isCurrent(generation, account) else { return }
        poll = detail.poll
        timeOptions = detail.timeOptions
        participants = detail.participants
        responses = detail.responses
        if let account { myParticipantId = participants.first { $0.userId == account }?.id }
        if let participant = myParticipant {
            await editor.load(pollId: pollId, participantId: participant.id, using: polls)
            guard isCurrent(generation, account) else { return }
            applySavedSnapshot()
        }
        await calendar.refreshGoogleCalendarConnection()
        guard isCurrent(generation, account) else { return }
        await checkCalendar(generation: generation, account: account)
    }

    /// Ends the visit. The editor keeps its draft for the next one.
    public func suspend() {
        editor.suspend()
        generation &+= 1
    }

    // MARK: - Editing

    public func setResponse(_ status: AvailabilityStatus, for optionId: UUID) {
        editor.responses[optionId] = status
    }

    /// Keeps the comment within the length limit; a longer value is rejected with an error.
    public func updateComment(_ value: String) {
        if value.count <= Self.maxCommentLength {
            editor.comment = value
            commentError = nil
        } else {
            commentError = Self.commentTooLong
        }
    }

    // MARK: - Commands

    public func retryCalendarCheck() async {
        await checkCalendar(generation: generation, account: auth.currentUserId)
    }

    /// Reloads the participant's saved availability, keeping the current draft.
    @discardableResult
    public func reloadSavedResponses() -> Task<Void, Never>? {
        guard let participant = myParticipant else { return nil }
        let generation = generation
        return auth.performSessionTask(
            operation: { _ in
                await self.editor.load(
                    pollId: self.pollId, participantId: participant.id, preservingDraft: true, using: self.polls)
            },
            onSuccess: { _ in self.applySavedSnapshot() },
            isCurrent: { generation == self.generation && self.displaysCurrentAccount }
        )
    }

    @discardableResult
    public func join() -> Task<Void, Never>? {
        let generation = generation
        return auth.performSessionTask(
            operation: { scope in
                let participant = try await self.polls.joinPoll(pollId: self.pollId, anonymousName: nil)
                try scope.checkCancellation()
                if !self.participants.contains(where: { $0.id == participant.id }) {
                    self.participants.append(participant)
                }
                self.myParticipantId = participant.id
                await self.editor.load(pollId: self.pollId, participantId: participant.id, using: self.polls)
            },
            onSuccess: { _ in
                self.applySavedSnapshot()
                self.actionError = nil
            },
            onFailure: { _ in self.actionError = "The poll could not be joined. Reload the poll and try again." },
            isCurrent: { generation == self.generation }
        )
    }

    @discardableResult
    public func save() -> Task<Void, Never>? {
        guard let participant = myParticipant, validateComment(), acceptsResponses else { return nil }
        let generation = generation
        return auth.performSessionTask(
            operation: { _ in
                await self.editor.save(pollId: self.pollId, participantId: participant.id, using: self.polls)
            },
            onSuccess: { _ in if self.editor.didSave { self.applySavedSnapshot() } },
            isCurrent: { generation == self.generation }
        )
    }

    @discardableResult
    public func close() -> Task<Void, Never>? {
        let generation = generation
        return auth.performSessionTask(
            operation: { _ in try await self.polls.updatePollStatus(pollId: self.pollId, status: .closed) },
            onSuccess: { _ in
                self.poll?.status = .closed
                self.actionError = nil
            },
            onFailure: { _ in self.actionError = "The poll status could not be changed. Try again." },
            isCurrent: { generation == self.generation }
        )
    }

    @discardableResult
    public func finalize(with option: PollTimeOption) -> Task<Void, Never>? {
        guard !isSelectingFinalDate else { return nil }
        let generation = generation
        isSelectingFinalDate = true
        return auth.performSessionTask(
            operation: { _ in try await self.polls.finalizePoll(pollId: self.pollId, timeOptionId: option.id) },
            onSuccess: { finalized in
                self.poll = finalized
                self.actionError = nil
            },
            onFailure: { _ in
                self.actionError = "The final time could not be confirmed. Reload the poll and try again."
            },
            onCompletion: { self.isSelectingFinalDate = false },
            isCurrent: { generation == self.generation }
        )
    }

    /// Adds `finalEvent` to the device calendar. Does nothing before the poll has a final time
    /// or while an earlier add is still running.
    @discardableResult
    public func addFinalTimeToCalendar() -> Task<Void, Never>? {
        guard let event = finalEvent, calendarAdd != .adding else { return nil }
        let generation = generation
        calendarAdd = .adding
        return auth.performSessionTask(
            operation: { _ in await self.calendar.addEventToCalendar(event) },
            onSuccess: { result in self.calendarAdd = .finished(result) },
            onCompletion: { if self.calendarAdd == .adding { self.calendarAdd = .idle } },
            isCurrent: { generation == self.generation }
        )
    }

    /// Clears a finished add once the screen has shown its result.
    public func acknowledgeCalendarAdd() {
        if case .finished = calendarAdd { calendarAdd = .idle }
    }

    /// The device calendar events behind a busy option, for the conflict screen.
    public func calendarConflicts(for option: PollTimeOption) async -> [CalendarConflict] {
        await calendar.deviceConflicts(for: option, pollTimeZone: poll?.timezone)
    }

    // MARK: - Private

    private static var commentTooLong: String {
        "Comment must be \(maxCommentLength) characters or less"
    }

    private func isCurrent(_ generation: UInt64, _ account: UUID?) -> Bool {
        generation == self.generation && account == auth.currentUserId && !Task.isCancelled
    }

    /// Only busy options become unavailable suggestions; unchecked options are left alone.
    private func checkCalendar(generation: UInt64, account: UUID?) async {
        // The service returns an empty result when no source is enabled, which clears a stale banner on retry.
        guard let poll, !timeOptions.isEmpty, !isCheckingCalendar else { return }
        isCheckingCalendar = true
        defer { if generation == self.generation { isCheckingCalendar = false } }
        let result = await calendar.checkConflicts(for: timeOptions, pollTimeZone: poll.timezone)
        guard isCurrent(generation, account) else { return }
        calendarCheck = result
        for conflictId in result.busyIds where editor.saved != nil && editor.responses[conflictId] == nil {
            editor.responses[conflictId] = .unavailable
        }
    }

    private func applySavedSnapshot() {
        guard let snapshot = editor.saved, snapshot.pollId == pollId else { return }
        responses.removeAll { $0.participantId == snapshot.participantId }
        responses += snapshot.availabilityResponses
        if let index = participants.firstIndex(where: { $0.id == snapshot.participantId }) {
            participants[index].comment = snapshot.comment
        }
    }

    private func validateComment() -> Bool {
        if editor.comment.count > Self.maxCommentLength {
            commentError = Self.commentTooLong
            return false
        }
        commentError = nil
        return true
    }
}
