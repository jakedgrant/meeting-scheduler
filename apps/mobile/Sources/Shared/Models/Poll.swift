import Foundation

public enum PollStatus: String, Codable, Sendable {
    case draft
    case active
    case closed
    case archived
}

public enum AvailabilityStatus: String, Codable, Sendable {
    case available
    case maybe
    case unavailable
}

public struct Poll: Codable, Identifiable, Sendable {
    public let id: UUID
    public let creatorId: UUID
    public var title: String
    public var description: String?
    public var location: String?
    public var status: PollStatus
    public var timezone: String
    public var isPremium: Bool
    public var maxParticipants: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var closesAt: Date?
    public var selectedStartTime: Date?
    public var selectedEndTime: Date?
    public let shareCode: String

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
    }

    public init(
        id: UUID = UUID(),
        creatorId: UUID,
        title: String,
        description: String? = nil,
        location: String? = nil,
        status: PollStatus = .draft,
        timezone: String = "UTC",
        isPremium: Bool = false,
        maxParticipants: Int = 10,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        closesAt: Date? = nil,
        selectedStartTime: Date? = nil,
        selectedEndTime: Date? = nil,
        shareCode: String = ""
    ) {
        self.id = id
        self.creatorId = creatorId
        self.title = title
        self.description = description
        self.location = location
        self.status = status
        self.timezone = timezone
        self.isPremium = isPremium
        self.maxParticipants = maxParticipants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closesAt = closesAt
        self.selectedStartTime = selectedStartTime
        self.selectedEndTime = selectedEndTime
        self.shareCode = shareCode
    }
}

public struct PollTimeOption: Codable, Identifiable, Sendable {
    public let id: UUID
    public let pollId: UUID
    public let startTime: Date
    public let endTime: Date
    public var isAllDay: Bool
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case pollId = "poll_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case isAllDay = "is_all_day"
        case createdAt = "created_at"
    }

    public init(
        id: UUID = UUID(),
        pollId: UUID,
        startTime: Date,
        endTime: Date,
        isAllDay: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.pollId = pollId
        self.startTime = startTime
        self.endTime = endTime
        self.isAllDay = isAllDay
        self.createdAt = createdAt
    }
}

public struct PollParticipant: Codable, Identifiable, Sendable {
    public let id: UUID
    public let pollId: UUID
    public var userId: UUID?
    public var anonymousName: String?
    public var anonymousEmail: String?
    public let accessToken: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var profiles: ParticipantProfile?

    public struct ParticipantProfile: Codable, Sendable {
        public let displayName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case pollId = "poll_id"
        case userId = "user_id"
        case anonymousName = "anonymous_name"
        case anonymousEmail = "anonymous_email"
        case accessToken = "access_token"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case profiles
    }

    public var displayName: String {
        profiles?.displayName ?? anonymousName ?? "Anonymous"
    }

    public init(
        id: UUID = UUID(),
        pollId: UUID,
        userId: UUID? = nil,
        anonymousName: String? = nil,
        anonymousEmail: String? = nil,
        accessToken: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        profiles: ParticipantProfile? = nil
    ) {
        self.id = id
        self.pollId = pollId
        self.userId = userId
        self.anonymousName = anonymousName
        self.anonymousEmail = anonymousEmail
        self.accessToken = accessToken
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.profiles = profiles
    }
}

public struct AvailabilityResponse: Codable, Identifiable, Sendable {
    public let id: UUID
    public let participantId: UUID
    public let timeOptionId: UUID
    public var status: AvailabilityStatus
    public var note: String?
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case participantId = "participant_id"
        case timeOptionId = "time_option_id"
        case status, note
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID = UUID(),
        participantId: UUID,
        timeOptionId: UUID,
        status: AvailabilityStatus,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.participantId = participantId
        self.timeOptionId = timeOptionId
        self.status = status
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
