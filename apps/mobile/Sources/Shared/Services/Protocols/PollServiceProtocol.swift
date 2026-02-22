import Foundation

/// Protocol describing the public interface of PollService for dependency injection and testing.
@MainActor
public protocol PollServiceProtocol: AnyObject, Observable, Sendable {
    // MARK: - Properties

    var myPolls: [Poll] { get }
    var createdPolls: [Poll] { get }
    var joinedPolls: [Poll] { get }
    var isLoading: Bool { get }

    // MARK: - Formatting

    func formatTimeRange(earliest: Date, latest: Date) -> String

    // MARK: - Load Polls

    func loadMyPolls() async
    func loadPoll(id: UUID) async -> Poll?
    func loadPollByCode(_ code: String) async -> PollLookupResponse?

    // MARK: - Create Poll

    func createPoll(
        title: String,
        description: String?,
        location: String?,
        timezone: String,
        closesAt: Date?
    ) async throws -> Poll

    // MARK: - Time Options

    func loadTimeOptions(pollId: UUID) async -> [PollTimeOption]
    func addTimeOptions(pollId: UUID, options: [(start: Date, end: Date, isAllDay: Bool)]) async throws -> [PollTimeOption]

    // MARK: - Poll Status

    func updatePollStatus(pollId: UUID, status: PollStatus) async throws
    func setSelectedFinalDate(pollId: UUID, startTime: Date, endTime: Date) async throws

    // MARK: - Participants

    func loadParticipants(pollId: UUID) async -> [PollParticipant]
    func joinPoll(pollId: UUID, anonymousName: String?) async throws -> PollParticipant

    // MARK: - Availability Responses

    func loadResponses(participantIds: [UUID]) async -> [AvailabilityResponse]
    func submitAvailability(participantId: UUID, timeOptionId: UUID, status: AvailabilityStatus, note: String?) async throws
    func updateParticipantComment(participantId: UUID, comment: String?) async throws

    // MARK: - Subscription Checks

    func canCreatePoll() async -> Bool
    func countActivePolls() async -> Int
}
