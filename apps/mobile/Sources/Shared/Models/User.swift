import Foundation

public struct Profile: Codable, Identifiable, Sendable {
    public let id: UUID
    public let email: String
    public var displayName: String?
    public var avatarUrl: String?
    public var timezone: String
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case timezone
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarUrl: String? = nil,
        timezone: String = "UTC",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.timezone = timezone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
