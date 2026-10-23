import Foundation
import SwiftData

@Model
public final class PersistedParticipant {
    @Attribute(.unique) public var id: UUID
    public var pollId: UUID
    public var userId: UUID?
    public var anonymousName: String?
    public var anonymousEmail: String?
    public var accessToken: UUID
    public var comment: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var profileDisplayName: String?
    public var lastSyncedAt: Date

    public var poll: PersistedPoll?

    @Relationship(deleteRule: .cascade, inverse: \PersistedAvailabilityResponse.participant)
    public var responses: [PersistedAvailabilityResponse]

    public init(
        id: UUID,
        pollId: UUID,
        userId: UUID?,
        anonymousName: String?,
        anonymousEmail: String?,
        accessToken: UUID,
        comment: String?,
        createdAt: Date,
        updatedAt: Date,
        profileDisplayName: String?,
        lastSyncedAt: Date = Date()
    ) {
        self.id = id
        self.pollId = pollId
        self.userId = userId
        self.anonymousName = anonymousName
        self.anonymousEmail = anonymousEmail
        self.accessToken = accessToken
        self.comment = comment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.profileDisplayName = profileDisplayName
        self.lastSyncedAt = lastSyncedAt
        self.responses = []
    }

    public func toModel() -> PollParticipant {
        let profile = profileDisplayName.map {
            PollParticipant.ParticipantProfile(displayName: $0)
        }
        return PollParticipant(
            id: id,
            pollId: pollId,
            userId: userId,
            anonymousName: anonymousName,
            anonymousEmail: anonymousEmail,
            accessToken: accessToken,
            comment: comment,
            createdAt: createdAt,
            updatedAt: updatedAt,
            profiles: profile
        )
    }

    public func update(from participant: PollParticipant) {
        pollId = participant.pollId
        userId = participant.userId
        anonymousName = participant.anonymousName
        anonymousEmail = participant.anonymousEmail
        accessToken = participant.accessToken
        comment = participant.comment
        createdAt = participant.createdAt
        updatedAt = participant.updatedAt
        profileDisplayName = participant.profiles?.displayName
        lastSyncedAt = Date()
    }

    public static func from(_ participant: PollParticipant) -> PersistedParticipant {
        PersistedParticipant(
            id: participant.id,
            pollId: participant.pollId,
            userId: participant.userId,
            anonymousName: participant.anonymousName,
            anonymousEmail: participant.anonymousEmail,
            accessToken: participant.accessToken,
            comment: participant.comment,
            createdAt: participant.createdAt,
            updatedAt: participant.updatedAt,
            profileDisplayName: participant.profiles?.displayName
        )
    }
}
