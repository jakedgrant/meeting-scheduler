package com.meetingscheduler.android

import com.meetingscheduler.android.services.AuthCallbackRouter
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class AuthCallbackRouterTest {
    private fun session() = Json.decodeFromString<UserSession>("""{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"bearer","user":{"id":"A","aud":"authenticated"}}""")

    @Test(timeout = 15000) fun coldCallbackWaitsForInitializationAndWarmDuplicateDoesNotExchangeTwice() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val ready = CompletableDeferred<Unit>()
        var exchanges = 0; var installed = 0
        val router = AuthCallbackRouter(scope, { "null:0" }, { ready.await() }, { exchanges++; session() }, { installed++ }, { fail(it) })
        router.beginFlow()
        assertTrue(router.route("meetingscheduler://auth/callback?code=one"))
        assertEquals(0, exchanges)
        ready.complete(Unit)
        assertEquals(1, exchanges); assertEquals(1, installed)
        assertTrue(router.route("meetingscheduler://auth/callback?code=one"))
        assertEquals(1, exchanges)
        scope.cancel()
    }

    @Test(timeout = 15000) fun exactRoutesRejectCalendarImplicitTokensMalformedAndDuplicateParameters() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        var exchanges = 0; var errors = 0
        val router = AuthCallbackRouter(scope, { "null:0" }, {}, { exchanges++; session() }, {}, { errors++ })
        router.beginFlow()
        for (url in listOf("meetingscheduler://calendar/callback?code=a", "meetingscheduler://auth/other?code=a", "meetingscheduler://auth/callback/extra?code=a", "https://auth/callback?code=a", "meetingscheduler://auth:443/callback?code=a", "meetingscheduler://auth/callback#access_token=fake", "meetingscheduler://auth/callback?code=%XX")) assertFalse(url, router.route(url))
        for (url in listOf("meetingscheduler://auth/callback", "meetingscheduler://auth/callback?code=", "meetingscheduler://auth/callback?code=a&code=b", "meetingscheduler://auth/callback?error=access_denied")) assertTrue(router.route(url))
        assertEquals(0, exchanges); assertEquals(4, errors)
        scope.cancel()
    }

    @Test(timeout = 15000) fun delayedSuccessAndExpiredFailureCannotAffectReplacementOrReturningSession() = runBlocking {
        for (replacement in listOf("B:2", "A:3")) for (fails in listOf(false, true)) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            var key = "A:1"; var installs = 0; var errors = 0
            val gate = CompletableDeferred<Unit>()
            val router = AuthCallbackRouter(scope, { key }, {}, { gate.await(); if (fails) error("expired code"); session() }, { installs++ }, { errors++ })
            router.beginFlow()
            router.route("meetingscheduler://auth/callback?code=old")
            key = replacement; gate.complete(Unit)
            assertEquals(0, installs); assertEquals(0, errors)
            scope.cancel()
        }
    }

    @Test(timeout = 15000) fun initializationReplacementCannotBeOverwrittenAndScopeDisposalCancelsExchange() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        var key = "null:0"; var exchanges = 0
        val ready = CompletableDeferred<Unit>()
        val router = AuthCallbackRouter(scope, { key }, { ready.await() }, { exchanges++; session() }, {}, {})
        router.beginFlow()
        router.route("meetingscheduler://auth/callback?code=old")
        key = "B:1"; ready.complete(Unit); assertEquals(0, exchanges)
        scope.cancel(); router.route("meetingscheduler://auth/callback?code=disposed"); assertEquals(0, exchanges)
    }

    @Test(timeout = 15000) fun initiatedCallbackDeliveredOnlyAfterBOrReturningAIsRejectedBeforeExchange() = runBlocking {
        for (next in listOf("B:2", "A:3")) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            var key = "A:1"; var exchanges = 0
            val router = AuthCallbackRouter(scope, { key }, {}, { exchanges++; session() }, { fail("stale install") }, { fail("stale error") })
            router.beginFlow()
            key = next; router.observeBoundary(initial = false)
            router.route("meetingscheduler://auth/callback?code=still-valid-old-code")
            assertEquals(0, exchanges)
            scope.cancel()
        }
    }

    @Test(timeout = 15000) fun persistedColdAttemptRebindsOnlyToMatchingInitialRestoredIdentity() = runBlocking {
        for (restored in listOf("A:1", "B:1")) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val store = com.meetingscheduler.android.services.MemoryAuthAttemptStore()
            val old = AuthCallbackRouter(scope, { "A:9" }, {}, { session() }, {}, {}, store)
            old.beginFlow(); old.dispose()
            var key = "null:0"; var installed = 0
            val ready = CompletableDeferred<Unit>()
            val router = AuthCallbackRouter(scope, { key }, { ready.await() }, { session() }, { installed++ }, {}, store)
            router.route("meetingscheduler://auth/callback?code=cold")
            key = restored; router.observeBoundary(initial = true); ready.complete(Unit)
            assertEquals(if (restored == "A:1") 1 else 0, installed)
            assertNull(store.read())
            scope.cancel()
        }
    }

    @Test(timeout = 15000) fun newerAttemptInTheSameSessionFencesOlderExchangeSuccess() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val gate = CompletableDeferred<Unit>(); var installed = 0
        val router = AuthCallbackRouter(scope, { "null:1" }, {}, { gate.await(); session() }, { installed++ }, {})
        router.beginFlow(); router.route("meetingscheduler://auth/callback?code=first")
        router.beginFlow(); gate.complete(Unit)
        assertEquals(0, installed)
        scope.cancel()
    }
}
