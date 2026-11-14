package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.CalendarSource
import com.meetingscheduler.android.services.PollDetailCalendar
import com.meetingscheduler.android.services.PollDetailPolls
import com.meetingscheduler.android.ui.DeadlineStatus
import com.meetingscheduler.android.ui.PollDetailModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlin.time.Clock
import kotlinx.datetime.Instant
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.*
import org.junit.Test

class PollDetailModelTest {
    private val stamp = Instant.parse("2026-11-04T00:00:00Z")
    private val now = Instant.parse("2026-11-05T12:00:00Z")
    private val clock = object : Clock { override fun now() = this@PollDetailModelTest.now }
    private val poll = Poll("poll", "owner", "Planning", status = PollStatus.ACTIVE, timezone = "America/Chicago",
        createdAt = stamp, updatedAt = stamp)
    private val first = PollTimeOption("first", "poll", Instant.parse("2026-11-10T15:00:00Z"), Instant.parse("2026-11-10T16:00:00Z"), createdAt = stamp)
    private val second = PollTimeOption("second", "poll", Instant.parse("2026-11-11T15:00:00Z"), Instant.parse("2026-11-11T16:00:00Z"), createdAt = stamp)
    private val member = PollParticipant("member", "poll", userId = "account", accessToken = "", createdAt = stamp, updatedAt = stamp)
    private val other = PollParticipant("other", "poll", userId = "someone", accessToken = "", createdAt = stamp, updatedAt = stamp)
    private val detail = PollDetail(poll, listOf(first, second), listOf(member, other), listOf(
        AvailabilityResponse("r1", "other", "second", AvailabilityStatus.AVAILABLE, createdAt = stamp, updatedAt = stamp),
    ))
    private val savedSnapshot = AvailabilitySnapshot("member", "poll", 3, "Saved", listOf(
        SavedAvailabilityResponse("r2", "first", AvailabilityStatus.MAYBE, updatedAt = stamp),
    ))

    private class FakePolls(var detail: suspend () -> PollDetail) : PollDetailPolls {
        override var creationAccountId: String? = "account"
        var generation = 1
        override val creationAccountKey get() = "$creationAccountId:$generation"
        val session = AvailabilitySaveSession { "request" }
        var availability: suspend () -> AvailabilitySnapshot = { error("unexpected availability read") }
        var save: suspend (AvailabilitySaveRequest) -> AvailabilitySnapshot = { error("unexpected save") }
        var join: suspend () -> PollParticipant = { error("unexpected join") }
        var finalize: suspend (String) -> Poll = { error("unexpected finalize") }
        override fun availabilitySession(pollId: String) = session
        var cached: PollDetail? = null
        override fun cachedPollDetail(pollId: String) = cached
        override suspend fun loadPollDetail(pollId: String) = detail()
        override suspend fun joinPoll(pollId: String) = join()
        override suspend fun getAvailability(pollId: String) = availability()
        override suspend fun saveAvailability(pollId: String, request: AvailabilitySaveRequest) = save(request)
        override suspend fun updatePollStatus(pollId: String, status: PollStatus) {}
        override suspend fun finalizePoll(pollId: String, timeOptionId: String) = finalize(timeOptionId)
    }

    private class FakeCalendar(var check: CalendarCheck = CalendarCheck.NONE) : PollDetailCalendar {
        override val calendarError: String? = null
        var checks = 0
        var checker: (suspend () -> CalendarCheck)? = null
        override suspend fun refreshGoogleCalendarConnection() {}
        override suspend fun checkPollConflicts(options: List<PollTimeOption>, pollTimeZone: String): CalendarCheck {
            checks += 1
            return checker?.invoke() ?: check
        }
    }

    @Test fun loadPublishesTheDetailAndSuggestsUnavailableOnlyForUnansweredBusyOptions() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val calendar = FakeCalendar(CalendarCheck(busy = setOf("first", "second"), checkedSources = listOf(CalendarSource.GOOGLE_CALENDAR)))
        val model = PollDetailModel("poll", polls, calendar, clock)
        model.load()
        assertFalse(model.isLoading)
        assertEquals(poll, model.poll)
        assertEquals(member, model.myParticipant?.copy(comment = null))
        assertTrue(model.availabilityLoaded)
        assertEquals("Saved", model.localComment)
        // The saved answer stays; only the unanswered busy option becomes a suggestion.
        assertEquals(mapOf("first" to AvailabilityStatus.MAYBE, "second" to AvailabilityStatus.UNAVAILABLE), model.localResponses)
        assertEquals(listOf("second", "first"), model.rankedTimeOptions.map { it.id })
        assertFalse(model.isCreator)
    }

    @Test fun cachedDetailIsVisibleBeforeRefreshAndSavedAvailabilityFinish() = runBlocking<Unit> {
        val reply = CompletableDeferred<PollDetail>()
        val availability = CompletableDeferred<AvailabilitySnapshot>()
        val availabilityStarted = CompletableDeferred<Unit>()
        val polls = FakePolls({ reply.await() }).apply {
            cached = this@PollDetailModelTest.detail
            this.availability = { availabilityStarted.complete(Unit); availability.await() }
        }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        assertEquals(detail.poll, model.poll)
        assertFalse(model.canRespond)
        val load = async(start = CoroutineStart.UNDISPATCHED) { model.load() }
        assertEquals(detail.poll, model.poll)
        assertFalse(model.canMutatePoll)
        model.close()
        assertEquals(PollStatus.ACTIVE, model.poll?.status)
        reply.complete(detail.copy(poll = poll.copy(title = "Refreshed")))
        availabilityStarted.await()
        assertEquals("Refreshed", model.poll?.title)
        assertTrue(model.isLoading)
        assertFalse(model.canRespond)
        availability.complete(savedSnapshot)
        load.await()
        assertTrue(model.canRespond)
    }

    @Test fun refreshingRetainsUnsavedDraftAndItsOriginalSaveVersion() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        model.setResponse("first", AvailabilityStatus.AVAILABLE)
        model.updateComment("Unsaved comment")
        polls.availability = { error("A dirty draft must keep its original saved version") }
        model.load(forceRefresh = true)
        assertEquals(AvailabilityStatus.AVAILABLE, model.localResponses["first"])
        assertEquals("Unsaved comment", model.localComment)
        assertEquals(3L, polls.session.snapshot?.version)
        assertTrue(model.canRespond)
    }

    @Test fun offlineRefreshThenRetryKeepsUnsavedDraftAndOriginalVersion() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot }; cached = this@PollDetailModelTest.detail }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        model.setResponse("first", AvailabilityStatus.AVAILABLE)
        model.updateComment("Retain through retry")
        polls.detail = { throw java.io.IOException("offline") }
        model.load(forceRefresh = true)
        assertFalse(model.availabilityLoaded)
        polls.detail = { detail }
        polls.availability = { error("Retry must preserve the draft's original version") }
        model.load(forceRefresh = true)
        assertEquals(AvailabilityStatus.AVAILABLE, model.localResponses["first"])
        assertEquals("Retain through retry", model.localComment)
        assertEquals(3L, polls.session.snapshot?.version)
        assertTrue(model.canRespond)
    }

    @Test fun olderAvailabilityReadCannotReplaceANewerVisitsSavedVersion() = runBlocking<Unit> {
        val firstReply = CompletableDeferred<AvailabilitySnapshot>()
        var reads = 0
        val latest = savedSnapshot.copy(version = 9, comment = "Latest saved")
        val polls = FakePolls({ detail }).apply {
            availability = { when (++reads) { 1 -> savedSnapshot; 2 -> firstReply.await(); else -> latest } }
        }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        val earlier = async(start = CoroutineStart.UNDISPATCHED) { model.load(forceRefresh = true) }
        model.load(forceRefresh = true)
        firstReply.complete(savedSnapshot)
        earlier.await()
        assertEquals(9L, polls.session.snapshot?.version)
        assertEquals("Latest saved", model.localComment)
        assertFalse(model.isLoading)
    }

    @Test fun olderCalendarReadCannotReplaceANewerVisitsCheck() = runBlocking<Unit> {
        val firstReply = CompletableDeferred<CalendarCheck>()
        var reads = 0
        val latest = CalendarCheck(busy = setOf("second"), checkedSources = listOf(CalendarSource.GOOGLE_CALENDAR))
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val calendar = FakeCalendar().apply { checker = { if (++reads == 1) firstReply.await() else latest } }
        val model = PollDetailModel("poll", polls, calendar, clock)
        val earlier = async(start = CoroutineStart.UNDISPATCHED) { model.load(forceRefresh = true) }
        model.load(forceRefresh = true)
        firstReply.complete(CalendarCheck(busy = setOf("first")))
        earlier.await()
        assertEquals(latest, model.calendarCheck)
        assertFalse(model.isCheckingCalendar)
    }

    @Test fun offlineRefreshRetainsCachedDetailButDenialDoesNot() = runBlocking<Unit> {
        val polls = FakePolls({ throw java.io.IOException("offline") }).apply { cached = this@PollDetailModelTest.detail }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        assertEquals(detail.poll, model.poll)
        assertNotNull(model.detailError)
        assertFalse(model.canRespond)
        polls.detail = { error("denied") }
        polls.cached = null
        model.load()
        assertNull(model.poll)
    }

    @Test fun aDetailThatArrivesAfterTheAccountChangesIsDropped() = runBlocking<Unit> {
        val reply = CompletableDeferred<PollDetail>()
        val polls = FakePolls({ reply.await() })
        val calendar = FakeCalendar()
        val model = PollDetailModel("poll", polls, calendar, clock)
        val load = async(start = CoroutineStart.UNDISPATCHED) { model.load() }
        polls.generation = 2
        reply.complete(detail)
        load.await()
        assertNull(model.poll)
        assertEquals(0, calendar.checks)
    }

    @Test fun anEarlierLoadCannotReplaceALaterOne() = runBlocking<Unit> {
        val slow = CompletableDeferred<PollDetail>()
        var calls = 0
        val polls = FakePolls({ if (++calls == 1) slow.await() else detail.copy(poll = poll.copy(title = "Latest")) })
        polls.creationAccountId = "nobody"
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        val earlier = async(start = CoroutineStart.UNDISPATCHED) { model.load() }
        model.load()
        slow.complete(detail)
        earlier.await()
        assertEquals("Latest", model.poll?.title)
        assertFalse(model.isLoading)
    }

    @Test fun aFailedLoadOffersARetry() = runBlocking<Unit> {
        val model = PollDetailModel("poll", FakePolls({ throw IllegalStateException("incomplete") }), FakeCalendar(), clock)
        model.load()
        assertNull(model.poll)
        assertFalse(model.isLoading)
        assertEquals("This poll could not be loaded completely. Please retry.", model.detailError)
    }

    @Test fun saveSendsTheDraftAndPublishesTheServerResult() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        model.setResponse("second", AvailabilityStatus.AVAILABLE)
        model.updateComment("  Works for me  ")
        val result = savedSnapshot.copy(version = 4, comment = "Works for me", responses = listOf(
            SavedAvailabilityResponse("r3", "second", AvailabilityStatus.AVAILABLE, updatedAt = stamp)))
        var sent: AvailabilitySaveRequest? = null
        polls.save = { sent = it; result }
        model.save()
        assertEquals(3L, sent?.expectedVersion)
        assertEquals("Works for me", sent?.draft?.comment)
        assertEquals(mapOf("first" to AvailabilityStatus.MAYBE, "second" to AvailabilityStatus.AVAILABLE), sent?.draft?.responses)
        assertEquals(mapOf("second" to AvailabilityStatus.AVAILABLE), model.localResponses)
        assertEquals(2, model.responseSummary("second").available)
        assertEquals(0, model.responseSummary("first").maybe)
        assertEquals("Works for me", model.participants.first { it.id == "member" }.comment)
        assertNull(model.saveError)
        assertFalse(model.isSaving)
    }

    @Test fun aVersionConflictWaitsForTheParticipantToChoose() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        model.setResponse("second", AvailabilityStatus.AVAILABLE)
        polls.save = { throw AvailabilityVersionConflict() }
        model.save()
        assertTrue(model.hasVersionConflict)
        assertFalse(model.canSave)
        val latest = savedSnapshot.copy(version = 5, comment = "From another device")
        polls.availability = { latest }
        model.reviewLatestVersion()
        assertEquals(latest, model.conflictSnapshot)
        model.keepDraft()
        assertNull(model.conflictSnapshot)
        assertFalse(model.hasVersionConflict)
        assertEquals(AvailabilityStatus.AVAILABLE, model.localResponses["second"])
        // The next save replaces the latest version, not the one the draft started from.
        var sent: AvailabilitySaveRequest? = null
        polls.save = { sent = it; latest.copy(version = 6) }
        model.save()
        assertEquals(5L, sent?.expectedVersion)
    }

    @Test fun usingTheSavedVersionReplacesTheDraft() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        model.setResponse("second", AvailabilityStatus.AVAILABLE)
        polls.save = { throw AvailabilityVersionConflict() }
        model.save()
        val latest = savedSnapshot.copy(version = 5, comment = "From another device")
        polls.availability = { latest }
        model.reviewLatestVersion()
        model.useSavedVersion()
        assertEquals(mapOf("first" to AvailabilityStatus.MAYBE), model.localResponses)
        assertEquals("From another device", model.localComment)
        assertNull(model.saveError)
    }

    @Test fun aSaveThatFailsKeepsTheDraftForRetry() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        model.setResponse("second", AvailabilityStatus.AVAILABLE)
        polls.save = { throw IllegalStateException("reply lost") }
        model.save()
        assertEquals(AvailabilityStatus.AVAILABLE, model.localResponses["second"])
        assertTrue(model.saveError!!.contains("not confirmed saved"))
        assertFalse(model.hasVersionConflict)
    }

    @Test fun aCommentOverTheLimitIsRefusedAndBlocksSaving() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        model.updateComment("x".repeat(PollDetailModel.MAX_COMMENT_LENGTH + 1))
        assertEquals("Saved", model.localComment)
        assertTrue(model.commentError.isNotEmpty())
        assertFalse(model.canSave)
        model.updateComment("Fine")
        assertTrue(model.canSave)
    }

    @Test fun joiningAddsTheMembershipAndLoadsItsAvailability() = runBlocking<Unit> {
        val polls = FakePolls({ detail.copy(participants = listOf(other)) })
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        assertNull(model.myParticipant)
        polls.join = { member }
        polls.availability = { savedSnapshot.copy(comment = null, responses = emptyList()) }
        model.join()
        assertEquals("member", model.myParticipant?.id)
        assertEquals(2, model.participants.size)
        assertTrue(model.availabilityLoaded)
        assertFalse(model.isJoining)
    }

    @Test fun aFullPollSaysSo() = runBlocking<Unit> {
        val polls = FakePolls({ detail.copy(participants = listOf(other)) })
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        polls.join = { throw PollCapacityReached() }
        model.join()
        assertEquals(PollCapacityReached().message, model.joinError)
        assertNull(model.myParticipant)
    }

    @Test fun aFinalizationAfterTheAccountChangesIsDropped() = runBlocking<Unit> {
        val owned = detail.copy(poll = poll.copy(creatorId = "account", status = PollStatus.CLOSED))
        val polls = FakePolls({ owned }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar(), clock)
        model.load()
        assertTrue(model.isCreator)
        polls.finalize = { polls.generation = 2; owned.poll.copy(selectedStartTime = first.startTime, selectedEndTime = first.endTime) }
        model.finalize(first)
        assertNull(model.poll?.selectedStartTime)
        assertFalse(model.isSelectingFinalDate)
    }

    @Test fun theFinalEventOfAnAllDayOptionCoversItsDateInThePollZone() = runBlocking<Unit> {
        // Midnight to midnight in Chicago is 06:00Z to 06:00Z; the provider wants the UTC midnights of that date.
        val allDay = PollTimeOption("day", "poll", Instant.parse("2026-11-10T06:00:00Z"), Instant.parse("2026-11-11T06:00:00Z"),
            isAllDay = true, createdAt = stamp)
        val finalized = poll.copy(status = PollStatus.CLOSED, location = "Office",
            selectedStartTime = allDay.startTime, selectedEndTime = allDay.endTime)
        val model = PollDetailModel("poll", FakePolls({ detail.copy(poll = finalized, timeOptions = listOf(allDay, first)) }), FakeCalendar(), clock)
        assertNull(model.finalEvent)
        model.load()
        val event = model.finalEvent!!
        assertTrue(event.isAllDay)
        assertEquals("Office", event.location)
        assertEquals(Instant.parse("2026-11-10T00:00:00Z") to Instant.parse("2026-11-11T00:00:00Z"), event.insertBounds)
    }

    @Test fun theFinalEventOfATimedOptionKeepsItsInterval() = runBlocking<Unit> {
        val finalized = poll.copy(status = PollStatus.CLOSED, selectedStartTime = first.startTime, selectedEndTime = first.endTime)
        val model = PollDetailModel("poll", FakePolls({ detail.copy(poll = finalized) }), FakeCalendar(), clock)
        model.load()
        val event = model.finalEvent!!
        assertFalse(event.isAllDay)
        assertEquals(first.startTime to first.endTime, event.insertBounds)
    }

    @Test fun theDeadlineIsClosingSoonWithinADayAndPastDueFromItsInstant() {
        val model = PollDetailModel("poll", FakePolls({ detail }), FakeCalendar(), clock)
        assertEquals(DeadlineStatus.OPEN, model.deadlineStatus(now + 24.hours))
        assertEquals(DeadlineStatus.CLOSING_SOON, model.deadlineStatus(now + 24.hours - 1.seconds))
        assertEquals(DeadlineStatus.CLOSING_SOON, model.deadlineStatus(now + 1.seconds))
        assertEquals(DeadlineStatus.PAST_DUE, model.deadlineStatus(now))
        assertEquals(DeadlineStatus.PAST_DUE, model.deadlineStatus(now - 1.seconds))
    }
}
