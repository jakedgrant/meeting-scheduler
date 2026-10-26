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

class PollReadTransportTest {
    private val stamp = Instant.parse("2026-10-25T12:00:00Z")
    private val json = Json { ignoreUnknownKeys = true }
    private class Identity : PollSessionIdentity {
        override var pollUserId: String? = "A"
        override var identityGeneration: Long = 1
        override val pollAccessToken: String get() = "token-$pollUserId-$identityGeneration"
    }
    private fun client(engine: MockEngine) = createSupabaseClient("https://reads.invalid", "unit-key") {
        httpEngine = engine
        install(Postgrest)
    }
    private fun poll(id: String) = Poll(id, "A", "Poll $id", createdAt = stamp, updatedAt = stamp)
    private fun list(rows: List<Poll>, total: Int, cursor: String? = null) = json.encodeToString(PollSummaryPage(
        rows.map { PollSummaryRow(it, "owner", 1200, 2, stamp, stamp) }, cursor != null, cursor, total))
    private inner class Fixture(people: Int = 4, slots: Int = 300) {
        val poll = poll("p")
        val participants = (0 until people).map { PollParticipant("person-$it", "p", "A", accessToken = "public-$it", createdAt = stamp, updatedAt = stamp) }
        val options = (0 until slots).map { PollTimeOption("slot-$it", "p", stamp, stamp, createdAt = stamp) }
        val rows = participants.flatMap { person -> options.map { option ->
            AvailabilityResponse("${person.id}-${option.id}", person.id, option.id, AvailabilityStatus.AVAILABLE, createdAt = stamp, updatedAt = stamp)
        } }
        fun header(count: Int = options.size) = json.encodeToString(PollDetailPage(poll, options, participants, count, participants.size))
    }
    private fun page(rows: List<AvailabilityResponse>, total: Int? = null, cursor: String? = null) =
        json.encodeToString(PollResponsePage(rows, cursor != null, cursor, total))

    @Test(timeout = 15000) fun listLoadsOneSummaryPageAndAppendsOnDemandWithoutPerPollReads() = runBlocking {
        val requests = mutableListOf<Pair<String, String>>()
        val rows = (0 until 52).map { poll("p$it") }
        val replies = ArrayDeque(listOf(list(rows.take(50), 52, "opaque-microsecond-cursor"), list(rows.takeLast(2), 52)))
        val client = client(MockEngine { request ->
            requests += request.url.encodedPath to request.body.toByteArray().decodeToString()
            respond(replies.removeFirst(), headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        try {
            val service = PollService(Identity(), injectedClient = client)
            service.loadMyPolls()
            assertEquals(1, requests.size); assertEquals(50, service.myPolls.size)
            assertEquals(52, service.listTotalCount); assertTrue(service.hasMorePolls)
            assertEquals(1200, service.pollParticipantCounts["p0"])
            service.loadMorePolls()
            assertEquals(rows, service.myPolls); assertFalse(service.hasMorePolls)
            assertEquals(listOf("/rest/v1/rpc/list_poll_summaries", "/rest/v1/rpc/list_poll_summaries"), requests.map { it.first })
            assertEquals("opaque-microsecond-cursor", json.parseToJsonElement(requests.last().second).jsonObject["page_cursor"]!!.jsonPrimitive.content)
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun repeatedListCursorDoesNotAppendAndRetryKeepsCursor() = runBlocking {
        val replies = ArrayDeque(listOf(list(listOf(poll("a")), 3, "cursor"), list(listOf(poll("b")), 3, "cursor"), list(listOf(poll("b")), 2)))
        val client = client(MockEngine { respond(replies.removeFirst(), headers = headersOf(HttpHeaders.ContentType, "application/json")) })
        try {
            val service = PollService(Identity(), injectedClient = client)
            service.loadMyPolls(); service.loadMorePolls()
            assertEquals(listOf("a"), service.myPolls.map { it.id }); assertNotNull(service.listLoadError)
            assertFalse(service.isLoadingMore)
            service.loadMorePolls()
            assertEquals(listOf("a", "b"), service.myPolls.map { it.id }); assertNull(service.listLoadError)
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun inconsistentFirstSummaryPageRetainsThePreviousListWithError() = runBlocking {
        val replies = ArrayDeque(listOf(list(listOf(poll("old")), 1), list(listOf(poll("partial")), 2)))
        val client = client(MockEngine { respond(replies.removeFirst(), headers = headersOf(HttpHeaders.ContentType, "application/json")) })
        try {
            val service = PollService(Identity(), injectedClient = client)
            service.loadMyPolls(); service.loadMyPolls()
            assertEquals(listOf("old"), service.myPolls.map { it.id }); assertNotNull(service.listLoadError)
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun creationSupersedingRefreshPreservesPagingOrExposesInitialRetry() = runBlocking {
        for (initial in listOf(false, true)) {
            val ready = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val payload = PollCreationPayload("New", timezone = "UTC", timeOptions = emptyList())
            val option = PollTimeOption("slot", "created", stamp, stamp, createdAt = stamp)
            val saved = PollCreationResult(poll("created"), listOf(option), null, "free")
            var calls = 0
            val client = client(MockEngine { request ->
                calls++
                val reply = when {
                    request.url.encodedPath.endsWith("create_poll") -> json.encodeToString(saved)
                    !initial && calls == 1 -> list(listOf(poll("first")), 2, "committed")
                    else -> { ready.complete(Unit); release.await(); list(emptyList(), 0) }
                }
                respond(reply, headers = headersOf(HttpHeaders.ContentType, "application/json"))
            })
            try {
                val service = PollService(Identity(), injectedClient = client)
                if (!initial) service.loadMyPolls()
                val pending = launch { service.loadMyPolls() }
                withTimeout(5000) { ready.await() }
                service.createPoll(PollCreationRequest("new-operation", payload))
                release.complete(Unit); pending.join()
                assertEquals(!initial, service.hasMorePolls)
                assertEquals(if (initial) null else 3, service.listTotalCount)
                assertEquals(initial, service.listLoadError != null)
                assertTrue(service.myPolls.any { it.id == "created" }); assertFalse(service.isLoading)
            } finally { release.complete(Unit); client.close() }
        }
    }

    @Test(timeout = 15000) fun failedRefreshRetryStartsAtFirstPageDespiteRetainedContinuation() = runBlocking {
        val requests = mutableListOf<JsonObject>(); var calls = 0
        val client = client(MockEngine { request ->
            requests += json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
            calls++
            if (calls == 2) throw java.io.IOException("Offline")
            respond(if (calls == 1) list(listOf(poll("old")), 2, "committed") else list(emptyList(), 0),
                headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        try {
            val service = PollService(Identity(), injectedClient = client)
            service.loadMyPolls(); service.loadMyPolls()
            assertTrue(service.hasMorePolls); assertNotNull(service.listLoadError)
            service.retryPollLoad()
            assertNull(requests.last()["page_cursor"]); assertTrue(service.myPolls.isEmpty()); assertNull(service.listLoadError)
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun detailTraverses1200ResponsesWithRequestOwnedCredentials() = runBlocking {
        val fixture = Fixture()
        val requests = mutableListOf<String>()
        val replies = ArrayDeque(listOf(fixture.header(), page(fixture.rows.take(500), 1200, "first"),
            page(fixture.rows.drop(500).take(500), cursor = "second"), page(fixture.rows.takeLast(200))))
        val client = client(MockEngine { request ->
            requests += request.url.encodedPath
            val params = json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
            assertEquals("p", params["poll_uuid"]!!.jsonPrimitive.content)
            if (requests.size > 1) {
                assertEquals(500, params["page_size"]!!.jsonPrimitive.int)
                val expectedCursor = when (requests.size) { 2 -> null; 3 -> "first"; else -> "second" }
                assertEquals(expectedCursor, params["page_cursor"]?.jsonPrimitive?.content)
            }
            assertEquals("Bearer token-A-1", request.headers[HttpHeaders.Authorization])
            assertEquals(1, request.headers.getAll(HttpHeaders.Authorization)!!.size)
            respond(replies.removeFirst(), headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        try {
            val service = PollService(Identity(), injectedClient = client)
            val detail = service.loadPollDetail("p")
            assertEquals(fixture.rows, detail.responses)
            assertEquals(listOf("/rest/v1/rpc/get_poll_detail") + List(3) { "/rest/v1/rpc/list_poll_responses" }, requests)
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun incompleteDuplicateForeignOrMissingCountResponsesFail() = runBlocking {
        val fixture = Fixture(people = 1, slots = 2)
        val foreign = fixture.rows[1].copy(participantId = "foreign")
        val variants = listOf(page(fixture.rows.take(1), 2), page(List(2) { fixture.rows[0] }, 2),
            page(listOf(fixture.rows[0], foreign), 2), page(fixture.rows))
        for (reply in variants) {
            val replies = ArrayDeque(listOf(fixture.header(), reply))
            val client = client(MockEngine { respond(replies.removeFirst(), headers = headersOf(HttpHeaders.ContentType, "application/json")) })
            try {
                try { PollService(Identity(), injectedClient = client).loadPollDetail("p"); fail("Incomplete response accepted") }
                catch (_: IncompletePollRead) { }
            } finally { client.close() }
        }
    }

    @Test(timeout = 15000) fun responseCursorCycleFailsWithoutReturningPartialData() = runBlocking {
        val fixture = Fixture(people = 1, slots = 3)
        val replies = ArrayDeque(listOf(fixture.header(), page(fixture.rows.take(1), 3, "repeat"),
            page(fixture.rows.drop(1).take(1), cursor = "repeat")))
        var calls = 0
        val client = client(MockEngine { calls++; respond(replies.removeFirst(), headers = headersOf(HttpHeaders.ContentType, "application/json")) })
        try {
            try { PollService(Identity(), injectedClient = client).loadPollDetail("p"); fail("Cursor cycle accepted") }
            catch (_: IncompletePollRead) { }
            assertEquals(3, calls)
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun mismatchedMetadataFailsBeforeResponseRequest() = runBlocking {
        val fixture = Fixture(people = 1, slots = 2)
        var calls = 0
        val client = client(MockEngine { calls++; respond(fixture.header(count = 3), headers = headersOf(HttpHeaders.ContentType, "application/json")) })
        try {
            try { PollService(Identity(), injectedClient = client).loadPollDetail("p"); fail("Truncated metadata accepted") }
            catch (_: IncompletePollRead) { }
            assertEquals(1, calls)
        } finally { client.close() }
    }

    @Test(timeout = 15000) fun accountSwitchBetweenResponsePagesStopsFurtherReads() = runBlocking {
        val fixture = Fixture(people = 2, slots = 300)
        val identity = Identity()
        val ready = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var calls = 0
        val client = client(MockEngine {
            calls++
            val reply = if (calls == 1) fixture.header() else {
                ready.complete(Unit); release.await()
                page(fixture.rows.take(500), 600, "old-cursor")
            }
            respond(reply, headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        try {
            val service = PollService(identity, injectedClient = client)
            val pending = async { runCatching { service.loadPollDetail("p") } }
            withTimeout(5000) { ready.await() }
            identity.pollUserId = "B"; identity.identityGeneration++; service.resetSession()
            release.complete(Unit)
            assertTrue(pending.await().exceptionOrNull() is CancellationException)
            assertEquals(2, calls)
        } finally { release.complete(Unit); client.close() }
    }

    @Test(timeout = 15000) fun refreshSupersedesInflightLoadMore() = runBlocking {
        val ready = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var calls = 0
        val client = client(MockEngine {
            calls++
            val reply = when (calls) {
                1 -> list(listOf(poll("a")), 2, "older")
                2 -> { ready.complete(Unit); release.await(); list(listOf(poll("a")), 2) }
                else -> list(listOf(poll("b")), 1)
            }
            respond(reply, headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        try {
            val service = PollService(Identity(), injectedClient = client)
            service.loadMyPolls()
            val pending = launch { service.loadMorePolls() }
            withTimeout(5000) { ready.await() }
            service.loadMyPolls(); release.complete(Unit); pending.join()
            assertEquals(listOf("b"), service.myPolls.map { it.id }); assertFalse(service.isLoadingMore)
        } finally { release.complete(Unit); client.close() }
    }
}
