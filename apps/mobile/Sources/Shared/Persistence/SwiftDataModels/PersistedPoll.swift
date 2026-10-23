import Foundation
import SwiftData

@Model
public final class PersistedPoll {
    @Attribute(.unique) public var id: UUID
    public var creatorId: UUID
    public var title: String
    public var pollDescription: String?
    public var location: String?
    public var statusRawValue: String
    public var timezone: String
    public var isPremium: Bool
    public var maxParticipants: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var closesAt: Date?
    public var selectedStartTime: Date?
    public var selectedEndTime: Date?
    public var shareCode: String
    public var lastSyncedAt: Date
    /// Updated only after a complete detail snapshot, never by a list upsert.
    public var detailSyncedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \PersistedTimeOption.poll)
    public var timeOptions: [PersistedTimeOption]

    @Relationship(deleteRule: .cascade, inverse: \PersistedParticipant.poll)
    public var participants: [PersistedParticipant]

    public init(
        id: UUID,
        creatorId: UUID,
        title: String,
        pollDescription: String?,
        location: String?,
        statusRawValue: String,
        timezone: String,
        isPremium: Bool,
        maxParticipants: Int,
        createdAt: Date,
        updatedAt: Date,
        closesAt: Date?,
        selectedStartTime: Date?,
        selectedEndTime: Date?,
        shareCode: String,
        lastSyncedAt: Date = Date()
    ) {
        self.id = id
        self.creatorId = creatorId
        self.title = title
        self.pollDescription = pollDescription
        self.location = location
        self.statusRawValue = statusRawValue
        self.timezone = timezone
        self.isPremium = isPremium
        self.maxParticipants = maxParticipants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closesAt = closesAt
        self.selectedStartTime = selectedStartTime
        self.selectedEndTime = selectedEndTime
        self.shareCode = shareCode
        self.lastSyncedAt = lastSyncedAt
        self.detailSyncedAt = nil
        self.timeOptions = []
        self.participants = []
    }

    public func toModel() -> Poll {
        Poll(
            id: id,
            creatorId: creatorId,
            title: title,
            description: pollDescription,
            location: location,
            status: PollStatus(rawValue: statusRawValue) ?? .draft,
            timezone: timezone,
            isPremium: isPremium,
            maxParticipants: maxParticipants,
            createdAt: createdAt,
            updatedAt: updatedAt,
            closesAt: closesAt,
            selectedStartTime: selectedStartTime,
            selectedEndTime: selectedEndTime,
            shareCode: shareCode
        )
    }

    public func update(from poll: Poll) {
        creatorId = poll.creatorId
        title = poll.title
        pollDescription = poll.description
        location = poll.location
        statusRawValue = poll.status.rawValue
        timezone = poll.timezone
        isPremium = poll.isPremium
        maxParticipants = poll.maxParticipants
        createdAt = poll.createdAt
        updatedAt = poll.updatedAt
        closesAt = poll.closesAt
        selectedStartTime = poll.selectedStartTime
        selectedEndTime = poll.selectedEndTime
        shareCode = poll.shareCode
        lastSyncedAt = Date()
    }

    public static func from(_ poll: Poll) -> PersistedPoll {
        PersistedPoll(
            id: poll.id,
            creatorId: poll.creatorId,
            title: poll.title,
            pollDescription: poll.description,
            location: poll.location,
            statusRawValue: poll.status.rawValue,
            timezone: poll.timezone,
            isPremium: poll.isPremium,
            maxParticipants: poll.maxParticipants,
            createdAt: poll.createdAt,
            updatedAt: poll.updatedAt,
            closesAt: poll.closesAt,
            selectedStartTime: poll.selectedStartTime,
            selectedEndTime: poll.selectedEndTime,
            shareCode: poll.shareCode
        )
    }
}
