package com.meetingscheduler.android.services

import com.meetingscheduler.android.models.*
import kotlinx.datetime.Instant

/** The signed-in account that screen models fence their results to. `PollService` implements it. */
interface PollAccount {
    val creationAccountId: String?
    /** Changes whenever the signed-in account or its session changes. */
    val creationAccountKey: String
}

/** The poll command the creation screen runs. `PollService` implements it. */
interface PollCreationPolls : PollAccount {
    suspend fun createPoll(request: PollCreationRequest): PollCreationResult
}

/** The poll read the responses screen runs. `PollService` implements it. */
interface PollResponsesPolls : PollAccount {
    fun cachedPollDetail(pollId: String): PollDetail? = null
    suspend fun loadPollDetail(pollId: String): PollDetail
    suspend fun refreshPollDetail(pollId: String): PollDetail = loadPollDetail(pollId)
}

/** The list state the poll list shows and the list commands it runs. `PollService` implements it. */
interface PollListPolls : PollAccount {
    val myPolls: List<Poll>
    val createdPolls: List<Poll>
    val joinedPolls: List<Poll>
    val isLoading: Boolean
    val isLoadingMore: Boolean
    val listLoadError: String?
    val listTotalCount: Int?
    val hasMorePolls: Boolean
    val pollParticipantCounts: Map<String, Int>
    val pollTimeRanges: Map<String, Pair<Instant, Instant>>
    fun formatTimeRange(earliest: Instant, latest: Instant): String
    suspend fun loadMyPolls()
    suspend fun loadMorePolls()
    suspend fun retryPollLoad()
    suspend fun loadPollByCode(code: String): PollLookupResponse?
    /** Entering a code is the decision to join: only members can read a poll, so join before opening it. */
    suspend fun joinPoll(pollId: String): PollParticipant
}

/** The poll commands the detail screen runs. `PollService` implements it. */
interface PollDetailPolls : PollResponsesPolls {
    fun availabilitySession(pollId: String): AvailabilitySaveSession
    suspend fun joinPoll(pollId: String): PollParticipant
    suspend fun getAvailability(pollId: String): AvailabilitySnapshot
    suspend fun saveAvailability(pollId: String, request: AvailabilitySaveRequest): AvailabilitySnapshot
    suspend fun updatePollStatus(pollId: String, status: PollStatus)
    suspend fun finalizePoll(pollId: String, timeOptionId: String): Poll
}

/** The calendar checks the detail screen runs. `CalendarService` implements it. */
interface PollDetailCalendar {
    val calendarError: String?
    suspend fun refreshGoogleCalendarConnection()
    suspend fun checkPollConflicts(options: List<PollTimeOption>, pollTimeZone: String): CalendarCheck
}
