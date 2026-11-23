package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.*
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.ktor.client.engine.mock.*
import io.ktor.http.*
import kotlinx.coroutines.*
import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class PollEditTransportTest {
    private val stamp = Instant.parse("2026-11-05T12:00:00Z")
    private val original = Poll("poll", "A", "Planning", description = "Agenda", location = "Room", status = PollStatus.CLOSED,
        closesAt = Instant.parse("2020-01-01T00:00:00.123456Z"), createdAt = stamp, updatedAt = stamp)
    private class Identity : PollSessionIdentity {
        override var pollUserId: String? = "A"
        override var identityGeneration: Long = 1
        override val pollAccessToken: String get() = "token-$pollUserId-$identityGeneration"
    }
    private fun client(engine: MockEngine) = createSupabaseClient("https://poll-edit.invalid", "unit-key") {
        httpEngine = engine
        install(Postgrest)
    }

    @Test(timeout = 15000) fun patchPinsOwnerAndCredentialsReturnsSavedDetailsAndInvalidatesCache() = runBlocking {
        val saved = original.copy(title = "Updated", description = null, location = null)
        val client = client(MockEngine { request ->
            assertEquals(HttpMethod.Patch, request.method)
            assertEquals("/rest/v1/polls", request.url.encodedPath)
            assertEquals("eq.poll", request.url.parameters["id"])
            assertEquals("eq.A", request.url.parameters["creator_id"])
            assertEquals(listOf("Bearer token-A-1"), request.headers.getAll(HttpHeaders.Authorization))
            val fields = Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
            assertEquals(setOf("title", "description", "location"), fields.keys)
            assertEquals("Updated", fields["title"]?.jsonPrimitive?.content)
            assertEquals(JsonNull, fields["description"]); assertEquals(JsonNull, fields["location"])
            respond(Json.encodeToString(listOf(saved)), headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        try {
            val cache = PollDetailCache.inMemory()
            val service = PollService(Identity(), client, listTransport = { listOf(original) to emptyList() }, detailCache = cache)
            service.loadMyPolls()
            cache.save("A", PollDetail(original, emptyList(), emptyList(), emptyList()))
            assertNotNull(service.cachedPollDetail("poll"))
            val draft = PollEditDraft.from(original, stamp).copy(title = " Updated ", description = "", location = "")
            assertEquals(saved, service.updatePoll(draft))
            assertEquals(saved, service.myPolls.single()); assertEquals(saved, service.createdPolls.single())
            assertNull(service.cachedPollDetail("poll"))
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun deniedOrForeignEditsDoNotPublishSuccess() = runBlocking {
        var calls = 0
        val client = client(MockEngine {
            calls++
            respond("[]", headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        try {
            val service = PollService(Identity(), client, listTransport = { listOf(original) to emptyList() })
            service.loadMyPolls()
            for (poll in listOf(original, original.copy(creatorId = "B"))) {
                var failed = false
                try { service.updatePoll(PollEditDraft.from(poll, stamp).copy(title = "Updated")) }
                catch (_: Exception) { failed = true }
                assertTrue(failed)
            }
            assertEquals(1, calls)
            assertEquals(original, service.myPolls.single())
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun oldSessionRepliesCannotUpdateListsOrNewAccountCache() = runBlocking {
        val identity = Identity()
        val client = client(MockEngine {
            identity.identityGeneration++
            respond(Json.encodeToString(listOf(original.copy(title = "Late"))), headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        try {
            val service = PollService(identity, client)
            var cancelled = false
            try { service.updatePoll(PollEditDraft.from(original, stamp).copy(title = "Late")) }
            catch (_: CancellationException) { cancelled = true }
            assertTrue(cancelled)
            assertTrue(service.myPolls.isEmpty())
        } finally { client.close() }
    }
}
