package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import kotlinx.coroutines.runBlocking
import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class AvailabilitySaveSessionTest {
    private val old = AvailabilitySnapshot("member", "poll", 4, "Saved", emptyList())
    private val draft = AvailabilityDraft(mapOf("option" to AvailabilityStatus.AVAILABLE), "My draft")
    private val saved = AvailabilitySnapshot("member", "poll", 6, "My draft", listOf(
        SavedAvailabilityResponse("response", "option", AvailabilityStatus.AVAILABLE, null, Instant.parse("2026-10-23T00:00:00Z")),
    ))

    @Test fun failedSaveKeepsSavedSnapshotAndRetriesSameRequestId() = runBlocking<Unit> {
        var sequence = 0
        val editor = AvailabilitySaveSession { "request-${++sequence}" }
        editor.acceptLoaded(old)
        val sent = mutableListOf<AvailabilitySaveRequest>()
        try {
            editor.save(draft) { sent.add(it); throw IllegalStateException("response lost after commit") }
            fail("transport failure must be reported")
        } catch (_: IllegalStateException) { }
        assertEquals(old, editor.snapshot)
        val result = editor.save(draft) { sent.add(it); saved }
        assertEquals(sent[0], sent[1])
        assertEquals(4L, sent[1].expectedVersion)
        assertEquals(saved, result)
        assertEquals(saved, editor.snapshot)
        assertEquals("member", result.responseRows().single().participantId)
    }

    @Test fun editedDraftGetsANewRequestWithoutReusingAnAmbiguousPayload() = runBlocking<Unit> {
        var sequence = 0
        val editor = AvailabilitySaveSession { "request-${++sequence}" }
        editor.acceptLoaded(old)
        val requests = mutableListOf<AvailabilitySaveRequest>()
        try { editor.save(draft) { requests.add(it); throw IllegalStateException("offline") } }
        catch (_: IllegalStateException) { }
        val changed = draft.copy(comment = "Changed")
        editor.save(changed) { requests.add(it); saved.copy(comment = "Changed") }
        assertNotEquals(requests[0].requestId, requests[1].requestId)
        assertEquals("Changed", requests[1].draft.comment)
    }

    @Test fun versionConflictKeepsDraftUntilUserAcceptsTheLatestVersion() = runBlocking<Unit> {
        var sequence = 0
        val editor = AvailabilitySaveSession { "request-${++sequence}" }
        editor.acceptLoaded(old)
        var conflicted: AvailabilitySaveRequest? = null
        try { editor.save(draft) { conflicted = it; throw AvailabilityVersionConflict() } }
        catch (_: AvailabilityVersionConflict) { }
        assertEquals(old, editor.snapshot)
        assertEquals("My draft", draft.comment)
        editor.acceptLoaded(old.copy(version = 8, comment = "Other device"))
        editor.save(draft) {
            assertEquals(8L, it.expectedVersion)
            assertNotEquals(conflicted!!.requestId, it.requestId)
            assertEquals(draft, it.draft)
            saved.copy(version = 9)
        }
    }

    @Test fun onlyTheReturnedServerSnapshotBecomesSavedState() = runBlocking<Unit> {
        val editor = AvailabilitySaveSession()
        editor.acceptLoaded(old)
        val persisted = saved.copy(comment = "Canonical server comment")
        assertEquals(persisted, editor.save(draft) { persisted })
        assertEquals("Canonical server comment", editor.snapshot!!.comment)
    }

    @Test fun decodeRpcResultAndKeepSavedResponseIdentity() {
        val response = """{"participant_id":"member","poll_id":"poll","version":6,"comment":null,
            "responses":[{"id":"response","time_option_id":"option","status":"available","note":null,
            "updated_at":"2026-10-23T00:00:00Z"}],"saved_at":"2026-10-23T00:00:00Z","replayed":true}"""
        val result = Json { ignoreUnknownKeys = true }.decodeFromString<AvailabilitySnapshot>(response)
        assertEquals("response", result.responseRows().single().id)
        assertEquals(AvailabilityStatus.AVAILABLE, result.responseRows().single().status)
        assertEquals(6L, result.version)
    }
}
