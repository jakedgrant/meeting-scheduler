import Foundation
import SwiftData

@Model
public final class PersistedProfile {
    @Attribute(.unique) public var id: UUID
    public var email: String
    public var displayName: String?
    public var avatarUrl: String?
    public var timezone: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSyncedAt: Date

    public init(
        id: UUID,
        email: String,
        displayName: String?,
        avatarUrl: String?,
        timezone: String,
        createdAt: Date,
        updatedAt: Date,
        lastSyncedAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.timezone = timezone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
    }

    public func toModel() -> Profile {
        Profile(
            id: id,
            email: email,
            displayName: displayName,
            avatarUrl: avatarUrl,
            timezone: timezone,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    public func update(from profile: Profile) {
        email = profile.email
        displayName = profile.displayName
        avatarUrl = profile.avatarUrl
        timezone = profile.timezone
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        lastSyncedAt = Date()
    }

    public static func from(_ profile: Profile) -> PersistedProfile {
        PersistedProfile(
            id: profile.id,
            email: profile.email,
            displayName: profile.displayName,
            avatarUrl: profile.avatarUrl,
            timezone: profile.timezone,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt
        )
    }
}
