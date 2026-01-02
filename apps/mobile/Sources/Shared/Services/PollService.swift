import Foundation
import Supabase

// Response structure for get_user_participated_polls RPC
private struct ParticipatedPollsResponse: Decodable {
    let created_polls: [Poll]
    let joined_polls: [Poll]
}

@MainActor
@Observable
public final class PollService {
    public static let shared = PollService()

    public private(set) var myPolls: [Poll] = []
    public private(set) var createdPolls: [Poll] = []
    public private(set) var joinedPolls: [Poll] = []
    public private(set) var isLoading = false

    private let supabase = SupabaseService.shared.client

    private init() {}

    // MARK: - Load Polls

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
        } catch {
            print("Failed to load polls: \(error)")
            createdPolls = []
            joinedPolls = []
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

    public func loadPollByCode(_ code: String) async -> Poll? {
        do {
            let response: [Poll] = try await supabase
                .rpc("get_poll_by_code", params: ["code": AnyJSON.string(code.uppercased())])
                .execute()
                .value

            return response.first
        } catch {
            print("Failed to load poll by code: \(error)")
            return nil
        }
    }

    // MARK: - Create Poll

    public func createPoll(
        title: String,
        description: String?,
        location: String?,
        timezone: String = TimeZone.current.identifier
    ) async throws -> Poll {
        guard let userId = AuthService.shared.currentUser?.id else {
            throw PollError.notAuthenticated
        }

        let newPoll: [String: AnyJSON] = [
            "creator_id": .string(userId.uuidString),
            "title": .string(title),
            "description": description.map { .string($0) } ?? .null,
            "location": location.map { .string($0) } ?? .null,
            "timezone": .string(timezone)
        ]

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
        var data: [String: AnyJSON] = [
            "poll_id": .string(pollId.uuidString)
        ]

        if let userId = AuthService.shared.currentUser?.id {
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

        return response
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

    public func submitAvailability(
        participantId: UUID,
        timeOptionId: UUID,
        status: AvailabilityStatus,
        note: String? = nil
    ) async throws {
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
