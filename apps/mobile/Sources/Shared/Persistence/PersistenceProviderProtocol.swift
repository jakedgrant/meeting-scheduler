import Foundation

@MainActor
public protocol PersistenceProviderProtocol: Sendable {
    /// Changes the cache namespace. Identity transitions discard the previous namespace.
    func selectAccount(_ accountId: UUID?) throws

    // MARK: - Polls
    /// Upsert only: safe for incomplete or paginated reads.
    func savePolls(_ polls: [Poll]) throws
    /// Reconcile a complete, authoritative list, including polls no longer accessible.
    func replacePollsSnapshot(_ polls: [Poll]) throws
    func fetchAllPolls() throws -> [Poll]
    func fetchPoll(id: UUID) throws -> Poll?
    func deletePoll(id: UUID) throws

    // MARK: - Poll Detail (composite)
    func savePollDetail(_ detail: PollDetail) throws
    func fetchPollDetail(id: UUID) throws -> PollDetail?

    // MARK: - Poll Metadata (participant counts, time ranges)
    func savePollParticipantCount(_ count: Int, for pollId: UUID) throws
    func fetchPollParticipantCounts() throws -> [UUID: Int]
    func savePollTimeRange(earliest: Date, latest: Date, for pollId: UUID) throws
    func fetchPollTimeRanges() throws -> [UUID: (earliest: Date, latest: Date)]

    // MARK: - Time Options
    func saveTimeOptions(_ options: [PollTimeOption], for pollId: UUID) throws
    func fetchTimeOptions(for pollId: UUID) throws -> [PollTimeOption]

    // MARK: - Participants
    func saveParticipants(_ participants: [PollParticipant], for pollId: UUID) throws
    func fetchParticipants(for pollId: UUID) throws -> [PollParticipant]

    // MARK: - Availability Responses
    func saveResponses(_ responses: [AvailabilityResponse]) throws
    func replaceResponsesSnapshot(_ responses: [AvailabilityResponse], for participantIds: [UUID]) throws
    func fetchResponses(for participantIds: [UUID]) throws -> [AvailabilityResponse]

    // MARK: - Profile
    func saveProfile(_ profile: Profile) throws
    func fetchProfile(id: UUID) throws -> Profile?

    // MARK: - Cache Management
    func isDetailFresh(_ pollId: UUID, maxAge: TimeInterval) -> Bool
    /// Deletes detail after a mutation so offline fallback cannot resurrect pre-write state.
    func invalidatePollDetail(_ pollId: UUID) throws
    func isFresh(_ entityId: UUID, maxAge: TimeInterval) -> Bool
    func clearAll() throws
}
