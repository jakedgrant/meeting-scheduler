package com.meetingscheduler.android.models

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class Subscription(
    val id: String,
    @SerialName("user_id")
    val userId: String,
    @SerialName("revenuecat_app_user_id")
    val revenuecatAppUserId: String? = null,
    @SerialName("original_transaction_id")
    val originalTransactionId: String? = null,
    val entitlement: String? = null,
    @SerialName("is_active")
    val isActive: Boolean = false,
    @SerialName("product_id")
    val productId: String? = null,
    val store: String? = null,
    @SerialName("period_type")
    val periodType: String? = null,
    @SerialName("purchased_at")
    val purchasedAt: Instant? = null,
    @SerialName("expires_at")
    val expiresAt: Instant? = null,
    @SerialName("cancellation_at")
    val cancellationAt: Instant? = null,
    @SerialName("created_at")
    val createdAt: Instant,
    @SerialName("updated_at")
    val updatedAt: Instant
) {
    val hasProAccess: Boolean
        get() = isActive && (entitlement == "pro_access" || entitlement == "team_access")

    val hasTeamAccess: Boolean
        get() = isActive && entitlement == "team_access"
}

@Serializable
data class EventPass(
    val id: String,
    @SerialName("user_id")
    val userId: String,
    @SerialName("transaction_id")
    val transactionId: String,
    val store: String,
    @SerialName("purchased_at")
    val purchasedAt: Instant,
    @SerialName("redeemed_at")
    val redeemedAt: Instant? = null,
    @SerialName("poll_id")
    val pollId: String? = null,
    @SerialName("created_at")
    val createdAt: Instant
) {
    val isRedeemed: Boolean
        get() = redeemedAt != null
}
