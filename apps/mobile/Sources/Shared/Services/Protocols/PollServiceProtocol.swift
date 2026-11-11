import Foundation

/// Protocol describing the public interface of PollService for dependency injection and testing.
@MainActor
public protocol PollServiceProtocol: AnyObject, Observable, Sendable {
    // MARK: - Properties

    var myPolls: [Poll] { get }
    var createdPolls: [Poll] { get }
    var joinedPolls: [Poll] { get }
    var isLoading: Bool { get }
    var isLoadingMore: Bool { get }
    var hasMorePolls: Bool { get }
    var listTotalCount: Int? { get }
    var listLoadError: String? { get }
    var pollDetailErrors: [UUID: String] { get }

    /// Participant counts keyed by poll ID — populated as part of loadMyPolls().
    var pollParticipantCounts: [UUID: Int] { get }

    /// Time ranges keyed by poll ID — populated as part of loadMyPolls().
    var pollTimeRanges: [UUID: (earliest: Date, latest: Date)] { get }

    // MARK: - Formatting

    func formatTimeRange(earliest: Date, latest: Date) -> String

    // MARK: - Load Polls

    func loadMyPolls() async
    func loadMorePolls() async
    func retryPollLoad() async
    func loadPoll(id: UUID) async -> Poll?
    func loadPollByCode(_ code: String) async -> PollLookupResponse?

    /// Loads complete metadata and all response pages before publishing or caching detail.
    func loadPollDetail(id: UUID) async -> PollDetail?

    // MARK: - Create Poll

    func createPoll(_ request: CreatePollRequest) async throws -> PollCreationResult

    // MARK: - Time Options

    func loadTimeOptions(pollId: UUID) async -> [PollTimeOption]

    // MARK: - Poll Status

    func updatePollStatus(pollId: UUID, status: PollStatus) async throws
    func finalizePoll(pollId: UUID, timeOptionId: UUID) async throws -> Poll

    // MARK: - Participants

    func loadParticipants(pollId: UUID) async -> [PollParticipant]
    func joinPoll(pollId: UUID, anonymousName: String?) async throws -> PollParticipant

    // MARK: - Availability Responses

    func loadResponses(participantIds: [UUID]) async -> [AvailabilityResponse]
    func getAvailability(pollId: UUID, participantId: UUID, guestToken: String?) async throws -> AvailabilitySnapshot
    func saveAvailability(_ request: SaveAvailabilityRequest) async throws -> AvailabilitySnapshot

}

extension PollServiceProtocol {
    /// Joins the poll a share code names and returns its ID.
    ///
    /// Entering a code is the decision to join. Only a poll's creator and participants can read
    /// its detail, so the join has to happen before the poll is opened; the code lookup returns
    /// just enough to choose the poll. Joining a poll the account is already in returns the
    /// existing membership.
    public func joinPoll(code: String) async throws -> UUID {
        guard let poll = await loadPollByCode(code) else { throw PollError.pollNotFound }
        guard poll.status == .active else { throw PollError.notAcceptingParticipants }
        _ = try await joinPoll(pollId: poll.id, anonymousName: nil)
        return poll.id
    }
}
