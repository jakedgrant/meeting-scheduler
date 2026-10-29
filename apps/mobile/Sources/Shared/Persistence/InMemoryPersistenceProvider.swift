import Foundation

@MainActor
public final class InMemoryPersistenceProvider: PersistenceProviderProtocol {
    private var listedPollIds: Set<UUID> = []
    private var polls: [UUID: Poll] = [:]
    private var timeOptions: [UUID: [PollTimeOption]] = [:]
    private var participants: [UUID: [PollParticipant]] = [:]
    private var responses: [UUID: [AvailabilityResponse]] = [:]
    private var profiles: [UUID: Profile] = [:]
    private var participantCounts: [UUID: Int] = [:]
    private var timeRanges: [UUID: (earliest: Date, latest: Date)] = [:]
    private var syncTimestamps: [UUID: Date] = [:]

    private var accountId: UUID?
    private var detailTimestamps: [UUID: Date] = [:]

    private let now: @MainActor () -> Date
    public init(now: @escaping @MainActor () -> Date = { Date() }) { self.now = now }

    public func selectAccount(_ accountId: UUID?) throws {
        guard self.accountId != accountId else { return }
        try clearAll()
        self.accountId = accountId
    }

    public func replacePollsSnapshot(_ polls: [Poll]) throws {
        let ids = Set(polls.map(\.id))
        for id in self.polls.keys.filter({ !ids.contains($0) }) { try deletePoll(id: id) }
        try saveListedPolls(polls)
    }

    public func replaceListedPollsPage(_ polls: [Poll]) throws {
        listedPollIds = []
        try saveListedPolls(polls)
    }

    public func saveListedPolls(_ polls: [Poll]) throws {
        try savePolls(polls)
        listedPollIds.formUnion(polls.map(\.id))
    }

    public func fetchListedPolls() throws -> [Poll] {
        try fetchAllPolls().filter { listedPollIds.contains($0.id) }
    }

    // MARK: - Polls

    public func savePolls(_ polls: [Poll]) throws {
        for poll in polls {
            if let existing = self.polls[poll.id] {
                if poll.updatedAt >= existing.updatedAt {
                    self.polls[poll.id] = poll
                    syncTimestamps[poll.id] = Date()
                }
            } else {
                self.polls[poll.id] = poll
                syncTimestamps[poll.id] = Date()
            }
        }
    }

    public func fetchAllPolls() throws -> [Poll] {
        Array(polls.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func fetchPoll(id: UUID) throws -> Poll? {
        polls[id]
    }

    public func deletePoll(id: UUID) throws {
        listedPollIds.remove(id)
        polls.removeValue(forKey: id)
        timeOptions.removeValue(forKey: id)
        for participant in participants[id] ?? [] { responses.removeValue(forKey: participant.id) }
        participants.removeValue(forKey: id)
        detailTimestamps.removeValue(forKey: id)
        participantCounts.removeValue(forKey: id)
        timeRanges.removeValue(forKey: id)
        syncTimestamps.removeValue(forKey: id)
    }

    // MARK: - Poll Detail

    public func savePollDetail(_ detail: PollDetail) throws {
        try invalidatePollDetail(detail.poll.id)
        try savePolls([detail.poll])
        try saveTimeOptions(detail.timeOptions, for: detail.poll.id)
        try saveParticipants(detail.participants, for: detail.poll.id)
        try saveResponses(detail.responses)
        detailTimestamps[detail.poll.id] = now()
    }

    public func fetchPollDetail(id: UUID) throws -> PollDetail? {
        guard let poll = polls[id], detailTimestamps[id] != nil else { return nil }
        let opts = timeOptions[id] ?? []
        let parts = participants[id] ?? []
        let partIds = parts.map { $0.id }
        let resps = partIds.flatMap { responses[$0] ?? [] }
        return PollDetail(
            poll: poll,
            timeOptions: opts,
            participants: parts,
            responses: resps
        )
    }

    // MARK: - Poll Metadata

    public func savePollParticipantCount(_ count: Int, for pollId: UUID) throws {
        participantCounts[pollId] = count
    }

    public func fetchPollParticipantCounts() throws -> [UUID: Int] {
        participantCounts
    }

    public func savePollTimeRange(earliest: Date, latest: Date, for pollId: UUID) throws {
        timeRanges[pollId] = (earliest: earliest, latest: latest)
    }

    public func fetchPollTimeRanges() throws -> [UUID: (earliest: Date, latest: Date)] {
        timeRanges
    }

    // MARK: - Time Options

    public func saveTimeOptions(_ options: [PollTimeOption], for pollId: UUID) throws {
        let retained = Set(options.map(\.id))
        for participant in participants[pollId] ?? [] {
            responses[participant.id]?.removeAll { !retained.contains($0.timeOptionId) }
        }
        timeOptions[pollId] = options
        syncTimestamps[pollId] = Date()
    }

    public func fetchTimeOptions(for pollId: UUID) throws -> [PollTimeOption] {
        timeOptions[pollId] ?? []
    }

    // MARK: - Participants

    public func saveParticipants(_ participants: [PollParticipant], for pollId: UUID) throws {
        let retained = Set(participants.map(\.id))
        for previous in self.participants[pollId] ?? [] where !retained.contains(previous.id) {
            responses.removeValue(forKey: previous.id)
        }
        self.participants[pollId] = participants
    }

    public func fetchParticipants(for pollId: UUID) throws -> [PollParticipant] {
        participants[pollId] ?? []
    }

    // MARK: - Availability Responses

    public func saveResponses(_ responses: [AvailabilityResponse]) throws {
        for response in responses {
            var existing = self.responses[response.participantId] ?? []
            if let index = existing.firstIndex(where: { $0.id == response.id }) {
                if response.updatedAt >= existing[index].updatedAt {
                    existing[index] = response
                }
            } else {
                existing.append(response)
            }
            self.responses[response.participantId] = existing
        }
    }

    public func replaceResponsesSnapshot(_ responses: [AvailabilityResponse], for participantIds: [UUID]) throws {
        for id in participantIds { self.responses[id] = [] }
        try saveResponses(responses)
    }

    public func fetchResponses(for participantIds: [UUID]) throws -> [AvailabilityResponse] {
        participantIds.flatMap { responses[$0] ?? [] }
    }

    // MARK: - Profile

    public func saveProfile(_ profile: Profile) throws {
        if let existing = profiles[profile.id] {
            if profile.updatedAt >= existing.updatedAt {
                profiles[profile.id] = profile
                syncTimestamps[profile.id] = Date()
            }
        } else {
            profiles[profile.id] = profile
            syncTimestamps[profile.id] = Date()
        }
    }

    public func fetchProfile(id: UUID) throws -> Profile? {
        profiles[id]
    }

    // MARK: - Cache Management

    public func isDetailFresh(_ pollId: UUID, maxAge: TimeInterval) -> Bool {
        guard let date = detailTimestamps[pollId] else { return false }
        return now().timeIntervalSince(date) < maxAge
    }

    public func invalidatePollDetail(_ pollId: UUID) throws {
        timeOptions.removeValue(forKey: pollId)
        for participant in participants[pollId] ?? [] { responses.removeValue(forKey: participant.id) }
        participants.removeValue(forKey: pollId)
        detailTimestamps.removeValue(forKey: pollId)
    }

    public func isFresh(_ entityId: UUID, maxAge: TimeInterval) -> Bool {
        guard let timestamp = syncTimestamps[entityId] else { return false }
        return Date().timeIntervalSince(timestamp) < maxAge
    }

    public func clearAll() throws {
        listedPollIds.removeAll()
        polls.removeAll()
        timeOptions.removeAll()
        participants.removeAll()
        responses.removeAll()
        profiles.removeAll()
        participantCounts.removeAll()
        timeRanges.removeAll()
        syncTimestamps.removeAll()
        detailTimestamps.removeAll()
    }
}
