import Foundation
import SwiftData

@Model
public final class PersistedAvailabilityResponse {
    @Attribute(.unique) public var id: UUID
    public var participantId: UUID
    public var timeOptionId: UUID
    public var statusRawValue: String
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSyncedAt: Date

    public var participant: PersistedParticipant?

    public init(
        id: UUID,
        participantId: UUID,
        timeOptionId: UUID,
        statusRawValue: String,
        note: String?,
        createdAt: Date,
        updatedAt: Date,
        lastSyncedAt: Date = Date()
    ) {
        self.id = id
        self.participantId = participantId
        self.timeOptionId = timeOptionId
        self.statusRawValue = statusRawValue
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
    }

    public func toModel() -> AvailabilityResponse {
        AvailabilityResponse(
            id: id,
            participantId: participantId,
            timeOptionId: timeOptionId,
            status: AvailabilityStatus(rawValue: statusRawValue) ?? .unavailable,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    public func update(from response: AvailabilityResponse) {
        participantId = response.participantId
        timeOptionId = response.timeOptionId
        statusRawValue = response.status.rawValue
        note = response.note
        createdAt = response.createdAt
        updatedAt = response.updatedAt
        lastSyncedAt = Date()
    }

    public static func from(_ response: AvailabilityResponse) -> PersistedAvailabilityResponse {
        PersistedAvailabilityResponse(
            id: response.id,
            participantId: response.participantId,
            timeOptionId: response.timeOptionId,
            statusRawValue: response.status.rawValue,
            note: response.note,
            createdAt: response.createdAt,
            updatedAt: response.updatedAt
        )
    }
}
