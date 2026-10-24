package com.meetingscheduler.android.models

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class SavedAvailabilityResponse(
    val id: String,
    @SerialName("time_option_id") val timeOptionId: String,
    val status: AvailabilityStatus,
    val note: String? = null,
    @SerialName("updated_at") val updatedAt: Instant,
)

@Serializable
data class AvailabilitySnapshot(
    @SerialName("participant_id") val participantId: String,
    @SerialName("poll_id") val pollId: String,
    val version: Long,
    val comment: String? = null,
    val responses: List<SavedAvailabilityResponse>,
) {
    fun responseRows() = responses.map {
        AvailabilityResponse(it.id, participantId, it.timeOptionId, it.status, it.note, it.updatedAt, it.updatedAt)
    }
}

@Serializable
data class AvailabilityDraft(
    val responses: Map<String, AvailabilityStatus>,
    val comment: String?,
)

@Serializable
data class AvailabilitySaveRequest(
    val requestId: String,
    val draft: AvailabilityDraft,
    val expectedVersion: Long,
)

/** Retains one logical save across transport failures. Only server results become saved state. */
@Serializable
data class AvailabilityRecovery(val snapshot: AvailabilitySnapshot?, val pending: AvailabilitySaveRequest?)

class AvailabilitySaveSession(
    initial: AvailabilityRecovery? = null,
    private val persist: (AvailabilityRecovery) -> Unit = {},
    private val newRequestId: () -> String = { UUID.randomUUID().toString() },
) {
    var snapshot: AvailabilitySnapshot? = initial?.snapshot
        private set
    private var pending: AvailabilitySaveRequest? = initial?.pending
    val pendingDraft get() = pending?.draft
    private fun saveRecovery() = persist(AvailabilityRecovery(snapshot, pending))

    fun acceptLoaded(value: AvailabilitySnapshot) {
        snapshot = value
        pending = null
        saveRecovery()
    }

    suspend fun loadIfCurrent(
        load: suspend () -> AvailabilitySnapshot,
        isCurrent: () -> Boolean,
    ): AvailabilitySnapshot? {
        val value = load()
        if (!isCurrent()) return null
        if (pending == null) acceptLoaded(value) // A restored retry retains its original expected version.
        return snapshot
    }

    suspend fun save(
        draft: AvailabilityDraft,
        isCurrent: () -> Boolean = { true },
        send: suspend (AvailabilitySaveRequest) -> AvailabilitySnapshot,
    ): AvailabilitySnapshot {
        val current = checkNotNull(snapshot) { "Load your saved availability before saving." }
        val request = pending?.takeIf { it.draft == draft }
            ?: AvailabilitySaveRequest(newRequestId(), draft.copy(responses = draft.responses.toMap()), current.version)
                .also { pending = it; saveRecovery() }
        val saved = send(request) // A thrown error keeps both the original snapshot and pending request.
        if (!isCurrent()) throw kotlinx.coroutines.CancellationException("Account changed")
        check(saved.participantId == current.participantId && saved.pollId == current.pollId) {
            "The save returned availability for a different participant."
        }
        snapshot = saved
        pending = null
        saveRecovery()
        return saved
    }
}

class AvailabilityVersionConflict : Exception("Your availability changed on another device. Review the latest saved version before retrying.")
