import Foundation
import SwiftData

@MainActor
public final class SwiftDataPersistenceProvider: PersistenceProviderProtocol {
    private var modelContainer: ModelContainer
    private var modelContext: ModelContext
    private let now: @MainActor () -> Date
    private let inMemory: Bool
    private var accountId: UUID?
    private var reconcilingSnapshot = false

    // In-memory metadata not worth persisting as @Model objects
    private var participantCounts: [UUID: Int] = [:]
    private var timeRanges: [UUID: (earliest: Date, latest: Date)] = [:]

    public init(inMemory: Bool = false, now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
        self.inMemory = inMemory
        do {
            let container = try Self.makeContainer(accountId: nil, inMemory: true)
            self.modelContainer = container
            self.modelContext = container.mainContext
        } catch {
            fatalError("Failed to create private cache: \(error)")
        }
    }

    private static func makeContainer(accountId: UUID?, inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([
            PersistedPoll.self, PersistedTimeOption.self, PersistedParticipant.self,
            PersistedAvailabilityResponse.self, PersistedProfile.self,
        ])
        // The old unscoped default.store is intentionally never opened.
        let name = accountId.map { "account-\($0.uuidString)" } ?? "signed-out"
        let config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: inMemory || accountId == nil)
        return try ModelContainer(for: schema, configurations: [config])
    }

    public func selectAccount(_ accountId: UUID?) throws {
        guard self.accountId != accountId else { return }
        // Clear before switching; failure cannot expose the old context to the new identity.
        defer { participantCounts.removeAll(); timeRanges.removeAll() }
        do {
            try clearAll()
            let container = try Self.makeContainer(accountId: accountId, inMemory: inMemory)
            modelContainer = container
            modelContext = container.mainContext
            self.accountId = accountId
        } catch {
            let empty = try Self.makeContainer(accountId: nil, inMemory: true)
            modelContainer = empty
            modelContext = empty.mainContext
            self.accountId = nil
            throw error
        }
    }

    private func saveChanges() throws {
        if !reconcilingSnapshot { try modelContext.save() }
    }

    public func replacePollsSnapshot(_ polls: [Poll]) throws {
        let ids = Set(polls.map(\.id))
        try modelContext.transaction {
            reconcilingSnapshot = true
            defer { reconcilingSnapshot = false }
            for existing in try modelContext.fetch(FetchDescriptor<PersistedPoll>()) where !ids.contains(existing.id) {
                modelContext.delete(existing)
                participantCounts.removeValue(forKey: existing.id)
                timeRanges.removeValue(forKey: existing.id)
            }
            try savePolls(polls)
            try modelContext.save()
        }
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
        try saveChanges()
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
            try saveChanges()
        }
    }

    // MARK: - Poll Detail

    public func savePollDetail(_ detail: PollDetail) throws {
        do {
            try modelContext.transaction {
                reconcilingSnapshot = true
                defer { reconcilingSnapshot = false }
                // These collections are complete. Replace them, including missing rows,
                // in one transaction; partial child reads continue to use upserts below.
                try invalidatePollDetail(detail.poll.id)
                try savePolls([detail.poll])
                try saveTimeOptions(detail.timeOptions, for: detail.poll.id)
                try saveParticipants(detail.participants, for: detail.poll.id)
                try saveResponses(detail.responses)
                let id = detail.poll.id
                let poll = try modelContext.fetch(FetchDescriptor<PersistedPoll>(predicate: #Predicate { $0.id == id })).first
                poll?.detailSyncedAt = now()
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func fetchPollDetail(id: UUID) throws -> PollDetail? {
        let persisted = try modelContext.fetch(FetchDescriptor<PersistedPoll>(predicate: #Predicate { $0.id == id })).first
        guard let persisted, persisted.detailSyncedAt != nil else { return nil }
        let poll = persisted.toModel()
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

        let retained = Set(options.map(\.id))
        let previous = try modelContext.fetch(FetchDescriptor<PersistedTimeOption>(predicate: #Predicate { $0.pollId == pollId }))
        let removed = Set(previous.filter { !retained.contains($0.id) }.map(\.id))
        for response in try modelContext.fetch(FetchDescriptor<PersistedAvailabilityResponse>()) where removed.contains(response.timeOptionId) {
            modelContext.delete(response)
        }
        for option in previous where removed.contains(option.id) { modelContext.delete(option) }
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
        try saveChanges()
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

        let retained = Set(participants.map(\.id))
        for previous in try modelContext.fetch(FetchDescriptor<PersistedParticipant>(predicate: #Predicate { $0.pollId == pollId })) where !retained.contains(previous.id) {
            modelContext.delete(previous)
        }
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
        try saveChanges()
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
        try saveChanges()
    }

    public func replaceResponsesSnapshot(_ responses: [AvailabilityResponse], for participantIds: [UUID]) throws {
        let participantIds = Set(participantIds)
        let retained = Set(responses.map(\.id))
        for previous in try modelContext.fetch(FetchDescriptor<PersistedAvailabilityResponse>())
            where participantIds.contains(previous.participantId) && !retained.contains(previous.id) {
            modelContext.delete(previous)
        }
        try saveResponses(responses)
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
        try saveChanges()
    }

    public func fetchProfile(id: UUID) throws -> Profile? {
        let descriptor = FetchDescriptor<PersistedProfile>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first?.toModel()
    }

    // MARK: - Cache Management

    public func isDetailFresh(_ pollId: UUID, maxAge: TimeInterval) -> Bool {
        let poll = try? modelContext.fetch(FetchDescriptor<PersistedPoll>(predicate: #Predicate { $0.id == pollId })).first
        guard let date = poll?.detailSyncedAt else { return false }
        return now().timeIntervalSince(date) < maxAge
    }

    public func invalidatePollDetail(_ pollId: UUID) throws {
        for option in try modelContext.fetch(FetchDescriptor<PersistedTimeOption>(predicate: #Predicate { $0.pollId == pollId })) {
            modelContext.delete(option)
        }
        for participant in try modelContext.fetch(FetchDescriptor<PersistedParticipant>(predicate: #Predicate { $0.pollId == pollId })) {
            modelContext.delete(participant)
        }
        let poll = try modelContext.fetch(FetchDescriptor<PersistedPoll>(predicate: #Predicate { $0.id == pollId })).first
        poll?.detailSyncedAt = nil
        try saveChanges()
    }

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
        try saveChanges()
    }
}
