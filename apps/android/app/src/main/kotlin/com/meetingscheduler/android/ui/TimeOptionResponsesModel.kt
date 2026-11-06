package com.meetingscheduler.android.ui

import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.models.AvailabilityResponse
import com.meetingscheduler.android.models.AvailabilityStatus
import com.meetingscheduler.android.models.PollParticipant
import com.meetingscheduler.android.models.PollTimeOption
import com.meetingscheduler.android.services.PollResponsesPolls
import kotlinx.coroutines.CancellationException

data class ResponseItem(
    val id: String,
    val participantName: String,
    val status: AvailabilityStatus,
    val note: String?
)

data class GroupedResponses(
    val available: List<ResponseItem>,
    val maybe: List<ResponseItem>,
    val unavailable: List<ResponseItem>
)

/**
 * One account's view of who answered one time option of a poll. It loads the poll once per
 * [load]; a load that a later load replaced, or that finishes after the account changed, is dropped.
 */
class TimeOptionResponsesModel(
    private val pollId: String,
    private val timeOptionId: String,
    private val polls: PollResponsesPolls,
) {
    private val isCurrent = polls.sameAccount()
    private var loadGeneration = 0

    var timeOption by mutableStateOf<PollTimeOption?>(null)
        private set
    var pollTimeZone by mutableStateOf("UTC")
        private set
    var participants by mutableStateOf<List<PollParticipant>>(emptyList())
        private set
    var responses by mutableStateOf<List<AvailabilityResponse>>(emptyList())
        private set
    var isLoading by mutableStateOf(true)
        private set
    var loadError by mutableStateOf<String?>(null)
        private set

    /** The option's responses by answer, each group sorted by participant name. */
    val grouped: GroupedResponses by derivedStateOf {
        val items = responses
            .filter { it.timeOptionId == timeOptionId }
            .mapNotNull { response ->
                participants.firstOrNull { it.id == response.participantId }?.let {
                    ResponseItem(response.id, it.displayName, response.status, response.note)
                }
            }
            .sortedBy { it.participantName }
        GroupedResponses(
            available = items.filter { it.status == AvailabilityStatus.AVAILABLE },
            maybe = items.filter { it.status == AvailabilityStatus.MAYBE },
            unavailable = items.filter { it.status == AvailabilityStatus.UNAVAILABLE },
        )
    }

    suspend fun load() {
        val generation = ++loadGeneration
        fun live() = generation == loadGeneration && isCurrent()
        isLoading = true
        loadError = null
        participants = emptyList(); responses = emptyList(); timeOption = null
        try {
            val detail = polls.loadPollDetail(pollId)
            if (!live()) return
            timeOption = detail.timeOptions.firstOrNull { it.id == timeOptionId }
            pollTimeZone = detail.poll.timezone
            participants = detail.participants
            responses = detail.responses
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (live()) loadError = "Responses could not be loaded completely. Please retry."
        } finally {
            if (live()) isLoading = false
        }
    }
}
