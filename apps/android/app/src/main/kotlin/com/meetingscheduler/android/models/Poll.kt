package com.meetingscheduler.android.models

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class PollStatus {
    @SerialName("draft")
    DRAFT,
    @SerialName("active")
    ACTIVE,
    @SerialName("closed")
    CLOSED,
    @SerialName("archived")
    ARCHIVED
}

@Serializable
enum class AvailabilityStatus {
    @SerialName("available")
    AVAILABLE,
    @SerialName("maybe")
    MAYBE,
    @SerialName("unavailable")
    UNAVAILABLE
}

@Serializable
data class PollLookupResponse(
    val id: String,
    val title: String,
    val description: String? = null,
    val location: String? = null,
    val status: PollStatus,
    @SerialName("creator_id")
    val creatorId: String,
    @SerialName("created_at")
    val createdAt: Instant,
    @SerialName("updated_at")
    val updatedAt: Instant,
    @SerialName("share_code")
    val shareCode: String
)

@Serializable
data class Poll(
    val id: String,
    @SerialName("creator_id")
    val creatorId: String,
    val title: String,
    val description: String? = null,
    val location: String? = null,
    val status: PollStatus = PollStatus.DRAFT,
    val timezone: String = "UTC",
    @SerialName("is_premium")
    val isPremium: Boolean = false,
    @SerialName("max_participants")
    val maxParticipants: Int = 10,
    @SerialName("created_at")
    val createdAt: Instant,
    @SerialName("updated_at")
    val updatedAt: Instant,
    @SerialName("closes_at")
    val closesAt: Instant? = null,
    @SerialName("selected_start_time")
    val selectedStartTime: Instant? = null,
    @SerialName("selected_end_time")
    val selectedEndTime: Instant? = null,
    @SerialName("share_code")
    val shareCode: String = ""
)

@Serializable
data class PollTimeOption(
    val id: String,
    @SerialName("poll_id")
    val pollId: String,
    @SerialName("start_time")
    val startTime: Instant,
    @SerialName("end_time")
    val endTime: Instant,
    @SerialName("is_all_day")
    val isAllDay: Boolean = false,
    @SerialName("created_at")
    val createdAt: Instant
)

@Serializable
data class PollParticipant(
    val id: String,
    @SerialName("poll_id")
    val pollId: String,
    @SerialName("user_id")
    val userId: String? = null,
    @SerialName("anonymous_name")
    val anonymousName: String? = null,
    @SerialName("anonymous_email")
    val anonymousEmail: String? = null,
    @SerialName("access_token")
    val accessToken: String,
    val comment: String? = null,
    @SerialName("created_at")
    val createdAt: Instant,
    @SerialName("updated_at")
    val updatedAt: Instant,
    val profiles: ParticipantProfile? = null
) {
    @Serializable
    data class ParticipantProfile(
        @SerialName("display_name")
        val displayName: String?
    )

    val displayName: String
        get() = profiles?.displayName ?: anonymousName ?: "Anonymous"
}

@Serializable
data class AvailabilityResponse(
    val id: String,
    @SerialName("participant_id")
    val participantId: String,
    @SerialName("time_option_id")
    val timeOptionId: String,
    val status: AvailabilityStatus,
    val note: String? = null,
    @SerialName("created_at")
    val createdAt: Instant,
    @SerialName("updated_at")
    val updatedAt: Instant
)
