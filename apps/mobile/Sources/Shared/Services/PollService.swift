import Foundation
import Supabase

// Response structure for get_user_participated_polls RPC
struct ParticipatedPollsResponse: Decodable {
    let created_polls: [Poll]
    let joined_polls: [Poll]
}

// Lightweight structs for batch list-view queries
private struct TimeOptionSummary: Decodable {
    let pollId: UUID
    let startTime: Date

    enum CodingKeys: String, CodingKey {
        case pollId = "poll_id"
        case startTime = "start_time"
    }
}

private struct ParticipantPollId: Decodable {
    let pollId: UUID

    enum CodingKeys: String, CodingKey {
        case pollId = "poll_id"
    }
}

// Decoding types for the single-request poll detail nested select
private struct PollDetailResponse: Decodable {
    let id: UUID
    let creatorId: UUID
    let title: String
    let description: String?
    let location: String?
    let status: PollStatus
    let timezone: String
    let isPremium: Bool
    let maxParticipants: Int
    let createdAt: Date
    let updatedAt: Date
    let closesAt: Date?
    let selectedStartTime: Date?
    let selectedEndTime: Date?
    let shareCode: String
    let pollTimeOptions: [PollTimeOption]
    let pollParticipants: [ParticipantDetailResponse]

    enum CodingKeys: String, CodingKey {
        case id
        case creatorId = "creator_id"
        case title, description, location, status, timezone
        case isPremium = "is_premium"
        case maxParticipants = "max_participants"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closesAt = "closes_at"
        case selectedStartTime = "selected_start_time"
        case selectedEndTime = "selected_end_time"
        case shareCode = "share_code"
        case pollTimeOptions = "poll_time_options"
        case pollParticipants = "poll_participants"
    }

    var poll: Poll {
        Poll(
            id: id, creatorId: creatorId, title: title, description: description,
            location: location, status: status, timezone: timezone,
            isPremium: isPremium, maxParticipants: maxParticipants,
            createdAt: createdAt, updatedAt: updatedAt, closesAt: closesAt,
            selectedStartTime: selectedStartTime, selectedEndTime: selectedEndTime,
            shareCode: shareCode
        )
    }
}

private struct ParticipantDetailResponse: Decodable {
    let id: UUID
    let pollId: UUID
    let userId: UUID?
    let anonymousName: String?
    let anonymousEmail: String?
    let accessToken: UUID
    let comment: String?
    let createdAt: Date
    let updatedAt: Date
    let profiles: PollParticipant.ParticipantProfile?
    let availabilityResponses: [AvailabilityResponse]

    enum CodingKeys: String, CodingKey {
        case id
        case pollId = "poll_id"
        case userId = "user_id"
        case anonymousName = "anonymous_name"
        case anonymousEmail = "anonymous_email"
        case accessToken = "access_token"
        case comment
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case profiles
        case availabilityResponses = "availability_responses"
    }

    var participant: PollParticipant {
        PollParticipant(
            id: id, pollId: pollId, userId: userId, anonymousName: anonymousName,
            anonymousEmail: anonymousEmail, accessToken: accessToken, comment: comment,
            createdAt: createdAt, updatedAt: updatedAt, profiles: profiles
        )
    }
}

@MainActor
@Observable
public final class PollService: PollServiceProtocol {
    public static let shared = PollService()

    public private(set) var myPolls: [Poll] = []
    public private(set) var createdPolls: [Poll] = []
    public private(set) var joinedPolls: [Poll] = []
    public private(set) var isLoading = false

    /// Participant counts keyed by poll ID — populated during loadMyPolls() via a single batch query.
    public private(set) var pollParticipantCounts: [UUID: Int] = [:]

    /// Time ranges keyed by poll ID — populated during loadMyPolls() via a single batch query.
    public private(set) var pollTimeRanges: [UUID: (earliest: Date, latest: Date)] = [:]

    private var supabase: SupabaseClient { SupabaseService.shared.client }
    private let currentUserId: @MainActor () -> UUID?
    private let listLoader: (@MainActor () async throws -> (created: [Poll], joined: [Poll]))?
    private let detailLoader: (@MainActor (UUID) async throws -> PollDetail)?
    private let statusUpdater: (@MainActor (UUID, PollStatus) async throws -> Void)?
    private var accountId: UUID?
    private var accountGeneration: UInt64 = 0
    private var detailGenerations: [UUID: UInt64] = [:]
    private let persistence: any PersistenceProviderProtocol
    private let timeRangeFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    private init() {
        self.persistence = AccountPersistence.shared
        self.currentUserId = { AuthService.shared.currentUserId }
        self.listLoader = nil
        self.detailLoader = nil
        self.statusUpdater = nil
    }

    public init(
        persistence: any PersistenceProviderProtocol,
        currentUserId: @escaping @MainActor () -> UUID? = { AuthService.shared.currentUserId },
        listLoader: (@MainActor () async throws -> (created: [Poll], joined: [Poll]))? = nil,
        detailLoader: (@MainActor (UUID) async throws -> PollDetail)? = nil,
        statusUpdater: (@MainActor (UUID, PollStatus) async throws -> Void)? = nil
    ) {
        self.persistence = persistence
        self.currentUserId = currentUserId
        self.listLoader = listLoader
        self.detailLoader = detailLoader
        self.statusUpdater = statusUpdater
    }

    /// Called synchronously at every auth identity boundary, before any new account work.
    public func accountDidChange(to userId: UUID?) {
        guard accountId != userId else { return }
        accountGeneration &+= 1
        accountId = userId
        myPolls = []
        createdPolls = []
        joinedPolls = []
        pollParticipantCounts = [:]
        pollTimeRanges = [:]
        detailGenerations = [:]
        isLoading = false
        try? persistence.selectAccount(userId)
    }

    private func beginRequest() -> UInt64 {
        accountDidChange(to: currentUserId())
        return accountGeneration
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == accountGeneration && currentUserId() == accountId
    }

    private func invalidateDetail(_ pollId: UUID) {
        detailGenerations[pollId, default: 0] &+= 1
        try? persistence.invalidatePollDetail(pollId)
    }

    private func invalidateAllDetails() {
        for poll in (try? persistence.fetchAllPolls()) ?? [] { invalidateDetail(poll.id) }
    }

    // MARK: - Formatting

    public func formatTimeRange(earliest: Date, latest: Date) -> String {
        "\(timeRangeFormatter.string(from: earliest)) - \(timeRangeFormatter.string(from: latest))"
    }

    // MARK: - Load Polls

    /// Loads all of the user's polls and — in two parallel batch queries — populates
    /// `pollParticipantCounts` and `pollTimeRanges` so the list view needs no per-poll requests.
    ///
    /// Uses a cache-then-network strategy: cached data is returned immediately so the UI renders
    /// without waiting for the network. A background fetch then refreshes from the server.
    public func loadMyPolls() async {
        let generation = beginRequest()
        guard let userId = accountId else { return }

        // 1. Return cached data immediately
        if let cached = try? persistence.fetchAllPolls(), !cached.isEmpty {
            createdPolls = cached.filter { $0.creatorId == userId }
            joinedPolls = cached.filter { $0.creatorId != userId }
            myPolls = createdPolls + joinedPolls
            pollParticipantCounts = (try? persistence.fetchPollParticipantCounts()) ?? [:]
            pollTimeRanges = (try? persistence.fetchPollTimeRanges()) ?? [:]
        }

        // 2. Fetch from server (only show spinner if cache was empty)
        isLoading = myPolls.isEmpty
        defer { if isCurrent(generation) { isLoading = false } }

        do {
            let result: (created: [Poll], joined: [Poll])
            if let listLoader {
                result = try await listLoader()
            } else {
                let response: ParticipatedPollsResponse = try await supabase
                    .rpc("get_user_participated_polls")
                    .execute()
                    .value
                result = (response.created_polls, response.joined_polls)
            }
            guard isCurrent(generation) else { return }
            createdPolls = result.created
            joinedPolls = result.joined
            myPolls = createdPolls + joinedPolls

            // A complete list also invalidates any in-flight detail for an evicted poll.
            let accessible = Set(myPolls.map(\.id))
            for id in detailGenerations.keys.filter({ !accessible.contains($0) }) { invalidateDetail(id) }
            try? persistence.replacePollsSnapshot(myPolls)
            pollParticipantCounts = [:]
            pollTimeRanges = [:]

            guard !myPolls.isEmpty, listLoader == nil else { return }

            let pollIds = myPolls.map { $0.id.uuidString }

            // Fetch time option summaries and participant IDs in parallel — one request each
            async let timeOptionsFetch = batchLoadTimeOptionSummaries(pollIds: pollIds)
            async let participantsFetch = batchLoadParticipantPollIds(pollIds: pollIds)
            let (timeOptionSummaries, participantPollIds) = await (timeOptionsFetch, participantsFetch)

            guard isCurrent(generation) else { return }
            // Derive time ranges (options are ordered by start_time ascending)
            var timeRanges: [UUID: (earliest: Date, latest: Date)] = [:]
            for summary in timeOptionSummaries {
                if let existing = timeRanges[summary.pollId] {
                    timeRanges[summary.pollId] = (
                        earliest: min(existing.earliest, summary.startTime),
                        latest: max(existing.latest, summary.startTime)
                    )
                } else {
                    timeRanges[summary.pollId] = (earliest: summary.startTime, latest: summary.startTime)
                }
            }
            pollTimeRanges = timeRanges

            // Derive participant counts
            var counts: [UUID: Int] = [:]
            for entry in participantPollIds {
                counts[entry.pollId, default: 0] += 1
            }
            pollParticipantCounts = counts

            // 4. Persist metadata
            for (pollId, range) in pollTimeRanges {
                try? persistence.savePollTimeRange(earliest: range.earliest, latest: range.latest, for: pollId)
            }
            for (pollId, count) in pollParticipantCounts {
                try? persistence.savePollParticipantCount(count, for: pollId)
            }

        } catch {
            guard isCurrent(generation) else { return }
            print("Failed to load polls: \(error)")
            // On network failure, keep cached data visible rather than clearing
            if myPolls.isEmpty {
                createdPolls = []
                joinedPolls = []
            }
        }
    }

    private func batchLoadTimeOptionSummaries(pollIds: [String]) async -> [TimeOptionSummary] {
        do {
            return try await supabase
                .from("poll_time_options")
                .select("poll_id, start_time")
                .in("poll_id", values: pollIds)
                .order("start_time", ascending: true)
                .execute()
                .value
        } catch {
            print("Failed to batch load time option summaries: \(error)")
            return []
        }
    }

    private func batchLoadParticipantPollIds(pollIds: [String]) async -> [ParticipantPollId] {
        do {
            return try await supabase
                .from("poll_participants")
                .select("poll_id")
                .in("poll_id", values: pollIds)
                .execute()
                .value
        } catch {
            print("Failed to batch load participant counts: \(error)")
            return []
        }
    }

    public func loadPoll(id: UUID) async -> Poll? {
        let generation = beginRequest()
        do {
            let response: Poll = try await supabase
                .from("polls")
                .select()
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value

            guard isCurrent(generation) else { return nil }
            try? persistence.savePolls([response])
            return response
        } catch {
            guard isCurrent(generation) else { return nil }
            print("Failed to load poll: \(error)")
            return try? persistence.fetchPoll(id: id)
        }
    }

    public func loadPollByCode(_ code: String) async -> PollLookupResponse? {
        let generation = beginRequest()
        do {
            let response: [PollLookupResponse] = try await supabase
                .rpc("get_poll_by_code", params: ["code": AnyJSON.string(code.uppercased())])
                .execute()
                .value

            guard isCurrent(generation) else { return nil }
            return response.first
        } catch {
            guard isCurrent(generation) else { return nil }
            print("Failed to load poll by code: \(error)")
            return nil
        }
    }

    /// Fetches a poll with all its time options, participants (with profile names), and
    /// availability responses in a single nested Supabase query.
    ///
    /// Returns cached detail immediately if fresh, otherwise fetches from the server.
    /// On network failure, falls back to stale cached data.
    public func loadPollDetail(id: UUID) async -> PollDetail? {
        let generation = beginRequest()
        detailGenerations[id, default: 0] &+= 0
        let detailGeneration = detailGenerations[id, default: 0]
        if persistence.isDetailFresh(id, maxAge: 300),
           let cached = try? persistence.fetchPollDetail(id: id) { return cached }
        do {
            let detail: PollDetail
            if let detailLoader {
                detail = try await detailLoader(id)
            } else {
                let response: PollDetailResponse = try await supabase
                    .from("polls")
                    .select("*, poll_time_options(*), poll_participants(*, profiles(display_name), availability_responses(*))")
                    .eq("id", value: id.uuidString)
                    .single()
                    .execute()
                    .value
                detail = PollDetail(
                    poll: response.poll, timeOptions: response.pollTimeOptions,
                    participants: response.pollParticipants.map { $0.participant },
                    responses: response.pollParticipants.flatMap { $0.availabilityResponses }
                )
            }
            guard isCurrent(generation), detailGeneration == detailGenerations[id, default: 0] else { return nil }
            try? persistence.savePollDetail(detail)
            return detail
        } catch {
            guard isCurrent(generation), detailGeneration == detailGenerations[id, default: 0] else { return nil }
            // A successful complete list has already evicted inaccessible/deleted polls.
            // Only transport failures use stale data; an authoritative not-found does not.
            if let error = error as? PostgrestError, ["PGRST116", "42501"].contains(error.code ?? "") {
                try? persistence.deletePoll(id: id)
                return nil
            }
            return try? persistence.fetchPollDetail(id: id)
        }
    }

    // MARK: - Create Poll

    public func createPoll(
        title: String,
        description: String?,
        location: String?,
        timezone: String = TimeZone.current.identifier,
        closesAt: Date? = nil
    ) async throws -> Poll {
        let generation = beginRequest()
        guard let userId = accountId else {
            throw PollError.notAuthenticated
        }

        var newPoll: [String: AnyJSON] = [
            "creator_id": .string(userId.uuidString),
            "title": .string(title),
            "description": description.map { .string($0) } ?? .null,
            "location": location.map { .string($0) } ?? .null,
            "timezone": .string(timezone),
            "status": .string(PollStatus.active.rawValue)
        ]

        if let closesAt = closesAt {
            newPoll["closes_at"] = .string(closesAt.ISO8601Format())
        }

        let response: Poll = try await supabase
            .from("polls")
            .insert(newPoll)
            .select()
            .single()
            .execute()
            .value

        guard isCurrent(generation) else { throw CancellationError() }
        try? persistence.savePolls([response])
        myPolls.insert(response, at: 0)
        return response
    }

    // MARK: - Time Options

    public func loadTimeOptions(pollId: UUID) async -> [PollTimeOption] {
        let generation = beginRequest()
        do {
            let response: [PollTimeOption] = try await supabase
                .from("poll_time_options")
                .select()
                .eq("poll_id", value: pollId.uuidString)
                .order("start_time", ascending: true)
                .execute()
                .value

            guard isCurrent(generation) else { return [] }
            try? persistence.saveTimeOptions(response, for: pollId)
            return response
        } catch {
            guard isCurrent(generation) else { return [] }
            print("Failed to load time options: \(error)")
            return (try? persistence.fetchTimeOptions(for: pollId)) ?? []
        }
    }

    public func addTimeOptions(pollId: UUID, options: [(start: Date, end: Date, isAllDay: Bool)]) async throws -> [PollTimeOption] {
        let generation = beginRequest()
        let formatter = ISO8601DateFormatter()

        let insertData: [[String: AnyJSON]] = options.map { option in
            [
                "poll_id": .string(pollId.uuidString),
                "start_time": .string(formatter.string(from: option.start)),
                "end_time": .string(formatter.string(from: option.end)),
                "is_all_day": .bool(option.isAllDay)
            ]
        }

        let response: [PollTimeOption] = try await supabase
            .from("poll_time_options")
            .insert(insertData)
            .select()
            .execute()
            .value

        guard isCurrent(generation) else { throw CancellationError() }
        invalidateDetail(pollId)
        return response
    }

    // MARK: - Poll Status

    public func updatePollStatus(pollId: UUID, status: PollStatus) async throws {
        let generation = beginRequest()
        if let statusUpdater {
            try await statusUpdater(pollId, status)
        } else {
            try await supabase
                .from("polls")
                .update(["status": AnyJSON.string(status.rawValue)])
                .eq("id", value: pollId.uuidString)
                .execute()
        }

        guard isCurrent(generation) else { throw CancellationError() }
        invalidateDetail(pollId)
        // Update local state
        if let index = myPolls.firstIndex(where: { $0.id == pollId }) {
            myPolls[index].status = status
        }
    }

    public func setSelectedFinalDate(pollId: UUID, startTime: Date, endTime: Date) async throws {
        let generation = beginRequest()
        let formatter = ISO8601DateFormatter()

        try await supabase
            .from("polls")
            .update([
                "selected_start_time": AnyJSON.string(formatter.string(from: startTime)),
                "selected_end_time": AnyJSON.string(formatter.string(from: endTime))
            ])
            .eq("id", value: pollId.uuidString)
            .execute()

        guard isCurrent(generation) else { throw CancellationError() }
        invalidateDetail(pollId)
        // Update local state
        if let index = myPolls.firstIndex(where: { $0.id == pollId }) {
            myPolls[index].selectedStartTime = startTime
            myPolls[index].selectedEndTime = endTime
        }
    }

    // MARK: - Participants

    public func loadParticipants(pollId: UUID) async -> [PollParticipant] {
        let generation = beginRequest()
        do {
            let response: [PollParticipant] = try await supabase
                .from("poll_participants")
                .select("*, profiles(display_name)")
                .eq("poll_id", value: pollId.uuidString)
                .execute()
                .value

            guard isCurrent(generation) else { return [] }
            try? persistence.saveParticipants(response, for: pollId)
            return response
        } catch {
            guard isCurrent(generation) else { return [] }
            print("Failed to load participants: \(error)")
            return (try? persistence.fetchParticipants(for: pollId)) ?? []
        }
    }

    public func joinPoll(pollId: UUID, anonymousName: String? = nil) async throws -> PollParticipant {
        let generation = beginRequest()
        var data: [String: AnyJSON] = [
            "poll_id": .string(pollId.uuidString)
        ]

        if let userId = accountId {
            data["user_id"] = .string(userId.uuidString)
        } else if let name = anonymousName {
            data["anonymous_name"] = .string(name)
        }

        let response: PollParticipant = try await supabase
            .from("poll_participants")
            .insert(data)
            .select()
            .single()
            .execute()
            .value

        guard isCurrent(generation) else { throw CancellationError() }
        invalidateDetail(pollId)
        return response
    }

    // MARK: - Availability Responses

    public func loadResponses(participantIds: [UUID]) async -> [AvailabilityResponse] {
        let generation = beginRequest()
        guard !participantIds.isEmpty else { return [] }

        do {
            let ids = participantIds.map { $0.uuidString }
            let response: [AvailabilityResponse] = try await supabase
                .from("availability_responses")
                .select()
                .in("participant_id", values: ids)
                .execute()
                .value

            guard isCurrent(generation) else { return [] }
            try? persistence.replaceResponsesSnapshot(response, for: participantIds)
            return response
        } catch {
            guard isCurrent(generation) else { return [] }
            print("Failed to load responses: \(error)")
            return (try? persistence.fetchResponses(for: participantIds)) ?? []
        }
    }

    public func submitAvailability(
        participantId: UUID,
        timeOptionId: UUID,
        status: AvailabilityStatus,
        note: String? = nil
    ) async throws {
        let generation = beginRequest()
        let data: [String: AnyJSON] = [
            "participant_id": .string(participantId.uuidString),
            "time_option_id": .string(timeOptionId.uuidString),
            "status": .string(status.rawValue),
            "note": note.map { .string($0) } ?? .null
        ]

        try await supabase
            .from("availability_responses")
            .upsert(data, onConflict: "participant_id,time_option_id")
            .execute()
        guard isCurrent(generation) else { throw CancellationError() }
        invalidateAllDetails()
    }

    public func updateParticipantComment(participantId: UUID, comment: String?) async throws {
        let generation = beginRequest()
        let data: [String: AnyJSON] = [
            "comment": comment.map { .string($0) } ?? .null
        ]

        try await supabase
            .from("poll_participants")
            .update(data)
            .eq("id", value: participantId.uuidString)
            .execute()
        guard isCurrent(generation) else { throw CancellationError() }
        invalidateAllDetails()
    }

    // MARK: - Subscription Checks

    public func canCreatePoll() async -> Bool {
        let generation = beginRequest()
        do {
            let result: Bool = try await supabase
                .rpc("can_create_poll")
                .execute()
                .value

            guard isCurrent(generation) else { return false }
            return result
        } catch {
            print("Failed to check can_create_poll: \(error)")
            return false
        }
    }

    public func countActivePolls() async -> Int {
        let generation = beginRequest()
        do {
            let result: Int = try await supabase
                .rpc("count_active_polls")
                .execute()
                .value

            guard isCurrent(generation) else { return 0 }
            return result
        } catch {
            print("Failed to count active polls: \(error)")
            return 0
        }
    }
}

public enum PollError: Error {
    case notAuthenticated
    case pollNotFound
}
