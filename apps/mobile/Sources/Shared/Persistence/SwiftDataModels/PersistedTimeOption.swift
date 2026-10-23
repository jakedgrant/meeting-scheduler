import Foundation
import SwiftData

@Model
public final class PersistedTimeOption {
    @Attribute(.unique) public var id: UUID
    public var pollId: UUID
    public var startTime: Date
    public var endTime: Date
    public var isAllDay: Bool
    public var createdAt: Date
    public var lastSyncedAt: Date

    public var poll: PersistedPoll?

    public init(
        id: UUID,
        pollId: UUID,
        startTime: Date,
        endTime: Date,
        isAllDay: Bool,
        createdAt: Date,
        lastSyncedAt: Date = Date()
    ) {
        self.id = id
        self.pollId = pollId
        self.startTime = startTime
        self.endTime = endTime
        self.isAllDay = isAllDay
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
    }

    public func toModel() -> PollTimeOption {
        PollTimeOption(
            id: id,
            pollId: pollId,
            startTime: startTime,
            endTime: endTime,
            isAllDay: isAllDay,
            createdAt: createdAt
        )
    }

    public func update(from option: PollTimeOption) {
        pollId = option.pollId
        startTime = option.startTime
        endTime = option.endTime
        isAllDay = option.isAllDay
        createdAt = option.createdAt
        lastSyncedAt = Date()
    }

    public static func from(_ option: PollTimeOption) -> PersistedTimeOption {
        PersistedTimeOption(
            id: option.id,
            pollId: option.pollId,
            startTime: option.startTime,
            endTime: option.endTime,
            isAllDay: option.isAllDay,
            createdAt: option.createdAt
        )
    }
}
