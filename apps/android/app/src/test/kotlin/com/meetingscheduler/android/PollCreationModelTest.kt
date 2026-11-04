package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.PollCreationPolls
import com.meetingscheduler.android.ui.CreationFormDraft
import com.meetingscheduler.android.ui.PollCreationModel
import com.meetingscheduler.android.ui.PollCreationStore
import com.meetingscheduler.android.ui.TimeOption
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
import kotlinx.datetime.TimeZone
import org.junit.Assert.*
import org.junit.Test

class PollCreationModelTest {
    private val stamp = Instant.parse("2026-11-04T00:00:00Z")
    private val today = LocalDate(2026, 11, 4)
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
        PollCreationModel(FakePolls(key, send), store, today = { today }, zone = { chicago })

    private val option = TimeOption("one", LocalDate(2026, 11, 10), LocalTime(9, 0), LocalTime(10, 0))

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
            isAllDay = true, timeOptions = listOf(option)))
        var sent: PollCreationRequest? = null
        val model = model(store, send = { sent = it; result })
        assertTrue(model.submit())
        val payload = sent!!.payload
        assertEquals("America/Chicago", payload.timezone)
        assertEquals(PollDates.deadline(LocalDate(2026, 11, 8), chicago), payload.closesAt)
        assertEquals(listOf(PollDates.allDayOption(option.date, chicago)), payload.timeOptions)
        assertNull(store.draft)
        assertNull(store.pending)
        // A late edit, such as a text field's last callback, can't bring the draft back.
        model.edit { it.copy(title = "After") }
        assertNull(store.draft)
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
            PollCreationModel(FakePolls({ "account:1" }) { result }, store)
        }
    }
}
