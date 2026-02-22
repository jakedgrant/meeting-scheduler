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

    public func setSelectedFinalDate(pollId: UUID, startTime: Date, endTime: Date) async throws {}

    public func loadParticipants(pollId: UUID) async -> [PollParticipant] {
        sampleParticipants.filter { $0.pollId == pollId }
    }

    public func joinPoll(pollId: UUID, anonymousName: String?) async throws -> PollParticipant {
        PollParticipant(pollId: pollId, anonymousName: anonymousName ?? "You")
    }

    public func loadResponses(participantIds: [UUID]) async -> [AvailabilityResponse] {
        sampleResponses.filter { participantIds.contains($0.participantId) }
    }

    public func submitAvailability(participantId: UUID, timeOptionId: UUID, status: AvailabilityStatus, note: String?) async throws {}

    public func updateParticipantComment(participantId: UUID, comment: String?) async throws {}

    public func canCreatePoll() async -> Bool { true }

    public func countActivePolls() async -> Int { createdPolls.filter { $0.status == .active }.count }
}
