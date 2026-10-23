import Foundation
import Supabase

extension PollService {
    public func getAvailability(pollId: UUID, participantId: UUID, guestToken: String? = nil) async throws -> AvailabilitySnapshot {
        var params: [String: AnyJSON] = [
            "poll_uuid": .string(pollId.uuidString), "participant_uuid": .string(participantId.uuidString)
        ]
        if let guestToken { params["guest_token"] = .string(guestToken) }
        do {
            return try await supabase.rpc("get_availability", params: params).execute().value
        } catch { throw Self.commandError(error) }
    }

    public func saveAvailability(_ request: SaveAvailabilityRequest) async throws -> AvailabilitySnapshot {
        do {
            return try await supabase.rpc("save_availability", params: request).execute().value
        } catch { throw Self.commandError(error) }
    }

    public func finalizePoll(pollId: UUID, timeOptionId: UUID) async throws -> Poll {
        do {
            return try await supabase.rpc("finalize_poll", params: [
                "poll_uuid": AnyJSON.string(pollId.uuidString), "time_option_uuid": .string(timeOptionId.uuidString)
            ]).execute().value
        } catch { throw Self.commandError(error) }
    }

    private static func commandError(_ error: Error) -> AvailabilityCommandError {
        guard let error = error as? PostgrestError else { return .transport }
        if error.code == "PT409" { return .conflict }
        if error.code == "42501" {
            if error.message == "Poll is not accepting responses" || error.message == "Poll cannot be finalized" { return .closed }
            return .accessDenied
        }
        if error.code == "22023" || error.code == "23514" { return .invalidRequest }
        return .transport
    }
}
