import Foundation
import Supabase

// Response structure for get_user_participated_polls RPC
private struct ParticipatedPollsResponse: Decodable {
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

    let supabase: SupabaseClient
    private let timeRangeFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    private init() { self.supabase = SupabaseService.shared.client }

    /// Allows transport regression tests without a running server or account session.
    public init(client: SupabaseClient) { self.supabase = client }

    // MARK: - Formatting

    public func formatTimeRange(earliest: Date, latest: Date) -> String {
        "\(timeRangeFormatter.string(from: earliest)) - \(timeRangeFormatter.string(from: latest))"
    }

    // MARK: - Load Polls

    /// Loads all of the user's polls and — in two parallel batch queries — populates
    /// `pollParticipantCounts` and `pollTimeRanges` so the list view needs no per-poll requests.
    public func loadMyPolls() async {
        guard AuthService.shared.currentUser != nil else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let response: ParticipatedPollsResponse = try await supabase
                .rpc("get_user_participated_polls")
                .execute()
                .value

            createdPolls = response.created_polls
            joinedPolls = response.joined_polls
            myPolls = createdPolls + joinedPolls

            guard !myPolls.isEmpty else { return }

            let pollIds = myPolls.map { $0.id.uuidString }

            // Fetch time option summaries and participant IDs in parallel — one request each
            async let timeOptionsFetch = batchLoadTimeOptionSummaries(pollIds: pollIds)
            async let participantsFetch = batchLoadParticipantPollIds(pollIds: pollIds)
            let (timeOptionSummaries, participantPollIds) = await (timeOptionsFetch, participantsFetch)

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

        } catch {
            print("Failed to load polls: \(error)")
            createdPolls = []
            joinedPolls = []
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
        do {
            let response: Poll = try await supabase
                .from("polls")
                .select()
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value

            return response
        } catch {
            print("Failed to load poll: \(error)")
            return nil
        }
    }

    public func loadPollByCode(_ code: String) async -> PollLookupResponse? {
        do {
            let response: [PollLookupResponse] = try await supabase
                .rpc("get_poll_by_code", params: ["code": AnyJSON.string(code.uppercased())])
                .execute()
                .value

            return response.first
        } catch {
            print("Failed to load poll by code: \(error)")
            return nil
        }
    }

    /// Fetches a poll with all its time options, participants (with profile names), and
    /// availability responses in a single nested Supabase query.
    public func loadPollDetail(id: UUID) async -> PollDetail? {
        do {
            let response: PollDetailResponse = try await supabase
                .from("polls")
                .select("*, poll_time_options(*), poll_participants(*, profiles(display_name), availability_responses(*))")
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value

            let participants = response.pollParticipants.map { $0.participant }
            let responses = response.pollParticipants.flatMap { $0.availabilityResponses }

            return PollDetail(
                poll: response.poll,
                timeOptions: response.pollTimeOptions,
                participants: participants,
                responses: responses
            )
        } catch {
            print("Failed to load poll detail: \(error)")
            return nil
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
        guard let userId = AuthService.shared.currentUser?.id else {
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

        myPolls.insert(response, at: 0)
        return response
    }

    // MARK: - Time Options

    public func loadTimeOptions(pollId: UUID) async -> [PollTimeOption] {
        do {
            let response: [PollTimeOption] = try await supabase
                .from("poll_time_options")
                .select()
                .eq("poll_id", value: pollId.uuidString)
                .order("start_time", ascending: true)
                .execute()
                .value

            return response
        } catch {
            print("Failed to load time options: \(error)")
            return []
        }
    }

    public func addTimeOptions(pollId: UUID, options: [(start: Date, end: Date, isAllDay: Bool)]) async throws -> [PollTimeOption] {
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

        return response
    }

    // MARK: - Poll Status

    public func updatePollStatus(pollId: UUID, status: PollStatus) async throws {
        try await supabase
            .from("polls")
            .update(["status": AnyJSON.string(status.rawValue)])
            .eq("id", value: pollId.uuidString)
            .execute()

        // Update local state
        if let index = myPolls.firstIndex(where: { $0.id == pollId }) {
            myPolls[index].status = status
        }
    }

    // MARK: - Participants

    public func loadParticipants(pollId: UUID) async -> [PollParticipant] {
        do {
            let response: [PollParticipant] = try await supabase
                .from("poll_participants")
                .select("*, profiles(display_name)")
                .eq("poll_id", value: pollId.uuidString)
                .execute()
                .value

            return response
        } catch {
            print("Failed to load participants: \(error)")
            return []
        }
    }

    public func joinPoll(pollId: UUID, anonymousName: String? = nil) async throws -> PollParticipant {
        // Native screens require sign-in. The server resolves auth.uid(), and a retry
        // returns the same membership instead of creating another participant.
        struct JoinResult: Decodable { let participant: PollParticipant; let created: Bool }
        let result: JoinResult = try await supabase
            .rpc("join_poll", params: ["poll_uuid": AnyJSON.string(pollId.uuidString)])
            .execute().value
        return result.participant
    }

    // MARK: - Availability Responses

    public func loadResponses(participantIds: [UUID]) async -> [AvailabilityResponse] {
        guard !participantIds.isEmpty else { return [] }

        do {
            let ids = participantIds.map { $0.uuidString }
            let response: [AvailabilityResponse] = try await supabase
                .from("availability_responses")
                .select()
                .in("participant_id", values: ids)
                .execute()
                .value

            return response
        } catch {
            print("Failed to load responses: \(error)")
            return []
        }
    }

    // MARK: - Subscription Checks

    public func canCreatePoll() async -> Bool {
        do {
            let result: Bool = try await supabase
                .rpc("can_create_poll")
                .execute()
                .value

            return result
        } catch {
            print("Failed to check can_create_poll: \(error)")
            return false
        }
    }

    public func countActivePolls() async -> Int {
        do {
            let result: Int = try await supabase
                .rpc("count_active_polls")
                .execute()
                .value

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
