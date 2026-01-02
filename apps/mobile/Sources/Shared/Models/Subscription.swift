import Foundation

public struct Subscription: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public var revenuecatAppUserId: String?
    public var originalTransactionId: String?
    public var entitlement: String?
    public var isActive: Bool
    public var productId: String?
    public var store: String?
    public var periodType: String?
    public var purchasedAt: Date?
    public var expiresAt: Date?
    public var cancellationAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case revenuecatAppUserId = "revenuecat_app_user_id"
        case originalTransactionId = "original_transaction_id"
        case entitlement
        case isActive = "is_active"
        case productId = "product_id"
        case store
        case periodType = "period_type"
        case purchasedAt = "purchased_at"
        case expiresAt = "expires_at"
        case cancellationAt = "cancellation_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public var hasProAccess: Bool {
        isActive && (entitlement == "pro_access" || entitlement == "team_access")
    }

    public var hasTeamAccess: Bool {
        isActive && entitlement == "team_access"
    }

    public init(
        id: UUID = UUID(),
        userId: UUID,
        revenuecatAppUserId: String? = nil,
        originalTransactionId: String? = nil,
        entitlement: String? = nil,
        isActive: Bool = false,
        productId: String? = nil,
        store: String? = nil,
        periodType: String? = nil,
        purchasedAt: Date? = nil,
        expiresAt: Date? = nil,
        cancellationAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.revenuecatAppUserId = revenuecatAppUserId
        self.originalTransactionId = originalTransactionId
        self.entitlement = entitlement
        self.isActive = isActive
        self.productId = productId
        self.store = store
        self.periodType = periodType
        self.purchasedAt = purchasedAt
        self.expiresAt = expiresAt
        self.cancellationAt = cancellationAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct EventPass: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let transactionId: String
    public let store: String
    public let purchasedAt: Date
    public var redeemedAt: Date?
    public var pollId: UUID?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case transactionId = "transaction_id"
        case store
        case purchasedAt = "purchased_at"
        case redeemedAt = "redeemed_at"
        case pollId = "poll_id"
        case createdAt = "created_at"
    }

    public var isRedeemed: Bool {
        redeemedAt != nil
    }

    public init(
        id: UUID = UUID(),
        userId: UUID,
        transactionId: String,
        store: String,
        purchasedAt: Date,
        redeemedAt: Date? = nil,
        pollId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.transactionId = transactionId
        self.store = store
        self.purchasedAt = purchasedAt
        self.redeemedAt = redeemedAt
        self.pollId = pollId
        self.createdAt = createdAt
    }
}
