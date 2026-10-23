package com.meetingscheduler.android.models

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class CreationTimeOption(
    @SerialName("start_time") val startTime: Instant,
    @SerialName("end_time") val endTime: Instant,
    @SerialName("is_all_day") val isAllDay: Boolean = false,
)

@Serializable
data class PollCreationPayload(
    val title: String,
    val description: String? = null,
    val location: String? = null,
    val timezone: String,
    @SerialName("closes_at") val closesAt: Instant? = null,
    @SerialName("time_options") val timeOptions: List<CreationTimeOption>,
    @SerialName("use_event_pass") val useEventPass: Boolean = false,
)

@Serializable
data class PollCreationRequest(
    @SerialName("operation_id") val operationId: String,
    val payload: PollCreationPayload,
)

@Serializable
data class PollCreationResult(
    val poll: Poll,
    @SerialName("time_options") val timeOptions: List<PollTimeOption>,
    @SerialName("redeemed_pass_id") val redeemedPassId: String? = null,
    val entitlement: String,
    val replayed: Boolean = false,
)

class CreationRejected(val code: String) : Exception(when (code) {
    "42501" -> "Sign in again before creating this poll. Your draft is saved."
    "22023" -> "Check the title, timezone, deadline and time options, then try again."
    "P0001" -> "Your active poll limit is reached. Close an active poll, use an event pass, or upgrade."
    "P0002" -> "No verified event pass is available. Refresh purchases or create without a pass."
    "22000" -> "This retry has changed. Reopen your saved draft before trying again."
    "54000" -> "A share code could not be allocated. Please try again."
    else -> "Creation was rejected. Your draft is saved."
})

class PollCapacityReached : Exception("This poll is full. Ask the organizer for help, then retry joining.")

class CreationStorageFailure : Exception("Could not save your retry. Free device storage and try again.")

/** Save the exact envelope before sending. An uncertain outcome must be resolved before editing. */
class PollCreationSession(
    initial: PollCreationRequest? = null,
    private val persist: (PollCreationRequest?) -> Unit = {},
    private val newId: () -> String = { UUID.randomUUID().toString() },
) {
    var pending: PollCreationRequest? = initial
        private set
    var saved: PollCreationResult? = null
        private set

    suspend fun submit(
        payload: PollCreationPayload,
        send: suspend (PollCreationRequest) -> PollCreationResult,
        isCurrent: () -> Boolean,
    ): PollCreationResult? {
        check(isCurrent()) { "Your account changed. Reopen creation for the current account." }
        saved?.let { return it }
        val request = pending ?: PollCreationRequest(newId(), payload.copy(timeOptions = payload.timeOptions.toList())).also {
            persist(it) // A disk failure prevents a request with unrecoverable retry identity.
            pending = it
        }
        val result = try { send(request) } catch (error: CreationRejected) {
            // A definitive SQL rejection rolled back this operation. Transport errors retain it.
            if (isCurrent() && error.code != "22000") { persist(null); pending = null }
            throw error
        }
        if (!isCurrent()) return null
        check(result.poll.creatorId.isNotEmpty() && result.timeOptions.all { it.pollId == result.poll.id }) {
            "Creation returned an invalid result. Retry the saved operation."
        }
        saved = result
        persist(null)
        pending = null
        return result
    }
}
