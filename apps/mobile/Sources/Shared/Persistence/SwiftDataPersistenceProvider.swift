import Foundation
import SwiftData

@MainActor
public final class SwiftDataPersistenceProvider: PersistenceProviderProtocol {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    // In-memory metadata not worth persisting as @Model objects
    private var participantCounts: [UUID: Int] = [:]
    private var timeRanges: [UUID: (earliest: Date, latest: Date)] = [:]

    public init(inMemory: Bool = false) {
        let schema = Schema([
            PersistedPoll.self,
            PersistedTimeOption.self,
            PersistedParticipant.self,
            PersistedAvailabilityResponse.self,
            PersistedProfile.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        self.modelContext = modelContainer.mainContext
    }

    // MARK: - Polls

    public func savePolls(_ polls: [Poll]) throws {
        for poll in polls {
            let descriptor = FetchDescriptor<PersistedPoll>(
                predicate: #Predicate { $0.id == poll.id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                if poll.updatedAt >= existing.updatedAt {
                    existing.update(from: poll)
                }
            } else {
                modelContext.insert(PersistedPoll.from(poll))
            }
        }
        try modelContext.save()
    }

    public func fetchAllPolls() throws -> [Poll] {
        let descriptor = FetchDescriptor<PersistedPoll>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toModel() }
    }

    public func fetchPoll(id: UUID) throws -> Poll? {
        let descriptor = FetchDescriptor<PersistedPoll>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first?.toModel()
    }

    public func deletePoll(id: UUID) throws {
        let descriptor = FetchDescriptor<PersistedPoll>(
            predicate: #Predicate { $0.id == id }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    // MARK: - Poll Detail

    public func savePollDetail(_ detail: PollDetail) throws {
        try savePolls([detail.poll])
        try saveTimeOptions(detail.timeOptions, for: detail.poll.id)
        try saveParticipants(detail.participants, for: detail.poll.id)
        try saveResponses(detail.responses)
    }

    public func fetchPollDetail(id: UUID) throws -> PollDetail? {
        guard let poll = try fetchPoll(id: id) else { return nil }
        let timeOptions = try fetchTimeOptions(for: id)
        let participants = try fetchParticipants(for: id)
        let participantIds = participants.map { $0.id }
        let responses = try fetchResponses(for: participantIds)
        return PollDetail(
            poll: poll,
            timeOptions: timeOptions,
            participants: participants,
            responses: responses
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
        let pollDescriptor = FetchDescriptor<PersistedPoll>(
            predicate: #Predicate { $0.id == pollId }
        )
        let persistedPoll = try modelContext.fetch(pollDescriptor).first

        for option in options {
            let descriptor = FetchDescriptor<PersistedTimeOption>(
                predicate: #Predicate { $0.id == option.id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: option)
            } else {
                let persisted = PersistedTimeOption.from(option)
                persisted.poll = persistedPoll
                modelContext.insert(persisted)
            }
        }
        try modelContext.save()
    }

    public func fetchTimeOptions(for pollId: UUID) throws -> [PollTimeOption] {
        let descriptor = FetchDescriptor<PersistedTimeOption>(
            predicate: #Predicate { $0.pollId == pollId },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map { $0.toModel() }
    }

    // MARK: - Participants

    public func saveParticipants(_ participants: [PollParticipant], for pollId: UUID) throws {
        let pollDescriptor = FetchDescriptor<PersistedPoll>(
            predicate: #Predicate { $0.id == pollId }
        )
        let persistedPoll = try modelContext.fetch(pollDescriptor).first

        for participant in participants {
            let descriptor = FetchDescriptor<PersistedParticipant>(
                predicate: #Predicate { $0.id == participant.id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                if participant.updatedAt >= existing.updatedAt {
                    existing.update(from: participant)
                }
            } else {
                let persisted = PersistedParticipant.from(participant)
                persisted.poll = persistedPoll
                modelContext.insert(persisted)
            }
        }
        try modelContext.save()
    }

    public func fetchParticipants(for pollId: UUID) throws -> [PollParticipant] {
        let descriptor = FetchDescriptor<PersistedParticipant>(
            predicate: #Predicate { $0.pollId == pollId }
        )
        return try modelContext.fetch(descriptor).map { $0.toModel() }
    }

    // MARK: - Availability Responses

    public func saveResponses(_ responses: [AvailabilityResponse]) throws {
        for response in responses {
            let descriptor = FetchDescriptor<PersistedAvailabilityResponse>(
                predicate: #Predicate { $0.id == response.id }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                if response.updatedAt >= existing.updatedAt {
                    existing.update(from: response)
                }
            } else {
                let persisted = PersistedAvailabilityResponse.from(response)
                // Link to participant if available
                let participantDescriptor = FetchDescriptor<PersistedParticipant>(
                    predicate: #Predicate { $0.id == response.participantId }
                )
                persisted.participant = try modelContext.fetch(participantDescriptor).first
                modelContext.insert(persisted)
            }
        }
        try modelContext.save()
    }

    public func fetchResponses(for participantIds: [UUID]) throws -> [AvailabilityResponse] {
        guard !participantIds.isEmpty else { return [] }
        let idSet = Set(participantIds)
        let descriptor = FetchDescriptor<PersistedAvailabilityResponse>()
        return try modelContext.fetch(descriptor)
            .filter { idSet.contains($0.participantId) }
            .map { $0.toModel() }
    }

    // MARK: - Profile

    public func saveProfile(_ profile: Profile) throws {
        let descriptor = FetchDescriptor<PersistedProfile>(
            predicate: #Predicate { $0.id == profile.id }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            if profile.updatedAt >= existing.updatedAt {
                existing.update(from: profile)
            }
        } else {
            modelContext.insert(PersistedProfile.from(profile))
        }
        try modelContext.save()
    }

    public func fetchProfile(id: UUID) throws -> Profile? {
        let descriptor = FetchDescriptor<PersistedProfile>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first?.toModel()
    }

    // MARK: - Cache Management

    public func isFresh(_ entityId: UUID, maxAge: TimeInterval) -> Bool {
        let cutoff = Date().addingTimeInterval(-maxAge)

        // Check polls first (most common)
        if let poll = try? modelContext.fetch(
            FetchDescriptor<PersistedPoll>(predicate: #Predicate { $0.id == entityId })
        ).first {
            return poll.lastSyncedAt > cutoff
        }

        // Check profiles
        if let profile = try? modelContext.fetch(
            FetchDescriptor<PersistedProfile>(predicate: #Predicate { $0.id == entityId })
        ).first {
            return profile.lastSyncedAt > cutoff
        }

        return false
    }

    public func clearAll() throws {
        try modelContext.delete(model: PersistedAvailabilityResponse.self)
        try modelContext.delete(model: PersistedParticipant.self)
        try modelContext.delete(model: PersistedTimeOption.self)
        try modelContext.delete(model: PersistedPoll.self)
        try modelContext.delete(model: PersistedProfile.self)
        participantCounts.removeAll()
        timeRanges.removeAll()
        try modelContext.save()
    }
}
