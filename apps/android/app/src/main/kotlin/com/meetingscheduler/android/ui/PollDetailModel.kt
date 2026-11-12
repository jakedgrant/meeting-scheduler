package com.meetingscheduler.android.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.FailureLog
import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.PollDetailCalendar
import com.meetingscheduler.android.services.PollDetailPolls
import kotlinx.coroutines.CancellationException
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.plus
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours

/** How near the poll's response deadline is. */
enum class DeadlineStatus { OPEN, CLOSING_SOON, PAST_DUE }

data class ResponseSummary(
    val available: Int,
    val maybe: Int,
    val unavailable: Int
)

/** The finalized meeting: the poll's chosen interval and what the device calendar needs to add it. */
data class FinalCalendarEvent(
    val title: String,
    val start: Instant,
    val end: Instant,
    val isAllDay: Boolean,
    val pollTimeZone: String,
    val description: String?,
    val location: String?,
) {
    /**
     * The bounds the Calendar Provider's insert screen takes. An all-day event runs from the UTC
     * midnight of its date in the poll's zone to the next one, as the provider stores all-day events.
     */
    val insertBounds: Pair<Instant, Instant>
        get() {
            if (!isAllDay) return start to end
            val date = PollDates.allDayDate(start, pollTimeZone)
            return date.atStartOfDayIn(TimeZone.UTC) to date.plus(1, DateTimeUnit.DAY).atStartOfDayIn(TimeZone.UTC)
        }
}

/**
 * One account's visit to a poll's detail screen: it loads the poll, edits that account's
 * availability, checks the enabled calendars and runs the join, save, close and finalize commands.
 *
 * The model belongs to the account that was signed in when it was made. A result that arrives
 * after the account changes is dropped, and so is a load that a later load replaced.
 */
class PollDetailModel(
    val pollId: String,
    private val polls: PollDetailPolls,
    private val calendar: PollDetailCalendar,
    private val clock: Clock,
) {
    companion object {
        const val MAX_COMMENT_LENGTH = 500
        private val CLOSING_SOON = 24.hours
    }

    private val accountKey = polls.creationAccountKey
    private val accountId = polls.creationAccountId
    /** Throws when the saved retry for this poll can't be read, so the screen can say so. */
    private val saveSession = polls.availabilitySession(pollId)
    private var loadGeneration = 0
    private var hasAvailabilityDraft = false

    var poll by mutableStateOf<Poll?>(null)
        private set
    var timeOptions by mutableStateOf<List<PollTimeOption>>(emptyList())
        private set
    var participants by mutableStateOf<List<PollParticipant>>(emptyList())
        private set
    var responses by mutableStateOf<List<AvailabilityResponse>>(emptyList())
        private set
    var myParticipant by mutableStateOf<PollParticipant?>(null)
        private set
    var localResponses by mutableStateOf<Map<String, AvailabilityStatus>>(emptyMap())
        private set
    var localComment by mutableStateOf("")
        private set
    var commentError by mutableStateOf("")
        private set
    var isLoading by mutableStateOf(true)
        private set
    var detailError by mutableStateOf<String?>(null)
        private set
    var availabilityLoaded by mutableStateOf(false)
        private set
    var isSaving by mutableStateOf(false)
        private set
    var saveError by mutableStateOf<String?>(null)
        private set
    var hasVersionConflict by mutableStateOf(false)
        private set
    /** The latest saved version, while the participant decides between it and their draft. */
    var conflictSnapshot by mutableStateOf<AvailabilitySnapshot?>(null)
        private set
    var isJoining by mutableStateOf(false)
        private set
    var joinError by mutableStateOf<String?>(null)
        private set
    private var isClosingPoll by mutableStateOf(false)
    val isMutatingPoll: Boolean get() = isSaving || isJoining || isSelectingFinalDate || isClosingPoll
    val canMutatePoll: Boolean get() = !isLoading && !isMutatingPoll && isCurrentAccount()

    var isSelectingFinalDate by mutableStateOf(false)
        private set
    var calendarCheck by mutableStateOf(CalendarCheck.NONE)
        private set
    var isCheckingCalendar by mutableStateOf(false)
        private set

    val calendarError: String? get() = calendar.calendarError
    val isCreator: Boolean get() = poll?.creatorId == accountId
    val canRespond: Boolean
        get() = myParticipant != null && poll?.status == PollStatus.ACTIVE && availabilityLoaded && !isLoading && !isMutatingPoll
    val canSave: Boolean
        get() = !isLoading && !isMutatingPoll && availabilityLoaded && !hasVersionConflict && commentError.isEmpty()

    /** Time options with the most available, then most maybe, responses first. */
    val rankedTimeOptions: List<PollTimeOption>
        get() = timeOptions.sortedWith { a, b ->
            val statsA = responseSummary(a.id)
            val statsB = responseSummary(b.id)
            when {
                statsB.available != statsA.available -> statsB.available.compareTo(statsA.available)
                else -> statsB.maybe.compareTo(statsA.maybe)
            }
        }

    /** The meeting to add to the device calendar, once the poll has a final time. */
    val finalEvent: FinalCalendarEvent?
        get() {
            val current = poll ?: return null
            val start = current.selectedStartTime ?: return null
            val end = current.selectedEndTime ?: return null
            // Finalization copies the chosen option's interval onto the poll.
            val isAllDay = timeOptions.any { it.isAllDay && it.startTime == start && it.endTime == end }
            return FinalCalendarEvent(current.title, start, end, isAllDay, current.timezone, current.description, current.location)
        }

    /**
     * Past due from the deadline instant on, as on iOS and in the database, which refuses saves
     * then. Closing soon within the 24 hours before it.
     */
    fun deadlineStatus(closesAt: Instant): DeadlineStatus {
        val now = clock.now()
        return when {
            closesAt <= now -> DeadlineStatus.PAST_DUE
            closesAt - now < CLOSING_SOON -> DeadlineStatus.CLOSING_SOON
            else -> DeadlineStatus.OPEN
        }
    }

    fun isCurrentUser(participant: PollParticipant) = participant.userId == accountId

    fun responseSummary(optionId: String): ResponseSummary {
        val optionResponses = responses.filter { it.timeOptionId == optionId }
        return ResponseSummary(
            available = optionResponses.count { it.status == AvailabilityStatus.AVAILABLE },
            maybe = optionResponses.count { it.status == AvailabilityStatus.MAYBE },
            unavailable = optionResponses.count { it.status == AvailabilityStatus.UNAVAILABLE }
        )
    }

    private fun isCurrentAccount() = polls.creationAccountKey == accountKey

    init { polls.cachedPollDetail(pollId)?.let(::applyDetail) }

    private fun applyDetail(detail: PollDetail) {
        poll = detail.poll
        timeOptions = detail.timeOptions
        participants = detail.participants
        responses = detail.responses
        myParticipant = participants.firstOrNull { it.userId == accountId }
    }

    /** Shows persisted detail before refreshing stale data, saved availability and calendars. */
    suspend fun load(forceRefresh: Boolean = false) {
        if (isMutatingPoll) return
        val generation = ++loadGeneration
        fun isCurrent() = generation == loadGeneration && isCurrentAccount()
        val saved = saveSession.snapshot
        val preserveDraft = hasAvailabilityDraft && saved != null &&
            (saveSession.pendingDraft != null || localResponses != saved.responses.associate { it.timeOptionId to it.status } ||
                localComment.trim().ifEmpty { null } != saved.comment)
        isLoading = true
        calendarCheck = CalendarCheck.NONE
        isCheckingCalendar = false
        try {
            availabilityLoaded = false
            if (!hasAvailabilityDraft) {
                localResponses = emptyMap()
                localComment = ""
            }
            myParticipant = null
            poll = null; timeOptions = emptyList(); participants = emptyList(); responses = emptyList()
            detailError = null
            polls.cachedPollDetail(pollId)?.let(::applyDetail)
            val detail = try {
                if (forceRefresh) polls.refreshPollDetail(pollId) else polls.loadPollDetail(pollId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (isCurrent()) {
                    // A denial evicts the cache in the service; never keep displaying revoked detail.
                    val cached = polls.cachedPollDetail(pollId)
                    if (error is java.io.IOException && cached != null) {
                        applyDetail(cached)
                        detailError = "This poll could not be refreshed. Displayed results may be out of date."
                    } else {
                        poll = null; timeOptions = emptyList(); participants = emptyList(); responses = emptyList()
                        myParticipant = null
                        detailError = "This poll could not be loaded completely. Please retry."
                    }
                }
                return
            }
            if (!isCurrent()) return
            applyDetail(detail)

            if (preserveDraft && saved?.participantId == myParticipant?.id) {
                // Keep the original save version so a remote edit still produces a conflict.
                availabilityLoaded = true
            } else if (myParticipant != null) loadSavedAvailability()
            if (!isCurrent()) return
            // Refresh safe connection metadata, then check all slots in one call.
            calendar.refreshGoogleCalendarConnection()
            if (!isCurrent()) return
            checkCalendar()
        } finally {
            if (isCurrent()) isLoading = false
        }
    }

    /** Only busy options become unavailable suggestions; unchecked options are left alone (F16). */
    suspend fun checkCalendar() {
        val generation = loadGeneration
        val currentPoll = poll ?: return
        // The service returns an empty result when no source is enabled, which clears a stale banner on retry.
        if (timeOptions.isEmpty() || isCheckingCalendar) return
        isCheckingCalendar = true
        try {
            val check = calendar.checkPollConflicts(timeOptions, currentPoll.timezone)
            if (generation != loadGeneration || !isCurrentAccount()) return
            calendarCheck = check
            check.busy.forEach { conflictId ->
                if (saveSession.pendingDraft == null && !localResponses.containsKey(conflictId)) {
                    localResponses = localResponses + (conflictId to AvailabilityStatus.UNAVAILABLE)
                }
            }
        } finally {
            if (generation == loadGeneration) isCheckingCalendar = false
        }
    }

    suspend fun loadSavedAvailability() {
        val generation = loadGeneration
        fun isCurrent() = generation == loadGeneration && isCurrentAccount()
        try {
            val saved = saveSession.loadIfCurrent(
                load = { polls.getAvailability(pollId) },
                isCurrent = ::isCurrent,
            ) ?: return
            applySavedAvailability(saved)
            availabilityLoaded = true
            saveError = null
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (isCurrent()) saveError = "Could not load your saved availability. Retry before editing."
        }
    }

    suspend fun join() {
        if (!canMutatePoll) return
        isJoining = true
        joinError = null
        try {
            val participant = polls.joinPoll(pollId)
            if (!isCurrentAccount()) return
            myParticipant = participant
            participants = participants.filterNot { it.id == participant.id } + participant
            loadSavedAvailability()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (isCurrentAccount()) {
                joinError = if (error is PollCapacityReached) error.message
                    else "Joining could not be confirmed. Tap Join This Poll to retry safely."
            }
        } finally {
            isJoining = false
        }
    }

    fun setResponse(optionId: String, status: AvailabilityStatus) {
        if (!isSaving && availabilityLoaded) localResponses = localResponses + (optionId to status)
    }

    fun updateComment(value: String) {
        if (value.length <= MAX_COMMENT_LENGTH) {
            localComment = value
            commentError = ""
        } else {
            commentError = "Comment must be $MAX_COMMENT_LENGTH characters or less"
        }
    }

    suspend fun save() {
        if (isSaving) return
        if (localComment.length > MAX_COMMENT_LENGTH) {
            commentError = "Comment must be $MAX_COMMENT_LENGTH characters or less"
            return
        }
        isSaving = true
        try {
            val draft = AvailabilityDraft(localResponses, localComment.trim().ifEmpty { null })
            val saved = saveSession.save(draft, send = { request ->
                polls.saveAvailability(pollId, request)
            }, isCurrent = ::isCurrentAccount)
            applySavedAvailability(saved)
            saveError = null
            hasVersionConflict = false
        } catch (error: CancellationException) {
            throw error
        } catch (error: AvailabilityVersionConflict) {
            if (isCurrentAccount()) {
                saveError = error.message
                hasVersionConflict = true
            }
        } catch (error: Exception) {
            if (isCurrentAccount()) {
                saveError = "Availability was not confirmed saved. Your draft is unchanged. Tap Save Responses to retry."
            }
        } finally {
            isSaving = false
        }
    }

    /** Loads the latest saved version for the participant to compare with their draft. */
    suspend fun reviewLatestVersion() {
        try {
            val latest = polls.getAvailability(pollId)
            if (isCurrentAccount()) conflictSnapshot = latest
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (isCurrentAccount()) saveError = "Could not load the latest version. Your draft is unchanged. Try again."
        }
    }

    /** Keeps the draft; the next save replaces the latest version with it. */
    fun keepDraft() {
        val latest = conflictSnapshot ?: return
        saveSession.acceptLoaded(latest)
        conflictSnapshot = null
        hasVersionConflict = false
        saveError = "Your draft is unchanged. Tap Save Responses to replace the latest version with your draft."
    }

    /** Discards the draft and shows the latest saved version. */
    fun useSavedVersion() {
        val latest = conflictSnapshot ?: return
        saveSession.acceptLoaded(latest)
        applySavedAvailability(latest)
        conflictSnapshot = null
        hasVersionConflict = false
        saveError = null
    }

    fun dismissConflict() {
        conflictSnapshot = null
    }

    suspend fun close() {
        if (!canMutatePoll) return
        isClosingPoll = true
        try {
            polls.updatePollStatus(pollId, PollStatus.CLOSED)
            if (isCurrentAccount()) poll = poll?.copy(status = PollStatus.CLOSED)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            FailureLog.record("PollDetailModel", "Failed to update status", error)
        } finally { isClosingPoll = false }
    }

    suspend fun finalize(option: PollTimeOption) {
        if (!canMutatePoll) return
        isSelectingFinalDate = true
        try {
            val finalized = polls.finalizePoll(pollId, option.id)
            if (isCurrentAccount()) poll = finalized
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (isCurrentAccount()) saveError = "The final date could not be saved. Try again."
        } finally {
            isSelectingFinalDate = false
        }
    }

    private fun applySavedAvailability(saved: AvailabilitySnapshot) {
        hasAvailabilityDraft = true
        responses = responses.filter { it.participantId != saved.participantId } + saved.responseRows()
        participants = participants.map { if (it.id == saved.participantId) it.copy(comment = saved.comment) else it }
        myParticipant = participants.firstOrNull { it.id == saved.participantId }
        localResponses = saveSession.pendingDraft?.responses ?: saved.responses.associate { it.timeOptionId to it.status }
        localComment = saveSession.pendingDraft?.comment ?: saved.comment.orEmpty()
    }
}
