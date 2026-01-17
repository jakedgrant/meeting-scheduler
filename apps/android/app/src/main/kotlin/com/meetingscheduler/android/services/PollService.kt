package com.meetingscheduler.android.services

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.models.*
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

@Serializable
private data class ParticipatedPollsResponse(
    @SerialName("created_polls")
    val createdPolls: List<Poll>,
    @SerialName("joined_polls")
    val joinedPolls: List<Poll>
)

class PollService(
    private val authService: AuthService,
    private val scope: CoroutineScope
) {
    private val supabase = SupabaseService.client

    var myPolls by mutableStateOf<List<Poll>>(emptyList())
        private set
    var createdPolls by mutableStateOf<List<Poll>>(emptyList())
        private set
    var joinedPolls by mutableStateOf<List<Poll>>(emptyList())
        private set
    var isLoading by mutableStateOf(false)
        private set

    // MARK: - Load Polls

    suspend fun loadMyPolls() {
        if (authService.currentUser == null) return

        isLoading = true
        try {
            val response = supabase.postgrest
                .rpc("get_user_participated_polls", buildJsonObject { })
                .decodeAs<ParticipatedPollsResponse>()

            createdPolls = response.createdPolls
            joinedPolls = response.joinedPolls
            myPolls = createdPolls + joinedPolls
        } catch (e: Exception) {
            println("Failed to load polls: ${e.message}")
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

    suspend fun createPoll(
        title: String,
        description: String?,
        location: String?,
        timezone: String = "UTC"
    ): Poll {
        val userId = authService.currentUser?.id ?: throw PollError.NotAuthenticated

        val newPoll = buildJsonObject {
            put("creator_id", userId)
            put("title", title)
            description?.let { put("description", it) }
            location?.let { put("location", it) }
            put("timezone", timezone)
            put("status", "active")
        }

        val response = supabase
            .from("polls")
            .insert(newPoll) {
                select()
            }
            .decodeSingle<Poll>()

        myPolls = listOf(response) + myPolls
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

    suspend fun addTimeOptions(
        pollId: String,
        options: List<TimeOptionInput>
    ): List<PollTimeOption> {
        val insertData = options.map { option ->
            buildJsonObject {
                put("poll_id", pollId)
                put("start_time", option.start.toString())
                put("end_time", option.end.toString())
                put("is_all_day", option.isAllDay)
            }
        }

        return supabase
            .from("poll_time_options")
            .insert(insertData) {
                select()
            }
            .decodeList<PollTimeOption>()
    }

    data class TimeOptionInput(
        val start: Instant,
        val end: Instant,
        val isAllDay: Boolean
    )

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

    suspend fun setSelectedFinalDate(pollId: String, startTime: Instant, endTime: Instant) {
        val update = buildJsonObject {
            put("selected_start_time", startTime.toString())
            put("selected_end_time", endTime.toString())
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
            if (poll.id == pollId) {
                poll.copy(selectedStartTime = startTime, selectedEndTime = endTime)
            } else {
                poll
            }
        }
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
        val userId = authService.currentUser?.id

        val newParticipant = buildJsonObject {
            put("poll_id", pollId)
            userId?.let { put("user_id", it) }
        }

        return supabase
            .from("poll_participants")
            .insert(newParticipant) {
                select()
            }
            .decodeSingle<PollParticipant>()
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

    suspend fun saveResponses(
        participantId: String,
        responses: List<ResponseInput>
    ) {
        val insertData = responses.map { response ->
            buildJsonObject {
                put("participant_id", participantId)
                put("time_option_id", response.timeOptionId)
                put("status", response.status.name.lowercase())
                response.note?.let { put("note", it) }
            }
        }

        supabase
            .from("availability_responses")
            .upsert(insertData) {
                onConflict = "participant_id,time_option_id"
            }
    }

    suspend fun updateParticipantComment(participantId: String, comment: String?) {
        val update = buildJsonObject {
            if (comment != null) {
                put("comment", comment)
            } else {
                put("comment", null as String?)
            }
        }

        supabase
            .from("poll_participants")
            .update(update) {
                filter {
                    eq("id", participantId)
                }
            }
    }

    data class ResponseInput(
        val timeOptionId: String,
        val status: AvailabilityStatus,
        val note: String?
    )

    // MARK: - Poll Limits

    fun canCreatePoll(): Boolean {
        // Count active polls created by the user
        val activeCreatedPolls = createdPolls.count { it.status == PollStatus.ACTIVE }

        // Free tier: 3 active polls, Pro tier: unlimited
        val hasProAccess = false // authService.profile?.hasProAccess == true ||
                          // authService.profile?.hasTeamAccess == true

        return hasProAccess || activeCreatedPolls < 3
    }

    sealed class PollError : Exception() {
        object NotAuthenticated : PollError()
    }

    companion object {
        private var instance: PollService? = null

        fun getInstance(authService: AuthService, scope: CoroutineScope): PollService {
            return instance ?: synchronized(this) {
                instance ?: PollService(authService, scope).also { instance = it }
            }
        }
    }
}
