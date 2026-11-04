package com.meetingscheduler.android.services

import com.meetingscheduler.android.models.*

/** The poll commands the detail screen runs. `PollService` implements it. */
interface PollDetailPolls {
    val creationAccountId: String?
    /** Changes whenever the signed-in account or its session changes. */
    val creationAccountKey: String
    fun availabilitySession(pollId: String): AvailabilitySaveSession
    suspend fun loadPollDetail(pollId: String): PollDetail
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
