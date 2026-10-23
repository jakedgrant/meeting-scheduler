import Foundation

/// Mock implementation of PollServiceProtocol for SwiftUI previews and testing.
@MainActor
@Observable
public final class MockPollService: PollServiceProtocol {
    public var myPolls: [Poll]
    public var createdPolls: [Poll]
    public var joinedPolls: [Poll]
    public var isLoading: Bool

    // Backing data returned by load methods
    public var sampleTimeOptions: [PollTimeOption]
    public var sampleParticipants: [PollParticipant]
    public var sampleResponses: [AvailabilityResponse]
    public var availabilityLoader: (@MainActor (UUID, UUID, String?) async throws -> AvailabilitySnapshot)?
    public var availabilitySaver: (@MainActor (SaveAvailabilityRequest) async throws -> AvailabilitySnapshot)?
    public var finalizer: (@MainActor (UUID, UUID) async throws -> Poll)?
    private var responseVersion: Int64 = 0

    /// Derived from sampleParticipants — matches what PollService populates during loadMyPolls().
    public var pollParticipantCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for participant in sampleParticipants {
            counts[participant.pollId, default: 0] += 1
        }
        return counts
    }

    /// Derived from sampleTimeOptions — matches what PollService populates during loadMyPolls().
    public var pollTimeRanges: [UUID: (earliest: Date, latest: Date)] {
        var ranges: [UUID: (earliest: Date, latest: Date)] = [:]
        for option in sampleTimeOptions {
            if let existing = ranges[option.pollId] {
                ranges[option.pollId] = (
                    earliest: min(existing.earliest, option.startTime),
                    latest: max(existing.latest, option.startTime)
                )
            } else {
                ranges[option.pollId] = (earliest: option.startTime, latest: option.startTime)
            }
        }
        return ranges
    }

    public init(
        createdPolls: [Poll] = [],
        joinedPolls: [Poll] = [],
        isLoading: Bool = false,
        sampleTimeOptions: [PollTimeOption] = [],
        sampleParticipants: [PollParticipant] = [],
        sampleResponses: [AvailabilityResponse] = []
    ) {
        self.createdPolls = createdPolls
        self.joinedPolls = joinedPolls
        self.myPolls = createdPolls + joinedPolls
        self.isLoading = isLoading
        self.sampleTimeOptions = sampleTimeOptions
        self.sampleParticipants = sampleParticipants
        self.sampleResponses = sampleResponses
    }

    // MARK: - Static Factories

    public static var withSamplePolls: MockPollService {
        let creatorId = UUID()
        let pollId1 = UUID()
        let pollId2 = UUID()
        let pollId3 = UUID()

        let created = [
            Poll(
                id: pollId1,
                creatorId: creatorId,
                title: "Team Standup",
                description: "Weekly sync meeting",
                location: "Zoom",
                status: .active,
                timezone: "America/New_York",
                shareCode: "ABC123"
            ),
            Poll(
                id: pollId2,
                creatorId: creatorId,
                title: "Sprint Planning",
                description: "Q2 sprint planning session",
                status: .closed,
                timezone: "America/New_York",
                shareCode: "DEF456"
            ),
        ]

        let joined = [
            Poll(
                id: pollId3,
                creatorId: UUID(),
                title: "Design Review",
                description: "Review new mockups",
                location: "Conference Room B",
                status: .active,
                timezone: "America/Chicago",
                shareCode: "GHI789"
            ),
        ]

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

        let timeOptions = [
            PollTimeOption(
                pollId: pollId1,
                startTime: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!,
                endTime: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!
            ),
            PollTimeOption(
                pollId: pollId1,
                startTime: Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow)!,
                endTime: Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow)!
            ),
        ]

        let participant1 = PollParticipant(
            pollId: pollId1,
            userId: creatorId,
            profiles: PollParticipant.ParticipantProfile(displayName: "Jane Doe")
        )
        let participant2 = PollParticipant(
            pollId: pollId1,
            anonymousName: "Bob Smith"
        )

        let responses = [
            AvailabilityResponse(participantId: participant1.id, timeOptionId: timeOptions[0].id, status: .available),
            AvailabilityResponse(participantId: participant1.id, timeOptionId: timeOptions[1].id, status: .maybe),
            AvailabilityResponse(participantId: participant2.id, timeOptionId: timeOptions[0].id, status: .available),
            AvailabilityResponse(participantId: participant2.id, timeOptionId: timeOptions[1].id, status: .unavailable),
        ]

        return MockPollService(
            createdPolls: created,
            joinedPolls: joined,
            sampleTimeOptions: timeOptions,
            sampleParticipants: [participant1, participant2],
            sampleResponses: responses
        )
    }

    public static var empty: MockPollService {
        MockPollService()
    }

    // MARK: - Formatting

    private let timeRangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    public func formatTimeRange(earliest: Date, latest: Date) -> String {
        "\(timeRangeFormatter.string(from: earliest)) - \(timeRangeFormatter.string(from: latest))"
    }

    // MARK: - Load Methods (return pre-set data)

    public func loadMyPolls() async {}

    public func loadPoll(id: UUID) async -> Poll? {
        myPolls.first { $0.id == id }
    }

    public func loadPollByCode(_ code: String) async -> PollLookupResponse? {
        nil
    }

    public func loadPollDetail(id: UUID) async -> PollDetail? {
        guard let poll = myPolls.first(where: { $0.id == id }) else { return nil }
        let timeOptions = sampleTimeOptions.filter { $0.pollId == id }
        let participants = sampleParticipants.filter { $0.pollId == id }
        let participantIds = Set(participants.map { $0.id })
        let responses = sampleResponses.filter { participantIds.contains($0.participantId) }
        return PollDetail(poll: poll, timeOptions: timeOptions, participants: participants, responses: responses)
    }

    public func createPoll(
        title: String,
        description: String?,
        location: String?,
        timezone: String,
        closesAt: Date?
    ) async throws -> Poll {
        Poll(creatorId: UUID(), title: title, description: description, location: location, status: .active, shareCode: "NEW123")
    }

    public func loadTimeOptions(pollId: UUID) async -> [PollTimeOption] {
        sampleTimeOptions.filter { $0.pollId == pollId }
    }

    public func addTimeOptions(pollId: UUID, options: [(start: Date, end: Date, isAllDay: Bool)]) async throws -> [PollTimeOption] {
        options.map { PollTimeOption(pollId: pollId, startTime: $0.start, endTime: $0.end, isAllDay: $0.isAllDay) }
    }

    public func updatePollStatus(pollId: UUID, status: PollStatus) async throws {}

    public func finalizePoll(pollId: UUID, timeOptionId: UUID) async throws -> Poll {
        if let finalizer { return try await finalizer(pollId, timeOptionId) }
        guard var poll = myPolls.first(where: { $0.id == pollId }),
              let option = sampleTimeOptions.first(where: { $0.id == timeOptionId && $0.pollId == pollId }) else { throw PollError.pollNotFound }
        poll.status = .closed
        poll.selectedStartTime = option.startTime
        poll.selectedEndTime = option.endTime
        return poll
    }

    public func loadParticipants(pollId: UUID) async -> [PollParticipant] {
        sampleParticipants.filter { $0.pollId == pollId }
    }

    public func joinPoll(pollId: UUID, anonymousName: String?) async throws -> PollParticipant {
        PollParticipant(pollId: pollId, anonymousName: anonymousName ?? "You")
    }

    public func loadResponses(participantIds: [UUID]) async -> [AvailabilityResponse] {
        sampleResponses.filter { participantIds.contains($0.participantId) }
    }

    public func getAvailability(pollId: UUID, participantId: UUID, guestToken: String? = nil) async throws -> AvailabilitySnapshot {
        if let availabilityLoader { return try await availabilityLoader(pollId, participantId, guestToken) }
        return AvailabilitySnapshot(participantId: participantId, pollId: pollId, version: responseVersion,
            comment: sampleParticipants.first(where: { $0.id == participantId })?.comment,
            responses: sampleResponses.filter { $0.participantId == participantId }.map {
                SavedAvailabilityAnswer(id: $0.id, timeOptionId: $0.timeOptionId, status: $0.status, note: $0.note, updatedAt: $0.updatedAt)
            })
    }

    public func saveAvailability(_ request: SaveAvailabilityRequest) async throws -> AvailabilitySnapshot {
        if let availabilitySaver { return try await availabilitySaver(request) }
        guard request.expectedVersion == responseVersion else { throw AvailabilityCommandError.conflict }
        responseVersion += 1
        let snapshot = AvailabilitySnapshot(participantId: request.participantId, pollId: request.pollId,
            version: responseVersion, comment: request.comment,
            responses: request.responses.map { SavedAvailabilityAnswer(timeOptionId: $0.timeOptionId, status: $0.status, note: $0.note) },
            savedAt: Date(), replayed: false)
        sampleResponses.removeAll { $0.participantId == request.participantId }
        sampleResponses += snapshot.availabilityResponses
        if let index = sampleParticipants.firstIndex(where: { $0.id == request.participantId }) { sampleParticipants[index].comment = snapshot.comment }
        return snapshot
    }

    public func canCreatePoll() async -> Bool { true }

    public func countActivePolls() async -> Int { createdPolls.filter { $0.status == .active }.count }
}
