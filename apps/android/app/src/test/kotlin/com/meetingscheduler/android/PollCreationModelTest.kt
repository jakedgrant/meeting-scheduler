package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.PollCreationPolls
import com.meetingscheduler.android.ui.CreationFormDraft
import com.meetingscheduler.android.ui.CreationStep
import com.meetingscheduler.android.ui.PollCreationModel
import com.meetingscheduler.android.ui.PollCreationStore
import com.meetingscheduler.android.ui.TimeOption
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlin.time.Clock
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.minus
import kotlinx.datetime.plus
import org.junit.Assert.*
import org.junit.Test

class PollCreationModelTest {
    private val stamp = Instant.parse("2026-11-04T00:00:00Z")
    private val today = LocalDate(2030, 3, 1)
    /** Already March 2 in UTC, still March 1 in Chicago. */
    private val clock = object : Clock { override fun now() = Instant.parse("2030-03-02T03:00:00Z") }
    private val chicago = TimeZone.of("America/Chicago")
    private val result = PollCreationResult(
        Poll("poll", "account", "Planning", status = PollStatus.ACTIVE, createdAt = stamp, updatedAt = stamp, shareCode = "ABC123"),
        listOf(PollTimeOption("option", "poll", stamp, stamp, createdAt = stamp)), entitlement = "free")

    private class MemoryStore(var draft: CreationFormDraft? = null, var pending: PollCreationRequest? = null) : PollCreationStore {
        var draftWrites = 0
        override fun loadDraft() = draft
        override fun saveDraft(draft: CreationFormDraft) { this.draft = draft; draftWrites += 1 }
        override fun clearDraft() { draft = null }
        override fun loadPending() = pending
        override fun savePending(request: PollCreationRequest?) { pending = request }
    }

    private class FakePolls(val key: () -> String, val send: suspend (PollCreationRequest) -> PollCreationResult) : PollCreationPolls {
        override val creationAccountId = "account"
        override val creationAccountKey get() = key()
        override suspend fun createPoll(request: PollCreationRequest) = send(request)
    }

    private fun model(store: MemoryStore, key: () -> String = { "account:1" }, send: suspend (PollCreationRequest) -> PollCreationResult = { result }) =
        PollCreationModel(FakePolls(key, send), store, clock, zone = { chicago })

    private val option = TimeOption("one", LocalDate(2026, 11, 10), LocalTime(9, 0), LocalTime(10, 0))

    @Test fun aNewDraftStartsWithoutOptionsAndAddsTodayOnRequest() {
        val store = MemoryStore()
        val model = model(store)
        assertEquals(today, model.today())
        assertTrue(model.draft.timeOptions.isEmpty())
        assertEquals(today, model.draft.rangeStartDate)
        assertEquals(today, model.draft.rangeEndDate)
        assertEquals(0, store.draftWrites)
        model.addOption()
        assertEquals(listOf(today), model.draft.timeOptions.map { it.date })
    }

    @Test fun editsRestoreAndPersistTheDraft() {
        val store = MemoryStore(CreationFormDraft(title = "Restored", timeOptions = listOf(option)))
        val model = model(store)
        assertEquals("Restored", model.draft.title)
        model.edit { it.copy(title = "Edited") }
        assertEquals("Edited", store.draft?.title)
        model.setHasDueDate(true)
        assertEquals(today, model.draft.dueDate)
        model.setHasDueDate(false)
        model.edit { it.copy(dueDate = LocalDate(2026, 12, 1)) }
        model.setHasDueDate(true)
        assertEquals(LocalDate(2026, 12, 1), store.draft?.dueDate)
    }

    @Test fun optionsAreAddedRemovedAndBuiltFromARange() {
        val store = MemoryStore(CreationFormDraft(timeOptions = listOf(option)))
        val model = model(store)
        model.addOption()
        assertEquals(LocalDate(2026, 11, 11), model.draft.timeOptions[1].date)
        assertEquals(LocalTime(9, 0), model.draft.timeOptions[1].startTime)
        model.updateOption(1) { it.copy(startTime = LocalTime(13, 0), endTime = LocalTime(14, 0)) }
        model.edit { it.copy(rangeStartDate = LocalDate(2026, 11, 9), rangeEndDate = LocalDate(2026, 11, 10),
            rangeStartTime = LocalTime(8, 0), rangeEndTime = LocalTime(8, 30)) }
        model.addRangeOptions()
        assertEquals(listOf(
            LocalDate(2026, 11, 9) to LocalTime(8, 0), LocalDate(2026, 11, 10) to LocalTime(8, 0),
            LocalDate(2026, 11, 10) to LocalTime(9, 0), LocalDate(2026, 11, 11) to LocalTime(13, 0),
        ), model.draft.timeOptions.map { it.date to it.startTime })
        model.removeOption(0)
        assertEquals(3, store.draft?.timeOptions?.size)
    }

    @Test fun aBackwardRangeAddsNothing() {
        val model = model(MemoryStore(CreationFormDraft(timeOptions = listOf(option),
            rangeStartDate = LocalDate(2026, 11, 12), rangeEndDate = LocalDate(2026, 11, 10))))
        model.addRangeOptions()
        assertEquals(listOf(option), model.draft.timeOptions)
        assertEquals("Start date must be before or equal to end date", model.errorMessage)
    }

    @Test fun submittingSendsTheDraftInTheDeviceZoneAndClearsIt() = runBlocking<Unit> {
        val store = MemoryStore(CreationFormDraft(title = "Planning", hasDueDate = true, dueDate = LocalDate(2026, 11, 8),
            isAllDay = true, selectedDays = setOf(LocalDate(2030, 3, 10))))
        var sent: PollCreationRequest? = null
        val model = model(store, send = { sent = it; result })
        assertTrue(model.submit())
        val payload = sent!!.payload
        assertEquals("America/Chicago", payload.timezone)
        assertEquals(PollDates.deadline(LocalDate(2026, 11, 8), chicago), payload.closesAt)
        assertEquals(listOf(PollDates.allDayOption(LocalDate(2030, 3, 10), chicago)), payload.timeOptions)
        assertNull(store.draft)
        assertNull(store.pending)
        // A late edit, such as a text field's last callback, can't bring the draft back.
        model.edit { it.copy(title = "After") }
        assertNull(store.draft)
    }

    @Test fun tappingADayTwiceSelectsThenDeselectsIt() {
        val model = model(MemoryStore())
        model.toggleDay(LocalDate(2026, 11, 12))
        model.toggleDay(LocalDate(2026, 11, 5))
        assertEquals(setOf(LocalDate(2026, 11, 5), LocalDate(2026, 11, 12)), model.draft.selectedDays)
        model.toggleDay(LocalDate(2026, 11, 5))
        assertEquals(setOf(LocalDate(2026, 11, 12)), model.draft.selectedDays)
    }

    @Test fun tappedAllDayDaysAreSentAsSortedAllDayOptions() = runBlocking<Unit> {
        val store = MemoryStore(CreationFormDraft(title = "Offsite", isAllDay = true))
        var sent: PollCreationRequest? = null
        val model = model(store, send = { sent = it; result })
        model.toggleDay(LocalDate(2030, 3, 12))
        model.toggleDay(LocalDate(2030, 3, 5))
        assertTrue(model.submit())
        assertEquals(
            listOf(LocalDate(2030, 3, 5), LocalDate(2030, 3, 12)).map { PollDates.allDayOption(it, chicago) },
            sent!!.payload.timeOptions)
    }

    @Test fun aSelectedDayThatHasPassedIsNotSent() = runBlocking<Unit> {
        val store = MemoryStore(CreationFormDraft(title = "Offsite", isAllDay = true,
            selectedDays = setOf(today.minus(1, DateTimeUnit.DAY), today.plus(1, DateTimeUnit.DAY))))
        var sent: PollCreationRequest? = null
        val model = model(store, send = { sent = it; result })
        assertTrue(model.submit())
        assertEquals(listOf(PollDates.allDayOption(today.plus(1, DateTimeUnit.DAY), chicago)), sent!!.payload.timeOptions)
    }

    @Test fun anAllDayPollWithNoDaysSelectedExplainsAndSendsNothing() = runBlocking<Unit> {
        var sent = false
        val model = model(MemoryStore(CreationFormDraft(title = "Offsite", isAllDay = true)), send = { sent = true; result })
        assertFalse(model.submit())
        assertEquals("Select at least one day.", model.errorMessage)
        assertFalse(sent)
    }

    @Test fun aLostReplyKeepsTheRequestAndTheRetrySendsItAgain() = runBlocking<Unit> {
        val store = MemoryStore(CreationFormDraft(title = "Planning", timeOptions = listOf(option)))
        val sent = mutableListOf<PollCreationRequest>()
        var fail = true
        val model = model(store, send = { sent += it; if (fail) throw IllegalStateException("reply lost") else result.copy(replayed = true) })
        assertFalse(model.submit())
        assertNotNull(model.pending)
        assertEquals(model.pending, store.pending)
        assertTrue(model.errorMessage!!.contains("could not be confirmed"))
        model.edit { it.copy(title = "Changed while pending") }
        fail = false
        assertTrue(model.submit())
        assertEquals(sent[0], sent[1])
        assertEquals("Planning", sent[1].payload.title)
        assertNull(model.pending)
    }

    @Test fun aRestoredRequestIsRetriedBeforeAnythingElse() = runBlocking<Unit> {
        val restored = PollCreationRequest("operation", PollCreationPayload("Earlier", timezone = "UTC",
            timeOptions = listOf(CreationTimeOption(stamp, stamp))))
        var sent: PollCreationRequest? = null
        val model = model(MemoryStore(CreationFormDraft(title = "Draft"), restored), send = { sent = it; result })
        assertEquals(restored, model.pending)
        assertTrue(model.submit())
        assertEquals(restored, sent)
    }

    @Test fun aRejectionShowsItsReasonAndKeepsTheDraft() = runBlocking<Unit> {
        val store = MemoryStore(CreationFormDraft(title = "Planning", timeOptions = listOf(option)))
        val model = model(store, send = { throw CreationRejected("P0001") })
        assertFalse(model.submit())
        assertEquals(CreationRejected("P0001").message, model.errorMessage)
        assertNull(model.pending)
        assertEquals("Planning", store.draft?.title)
    }

    @Test fun aNewTimedDraftWithoutOptionsIsRefusedWithoutSending() = runBlocking<Unit> {
        var sent = false
        val model = model(MemoryStore(), send = { sent = true; result })
        model.edit { it.copy(title = "Planning") }
        assertFalse(model.submit())
        assertFalse(sent)
        assertNull(model.pending)
        assertEquals("Enter a title and at least one time option.", model.errorMessage)
    }

    @Test fun aBlankTitleIsRefusedWithoutSending() = runBlocking<Unit> {
        var sent = false
        val model = model(MemoryStore(CreationFormDraft(title = " ", timeOptions = listOf(option))), send = { sent = true; result })
        assertFalse(model.submit())
        assertFalse(sent)
        assertEquals("Enter a title and at least one time option.", model.errorMessage)
    }

    @Test fun aResultForAnEarlierAccountIsNotReported() = runBlocking<Unit> {
        var key = "account:1"
        val reply = CompletableDeferred<PollCreationResult>()
        val store = MemoryStore(CreationFormDraft(title = "Planning", timeOptions = listOf(option)))
        val model = model(store, key = { key }, send = { reply.await() })
        val submit = async(start = CoroutineStart.UNDISPATCHED) { model.submit() }
        key = "account:2"
        reply.complete(result)
        assertFalse(submit.await())
        assertNull(model.errorMessage)
        assertEquals("Planning", store.draft?.title)
        assertNotNull(store.pending)
    }

    @Test fun anUnreadableStoreFailsConstruction() {
        val store = object : PollCreationStore by MemoryStore() {
            override fun loadPending(): PollCreationRequest? = throw IllegalStateException("corrupt")
        }
        assertThrows(IllegalStateException::class.java) {
            PollCreationModel(FakePolls({ "account:1" }) { result }, store, clock)
        }
    }

    @Test fun theFlowStartsOnDetailsAndNeedsANonBlankTitleToContinue() {
        val model = model(MemoryStore())
        assertEquals(CreationStep.DETAILS, model.step)
        assertEquals(1, model.step.number)
        assertFalse(model.canGoBack)
        assertFalse(model.canAdvance)
        model.advance()
        assertEquals(CreationStep.DETAILS, model.step)
        model.edit { it.copy(title = "   ") }
        assertFalse(model.canAdvance)
        model.edit { it.copy(title = "Planning") }
        assertTrue(model.canAdvance)
        model.advance()
        assertEquals(CreationStep.TIME_OPTIONS, model.step)
    }

    @Test fun stepsRunInOrderAndTheOptionStepNeedsAnOption() {
        val model = model(MemoryStore(CreationFormDraft(title = "Planning")))
        model.advance()
        assertFalse(model.canAdvance)
        model.advance()
        assertEquals(CreationStep.TIME_OPTIONS, model.step)
        model.addOption()
        assertTrue(model.canAdvance)
        model.advance()
        assertEquals(CreationStep.DEADLINE, model.step)
        assertTrue(model.canAdvance)
        model.advance()
        assertEquals(CreationStep.EVENT_PASS, model.step)
        // Creating the poll, not advancing, leaves the last form step.
        assertFalse(model.canAdvance)
        model.advance()
        assertEquals(CreationStep.EVENT_PASS, model.step)
        assertEquals(listOf(1, 2, 3, 4, 5), CreationStep.entries.map { it.number })
    }

    @Test fun backStepsOneAtATimeAndTheReviewJumpsToAnEarlierStep() {
        val model = model(MemoryStore(CreationFormDraft(title = "Planning", timeOptions = listOf(option))))
        repeat(3) { model.advance() }
        assertEquals(CreationStep.EVENT_PASS, model.step)
        model.goBack()
        assertEquals(CreationStep.DEADLINE, model.step)
        model.advance()
        model.goTo(CreationStep.DETAILS)
        assertEquals(CreationStep.DETAILS, model.step)
        model.goTo(CreationStep.EVENT_PASS)
        assertEquals("A jump only goes back", CreationStep.DETAILS, model.step)
        model.goBack()
        assertEquals(CreationStep.DETAILS, model.step)
    }

    @Test fun anAllDayPollNeedsADayNotAnOption() {
        val model = model(MemoryStore(CreationFormDraft(title = "Offsite", isAllDay = true, timeOptions = listOf(option))))
        model.advance()
        assertFalse(model.canAdvance)
        model.toggleDay(LocalDate(2030, 3, 12))
        assertTrue(model.canAdvance)
        assertEquals(LocalDate(2030, 3, 12), model.firstOptionDate)
        model.toggleDay(LocalDate(2030, 3, 12))
        assertFalse(model.canAdvance)
        // Turning all-day off falls back to the timed options.
        model.edit { it.copy(isAllDay = false) }
        assertTrue(model.canAdvance)
        assertEquals(option.date, model.firstOptionDate)
    }

    @Test fun aSuccessfulCreationMovesToShareAndBlocksGoingBack() = runBlocking<Unit> {
        val model = model(MemoryStore(CreationFormDraft(title = "Planning", timeOptions = listOf(option))))
        repeat(3) { model.advance() }
        assertTrue(model.submit())
        assertEquals(CreationStep.SHARE, model.step)
        assertEquals("poll", model.createdPoll?.id)
        assertEquals("ABC123", model.createdPoll?.shareCode)
        assertTrue(model.created)
        assertFalse(model.canGoBack)
        model.goBack()
        model.goTo(CreationStep.DETAILS)
        assertEquals(CreationStep.SHARE, model.step)
        assertFalse(model.canAdvance)
    }

    @Test fun aFailedCreationStaysOnTheLastStep() = runBlocking<Unit> {
        val model = model(MemoryStore(CreationFormDraft(title = "Planning", timeOptions = listOf(option))),
            send = { throw CreationRejected("P0001") })
        repeat(3) { model.advance() }
        assertFalse(model.submit())
        assertEquals(CreationStep.EVENT_PASS, model.step)
        assertNull(model.createdPoll)
        assertTrue(model.canGoBack)
    }

    @Test fun aRetainedSubmissionReopensOnTheLastStepAndReviewsTheSavedRequest() = runBlocking<Unit> {
        val restored = PollCreationRequest("operation", PollCreationPayload("Earlier", location = "Room 4", timezone = "UTC",
            closesAt = Instant.parse("2026-11-09T00:00:00Z"),
            timeOptions = listOf(CreationTimeOption(stamp, stamp), CreationTimeOption(stamp, stamp))))
        var sent: PollCreationRequest? = null
        val model = model(MemoryStore(CreationFormDraft(title = "Draft"), restored), send = { sent = it; result })
        assertEquals(CreationStep.EVENT_PASS, model.step)
        assertFalse(model.canGoBack)
        model.goBack()
        assertEquals(CreationStep.EVENT_PASS, model.step)
        val review = model.review
        assertEquals("Earlier", review.title)
        assertEquals(2, review.optionCount)
        assertEquals(LocalDate(2026, 11, 8), review.deadline)
        assertEquals("Room 4", review.location)
        assertTrue(model.submit())
        assertEquals(restored, sent)
        assertEquals(CreationStep.SHARE, model.step)
    }

    @Test fun theReviewSummarisesTheDraft() {
        val model = model(MemoryStore(CreationFormDraft(title = " Planning ", location = " ", hasDueDate = true,
            dueDate = LocalDate(2026, 12, 1), timeOptions = listOf(option, option))))
        val review = model.review
        assertEquals("Planning", review.title)
        assertEquals(2, review.optionCount)
        assertEquals(LocalDate(2026, 12, 1), review.deadline)
        assertNull(review.location)
    }
}
