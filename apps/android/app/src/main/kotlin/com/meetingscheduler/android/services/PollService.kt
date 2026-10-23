package com.meetingscheduler.android.services

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.models.*
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.text.SimpleDateFormat
import java.util.*

@Serializable
private data class ParticipatedPollsResponse(
    @SerialName("created_polls")
    val createdPolls: List<Poll>,
    @SerialName("joined_polls")
    val joinedPolls: List<Poll>
)

@Serializable
private data class JoinPollResult(val participant: PollParticipant, val created: Boolean)

/** Process-lifetime poll state (F13); callers own the coroutine that runs each request. */
class PollService(
    private val authService: AuthService,
) {
    private val supabase = SupabaseService.client
    private val timeRangeFormatter = SimpleDateFormat("MMM d, h:mm a", Locale.getDefault())

    var myPolls by mutableStateOf<List<Poll>>(emptyList())
        private set
    var createdPolls by mutableStateOf<List<Poll>>(emptyList())
        private set
    var joinedPolls by mutableStateOf<List<Poll>>(emptyList())
        private set
    var isLoading by mutableStateOf(false)
        private set

    private var creationRevision = 0L

    // MARK: - Formatting

    fun formatTimeRange(earliest: Instant, latest: Instant): String {
        val earliestDate = Date.from(java.time.Instant.ofEpochMilli(earliest.toEpochMilliseconds()))
        val latestDate = Date.from(java.time.Instant.ofEpochMilli(latest.toEpochMilliseconds()))
        return "${timeRangeFormatter.format(earliestDate)} - ${timeRangeFormatter.format(latestDate)}"
    }

    // MARK: - Load Polls

    suspend fun loadMyPolls() {
        if (authService.currentUser == null) return

        val accountKey = creationAccountKey
        val revision = creationRevision
        isLoading = true
        try {
            val response = supabase.postgrest
                .rpc("get_user_participated_polls", buildJsonObject { })
                .decodeAs<ParticipatedPollsResponse>()

            if (creationAccountKey != accountKey || creationRevision != revision) return
            createdPolls = response.createdPolls
            joinedPolls = response.joinedPolls
            myPolls = createdPolls + joinedPolls
        } catch (e: Exception) {
            println("Failed to load polls: ${e.message}")
            if (creationAccountKey != accountKey || creationRevision != revision) return
            createdPolls = emptyList()
            joinedPolls = emptyList()
        } finally {
            isLoading = false
        }
    }

    suspend fun loadPoll(id: String): Poll? {
        return try {
            supabase
                .from("polls")
                .select {
                    filter {
                        eq("id", id)
                    }
                }
                .decodeSingle<Poll>()
        } catch (e: Exception) {
            println("Failed to load poll: ${e.message}")
            null
        }
    }

    suspend fun loadPollByCode(code: String): PollLookupResponse? {
        return try {
            val params = buildJsonObject {
                put("code", code.uppercase())
            }
            val response = supabase.postgrest
                .rpc("get_poll_by_code", params)
                .decodeList<PollLookupResponse>()

            response.firstOrNull()
        } catch (e: Exception) {
            println("Failed to load poll by code: ${e.message}")
            null
        }
    }

    // MARK: - Create Poll

    val creationAccountId: String? get() = authService.currentUser?.id
    val creationAccountKey: String get() = "${creationAccountId}:${authService.identityGeneration}"

    suspend fun createPoll(request: PollCreationRequest): PollCreationResult {
        val userId = creationAccountId ?: throw PollError.NotAuthenticated
        val accountKey = creationAccountKey
        val response = try {
            supabase.postgrest.rpc("create_poll", request).decodeAs<PollCreationResult>()
        } catch (error: io.github.jan.supabase.postgrest.exception.PostgrestRestException) {
            if (error.code in setOf("42501", "22023", "P0001", "P0002", "22000", "54000")) {
                throw CreationRejected(requireNotNull(error.code))
            }
            throw error
        }
        check(creationAccountKey == accountKey) { "Your account changed. Reopen your saved draft." }
        check(response.poll.creatorId == userId) { "Creation returned a poll for another account." }
        // Install only the authoritative result, once even after a lost reply/replay.
        creationRevision += 1
        createdPolls = listOf(response.poll) + createdPolls.filterNot { it.id == response.poll.id }
        myPolls = listOf(response.poll) + myPolls.filterNot { it.id == response.poll.id }
        return response
    }

    // MARK: - Time Options

    suspend fun loadTimeOptions(pollId: String): List<PollTimeOption> {
        return try {
            supabase
                .from("poll_time_options")
                .select {
                    filter {
                        eq("poll_id", pollId)
                    }
                    order("start_time", order = io.github.jan.supabase.postgrest.query.Order.ASCENDING)
                }
                .decodeList<PollTimeOption>()
        } catch (e: Exception) {
            println("Failed to load time options: ${e.message}")
            emptyList()
        }
    }

    // MARK: - Poll Status

    suspend fun updatePollStatus(pollId: String, status: PollStatus) {
        val update = buildJsonObject {
            put("status", status.name.lowercase())
        }

        supabase
            .from("polls")
            .update(update) {
                filter {
                    eq("id", pollId)
                }
            }

        // Update local state
        myPolls = myPolls.map { poll ->
            if (poll.id == pollId) poll.copy(status = status) else poll
        }
    }

    suspend fun finalizePoll(pollId: String, timeOptionId: String): Poll {
        val saved = supabase.postgrest.rpc("finalize_poll", buildJsonObject {
            put("poll_uuid", pollId)
            put("time_option_uuid", timeOptionId)
        }).decodeAs<Poll>()
        myPolls = myPolls.map { if (it.id == pollId) saved else it }
        return saved
    }

    // MARK: - Participants

    suspend fun loadParticipants(pollId: String): List<PollParticipant> {
        return try {
            supabase
                .from("poll_participants")
                .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("*, profiles(display_name)")) {
                    filter {
                        eq("poll_id", pollId)
                    }
                }
                .decodeList<PollParticipant>()
        } catch (e: Exception) {
            println("Failed to load participants: ${e.message}")
            emptyList()
        }
    }

    suspend fun joinPoll(pollId: String): PollParticipant {
        val userId = creationAccountId ?: throw PollError.NotAuthenticated
        val accountKey = creationAccountKey
        try {
            val participant = supabase.postgrest.rpc("join_poll", buildJsonObject { put("poll_uuid", pollId) })
                .decodeAs<JoinPollResult>().participant
            if (creationAccountKey != accountKey) throw kotlinx.coroutines.CancellationException("Account changed")
            check(participant.pollId == pollId && participant.userId == userId) { "Join returned a different membership." }
            return participant
        } catch (error: Exception) {
            if (creationAccountKey != accountKey) throw kotlinx.coroutines.CancellationException("Account changed")
            if (error is io.github.jan.supabase.postgrest.exception.PostgrestRestException && error.code == "P0003") {
                throw PollCapacityReached()
            }
            throw error
        }
    }

    // MARK: - Availability Responses

    suspend fun loadResponses(timeOptionIds: List<String>): List<AvailabilityResponse> {
        if (timeOptionIds.isEmpty()) return emptyList()

        return try {
            supabase
                .from("availability_responses")
                .select {
                    filter {
                        isIn("time_option_id", timeOptionIds)
                    }
                }
                .decodeList<AvailabilityResponse>()
        } catch (e: Exception) {
            println("Failed to load responses: ${e.message}")
            emptyList()
        }
    }

    suspend fun getAvailability(pollId: String): AvailabilitySnapshot =
        supabase.postgrest.rpc("get_availability", buildJsonObject {
            put("poll_uuid", pollId)
        }).decodeAs<AvailabilitySnapshot>()

    suspend fun saveAvailability(pollId: String, request: AvailabilitySaveRequest): AvailabilitySnapshot {
        val params = buildJsonObject {
            put("poll_uuid", pollId)
            put("request_id", request.requestId)
            put("expected_version", request.expectedVersion)
            put("comment", request.draft.comment)
            putJsonArray("responses") {
                request.draft.responses.toSortedMap().forEach { (optionId, status) ->
                    add(buildJsonObject {
                        put("time_option_id", optionId)
                        put("status", status.name.lowercase())
                        put("note", null as String?)
                    })
                }
            }
        }
        return try {
            supabase.postgrest.rpc("save_availability", params).decodeAs<AvailabilitySnapshot>()
        } catch (error: io.github.jan.supabase.postgrest.exception.PostgrestRestException) {
            if (error.code == "PT409") throw AvailabilityVersionConflict()
            throw error
        }
    }

    // MARK: - Poll Limits

    sealed class PollError : Exception() {
        object NotAuthenticated : PollError()
    }
}
