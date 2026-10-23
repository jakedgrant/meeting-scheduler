package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class PollCreationSessionTest {
    private val instant = Instant.parse("2026-10-23T00:00:00Z")
    private val payload = PollCreationPayload("Draft", timezone = "America/Chicago", timeOptions = listOf(
        CreationTimeOption(instant, Instant.parse("2026-10-23T01:00:00Z"))))
    private val result = PollCreationResult(
        Poll("poll", "account", "Server title", status = PollStatus.ACTIVE, isPremium = true,
            maxParticipants = 50, createdAt = instant, updatedAt = instant, shareCode = "ABC123"),
        listOf(PollTimeOption("option", "poll", instant, Instant.parse("2026-10-23T01:00:00Z"), createdAt = instant)),
        "pass", "event_pass")

    @Test fun lostReplyRestoresTheExactOperationAndPayloadAfterRestart() = runBlocking<Unit> {
        var disk: String? = null
        val json = Json { encodeDefaults = true }
        val editor = PollCreationSession(persist = { disk = it?.let(json::encodeToString) }, newId = { "operation" })
        try { editor.submit(payload, { throw IllegalStateException("lost reply after commit") }, { true }) }
        catch (_: IllegalStateException) { }
        assertNull(editor.saved)
        val restored = PollCreationSession(json.decodeFromString<PollCreationRequest>(disk!!), persist = { disk = it?.let(json::encodeToString) })
        val saved = restored.submit(payload.copy(title = "Must not create a second poll"), {
            assertEquals("operation", it.operationId)
            assertEquals(payload, it.payload)
            result.copy(replayed = true)
        }, { true })
        assertEquals(result.poll, saved!!.poll)
        assertNull(disk)
        assertNull(restored.pending)
    }

    @Test fun serverRejectionRetainsDraftAndAllowsCorrectedCreation() = runBlocking<Unit> {
        var id = 0
        val editor = PollCreationSession(newId = { "operation-${++id}" })
        try { editor.submit(payload, { throw CreationRejected("P0001") }, { true }); fail() }
        catch (error: CreationRejected) { assertTrue(error.message!!.contains("Close an active poll")) }
        assertNull(editor.pending)
        assertEquals("Draft", payload.title)
        val corrected = payload.copy(useEventPass = true)
        editor.submit(corrected, { assertEquals("operation-2", it.operationId); assertTrue(it.payload.useEventPass); result }, { true })
        assertEquals(result, editor.saved)
        assertEquals(50, editor.saved!!.poll.maxParticipants)
    }

    @Test fun persistenceFailurePreventsSendingAnUnrecoverableRequest() = runBlocking<Unit> {
        val editor = PollCreationSession(persist = { throw IllegalStateException("disk full") })
        var sent = false
        try { editor.submit(payload, { sent = true; result }, { true }) } catch (_: IllegalStateException) { }
        assertFalse(sent)
        assertNull(editor.pending)
    }

    @Test fun lateAccountResultCannotBecomeSavedOrClearRetryIdentity() = runBlocking<Unit> {
        var epoch = "A:1"
        val response = CompletableDeferred<PollCreationResult>()
        val started = CompletableDeferred<Unit>()
        var persisted: PollCreationRequest? = null
        val editor = PollCreationSession(persist = { persisted = it })
        val send = async { editor.submit(payload, { started.complete(Unit); response.await() }, { epoch == "A:1" }) }
        started.await()
        epoch = "B:2"
        epoch = "A:3" // Same account later still cannot accept the old session's result.
        response.complete(result)
        assertNull(send.await())
        assertNull(editor.saved)
        assertNotNull(persisted)
    }

    @Test fun repeatedSubmitAfterSuccessReturnsTheSamePollWithoutAnotherRequest() = runBlocking<Unit> {
        val editor = PollCreationSession()
        var sends = 0
        editor.submit(payload, { sends++; result }, { true })
        assertEquals(result, editor.submit(payload, { sends++; result }, { true }))
        assertEquals(1, sends)
    }

    @Test fun changedOperationRejectionCannotUnlockAnotherCreation() = runBlocking<Unit> {
        val editor = PollCreationSession()
        try { editor.submit(payload, { throw CreationRejected("22000") }, { true }) }
        catch (_: CreationRejected) { }
        assertNotNull(editor.pending)
    }

    @Test fun lateRejectionCannotClearThePreviousAccountsRetry() = runBlocking<Unit> {
        var current = true
        val response = CompletableDeferred<Unit>()
        val started = CompletableDeferred<Unit>()
        var disk: PollCreationRequest? = null
        val editor = PollCreationSession(persist = { disk = it })
        val submit = async {
            try { editor.submit(payload, { started.complete(Unit); response.await(); throw CreationRejected("P0001") }, { current }) }
            catch (_: CreationRejected) { }
        }
        started.await()
        current = false
        response.complete(Unit)
        submit.await()
        assertNotNull(disk)
        assertNotNull(editor.pending)
        assertNull(editor.saved)
    }

    @Test fun canonicalCommandEncodesCompletePayloadAndDecodesAuthoritativeState() {
        val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
        val body = json.encodeToString(PollCreationRequest("operation", payload))
        assertTrue(body.contains("\"operation_id\""))
        assertTrue(body.contains("\"time_options\""))
        assertTrue(body.contains("\"is_all_day\":false"))
        assertFalse(body.contains("creator_id"))
        assertFalse(body.contains("max_participants"))
        assertEquals(result, json.decodeFromString<PollCreationResult>(json.encodeToString(result)))
    }
}
