package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.CalendarSource
import com.meetingscheduler.android.services.PollDetailCalendar
import com.meetingscheduler.android.services.PollDetailPolls
import com.meetingscheduler.android.ui.PollDetailModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

class PollDetailModelTest {
    private val stamp = Instant.parse("2026-11-04T00:00:00Z")
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
        override suspend fun refreshGoogleCalendarConnection() {}
        override suspend fun checkPollConflicts(options: List<PollTimeOption>, pollTimeZone: String): CalendarCheck {
            checks += 1
            return check
        }
    }

    @Test fun loadPublishesTheDetailAndSuggestsUnavailableOnlyForUnansweredBusyOptions() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val calendar = FakeCalendar(CalendarCheck(busy = setOf("first", "second"), checkedSources = listOf(CalendarSource.GOOGLE_CALENDAR)))
        val model = PollDetailModel("poll", polls, calendar)
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

    @Test fun aDetailThatArrivesAfterTheAccountChangesIsDropped() = runBlocking<Unit> {
        val reply = CompletableDeferred<PollDetail>()
        val polls = FakePolls({ reply.await() })
        val calendar = FakeCalendar()
        val model = PollDetailModel("poll", polls, calendar)
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
        val model = PollDetailModel("poll", polls, FakeCalendar())
        val earlier = async(start = CoroutineStart.UNDISPATCHED) { model.load() }
        model.load()
        slow.complete(detail)
        earlier.await()
        assertEquals("Latest", model.poll?.title)
        assertFalse(model.isLoading)
    }

    @Test fun aFailedLoadOffersARetry() = runBlocking<Unit> {
        val model = PollDetailModel("poll", FakePolls({ throw IllegalStateException("incomplete") }), FakeCalendar())
        model.load()
        assertNull(model.poll)
        assertFalse(model.isLoading)
        assertEquals("This poll could not be loaded completely. Please retry.", model.detailError)
    }

    @Test fun saveSendsTheDraftAndPublishesTheServerResult() = runBlocking<Unit> {
        val polls = FakePolls({ detail }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar())
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
        val model = PollDetailModel("poll", polls, FakeCalendar())
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
        val model = PollDetailModel("poll", polls, FakeCalendar())
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
        val model = PollDetailModel("poll", polls, FakeCalendar())
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
        val model = PollDetailModel("poll", polls, FakeCalendar())
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
        val model = PollDetailModel("poll", polls, FakeCalendar())
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
        val model = PollDetailModel("poll", polls, FakeCalendar())
        model.load()
        polls.join = { throw PollCapacityReached() }
        model.join()
        assertEquals(PollCapacityReached().message, model.joinError)
        assertNull(model.myParticipant)
    }

    @Test fun aFinalizationAfterTheAccountChangesIsDropped() = runBlocking<Unit> {
        val owned = detail.copy(poll = poll.copy(creatorId = "account", status = PollStatus.CLOSED))
        val polls = FakePolls({ owned }).apply { availability = { savedSnapshot } }
        val model = PollDetailModel("poll", polls, FakeCalendar())
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
        val model = PollDetailModel("poll", FakePolls({ detail.copy(poll = finalized, timeOptions = listOf(allDay, first)) }), FakeCalendar())
        assertNull(model.finalEvent)
        model.load()
        val event = model.finalEvent!!
        assertTrue(event.isAllDay)
        assertEquals("Office", event.location)
        assertEquals(Instant.parse("2026-11-10T00:00:00Z") to Instant.parse("2026-11-11T00:00:00Z"), event.insertBounds)
    }

    @Test fun theFinalEventOfATimedOptionKeepsItsInterval() = runBlocking<Unit> {
        val finalized = poll.copy(status = PollStatus.CLOSED, selectedStartTime = first.startTime, selectedEndTime = first.endTime)
        val model = PollDetailModel("poll", FakePolls({ detail.copy(poll = finalized) }), FakeCalendar())
        model.load()
        val event = model.finalEvent!!
        assertFalse(event.isAllDay)
        assertEquals(first.startTime to first.endTime, event.insertBounds)
    }
}
