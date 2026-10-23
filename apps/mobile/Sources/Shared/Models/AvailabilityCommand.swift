import Foundation

public struct AvailabilityAnswer: Codable, Equatable, Sendable {
    public let timeOptionId: UUID
    public let status: AvailabilityStatus
    public let note: String?
    enum CodingKeys: String, CodingKey { case timeOptionId = "time_option_id", status, note }
    public init(timeOptionId: UUID, status: AvailabilityStatus, note: String? = nil) {
        self.timeOptionId = timeOptionId; self.status = status; self.note = note
    }
}

public struct SavedAvailabilityAnswer: Codable, Sendable {
    public let id: UUID
    public let timeOptionId: UUID
    public let status: AvailabilityStatus
    public let note: String?
    public let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, timeOptionId = "time_option_id", status, note, updatedAt = "updated_at"
    }
    public init(id: UUID = UUID(), timeOptionId: UUID, status: AvailabilityStatus, note: String? = nil, updatedAt: Date = Date()) {
        self.id = id; self.timeOptionId = timeOptionId; self.status = status; self.note = note; self.updatedAt = updatedAt
    }
}

public struct AvailabilitySnapshot: Codable, Sendable {
    public let participantId: UUID
    public let pollId: UUID
    public let version: Int64
    public let comment: String?
    public let responses: [SavedAvailabilityAnswer]
    public let savedAt: Date?
    public let replayed: Bool?
    enum CodingKeys: String, CodingKey {
        case participantId = "participant_id", pollId = "poll_id", version, comment, responses
        case savedAt = "saved_at", replayed
    }
    public init(participantId: UUID, pollId: UUID, version: Int64, comment: String?, responses: [SavedAvailabilityAnswer], savedAt: Date? = nil, replayed: Bool? = nil) {
        self.participantId = participantId; self.pollId = pollId; self.version = version; self.comment = comment
        self.responses = responses; self.savedAt = savedAt; self.replayed = replayed
    }
    public var availabilityResponses: [AvailabilityResponse] {
        responses.map { AvailabilityResponse(id: $0.id, participantId: participantId, timeOptionId: $0.timeOptionId,
                                             status: $0.status, note: $0.note, createdAt: $0.updatedAt, updatedAt: $0.updatedAt) }
    }
}

public struct SaveAvailabilityRequest: Encodable, Sendable {
    public let pollId: UUID
    public let requestId: UUID
    public let responses: [AvailabilityAnswer]
    public let comment: String?
    public let expectedVersion: Int64
    public let participantId: UUID
    public let guestToken: String?
    enum CodingKeys: String, CodingKey {
        case pollId = "poll_uuid", requestId = "request_id", responses, comment
        case expectedVersion = "expected_version", participantId = "participant_uuid", guestToken = "guest_token"
    }
    public init(pollId: UUID, requestId: UUID = UUID(), responses: [AvailabilityAnswer], comment: String?, expectedVersion: Int64, participantId: UUID, guestToken: String? = nil) {
        self.pollId = pollId; self.requestId = requestId; self.responses = responses
        self.comment = comment; self.expectedVersion = expectedVersion; self.participantId = participantId; self.guestToken = guestToken
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(pollId, forKey: .pollId)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(responses, forKey: .responses)
        // This required argument must be present even when clearing a comment.
        try values.encode(comment, forKey: .comment)
        try values.encode(expectedVersion, forKey: .expectedVersion)
        try values.encode(participantId, forKey: .participantId)
        try values.encodeIfPresent(guestToken, forKey: .guestToken)
    }
}

public enum AvailabilityCommandError: Error, LocalizedError, Equatable {
    case conflict, closed, accessDenied, invalidRequest, transport
    public var errorDescription: String? {
        switch self {
        case .conflict: "Responses changed on another device. Load the latest saved responses, review your retained draft, then save again."
        case .closed: "This poll is no longer accepting responses. Your draft has been retained."
        case .accessDenied: "Your poll access has changed. Your draft has been retained; reload the poll to check your access."
        case .invalidRequest: "These responses could not be saved. Reload the poll to check its time options. Your draft has been retained."
        case .transport: "Responses could not be saved. Your draft has been retained. Retry to check or finish the same save."
        }
    }
}
