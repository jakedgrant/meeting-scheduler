package com.meetingscheduler.android

import com.meetingscheduler.android.services.*
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class AuthCallbackRouterTest {
    private fun session(id: String = "A") = Json.decodeFromString<UserSession>("""{"access_token":"access-$id","refresh_token":"refresh-$id","expires_in":3600,"token_type":"bearer","user":{"id":"$id","aud":"authenticated"}}""")
    private fun link(id: String, query: String) = "${authRedirectUrl(id)}&$query"

    @Test(timeout = 15000) fun coldCallbackWaitsForInitializationAndWarmDuplicateDoesNotExchangeTwice() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val ready = CompletableDeferred<Unit>(); var exchanges = 0; var installed = 0
        val router = AuthCallbackRouter(scope, { "null:0" }, { ready.await() }, { exchanges++; session() }, { installed++ }, { fail(it) })
        val callback = link(router.beginFlow(), "code=one")
        assertTrue(router.route(callback)); assertEquals(0, exchanges)
        ready.complete(Unit); assertEquals(1, exchanges); assertEquals(1, installed)
        assertTrue(router.route(callback)); assertEquals(1, exchanges)
        scope.cancel()
    }

    @Test(timeout = 15000) fun exactRoutesRejectCalendarImplicitTokensMalformedAndDuplicateParameters() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined); var exchanges = 0; var errors = 0
        val router = AuthCallbackRouter(scope, { "null:0" }, {}, { exchanges++; session() }, {}, { errors++ })
        val id = router.beginFlow()
        for (url in listOf("meetingscheduler://calendar/callback?code=a", "meetingscheduler://auth/other?code=a", "meetingscheduler://auth/callback/extra?code=a", "https://auth/callback?code=a", "meetingscheduler://auth:443/callback?code=a", "meetingscheduler://auth/callback#access_token=fake", "meetingscheduler://auth/callback?code=%XX")) assertFalse(url, router.route(url))
        for (query in listOf("", "code=", "code=a&code=b", "error=access_denied")) assertTrue(router.route(link(id, query)))
        assertEquals(0, exchanges); assertEquals(4, errors)
        scope.cancel()
    }

    @Test(timeout = 15000) fun delayedSuccessAndExpiredFailureCannotAffectReplacementOrReturningSession() = runBlocking {
        for (replacement in listOf("B:2", "A:3")) for (fails in listOf(false, true)) {
            val scope = createApplicationScope(Dispatchers.Unconfined); var key = "A:1"; var installs = 0; var errors = 0
            val gate = CompletableDeferred<Unit>()
            val router = AuthCallbackRouter(scope, { key }, {}, { gate.await(); if (fails) error("expired code"); session() }, { installs++ }, { errors++ })
            router.route(link(router.beginFlow(), "code=old")); key = replacement; gate.complete(Unit)
            assertEquals(0, installs); assertEquals(0, errors); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun initializationReplacementCannotBeOverwrittenAndScopeDisposalCancelsExchange() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined); var key = "null:0"; var exchanges = 0
        val ready = CompletableDeferred<Unit>()
        val router = AuthCallbackRouter(scope, { key }, { ready.await() }, { exchanges++; session() }, {}, {})
        val callback = link(router.beginFlow(), "code=old")
        router.route(callback); key = "B:1"; ready.complete(Unit); assertEquals(0, exchanges)
        scope.cancel(); router.route(callback); assertEquals(0, exchanges)
    }

    @Test(timeout = 15000) fun initiatedCallbackDeliveredOnlyAfterBOrReturningAIsRejectedBeforeExchange() = runBlocking {
        for (next in listOf("B:2", "A:3")) {
            val scope = createApplicationScope(Dispatchers.Unconfined); var key = "A:1"; var exchanges = 0
            val router = AuthCallbackRouter(scope, { key }, {}, { exchanges++; session() }, { fail("stale install") }, { fail("stale error") })
            val callback = link(router.beginFlow(), "code=still-valid-old-code")
            key = next; router.observeBoundary(initial = false); router.route(callback)
            assertEquals(0, exchanges); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun persistedColdAttemptRebindsOnlyToMatchingInitialRestoredIdentity() = runBlocking {
        for (restored in listOf("A:1", "B:1")) {
            val scope = createApplicationScope(Dispatchers.Unconfined); val store = MemoryAuthAttemptStore()
            val old = AuthCallbackRouter(scope, { "A:9" }, {}, { session() }, {}, {}, store)
            val callback = link(old.beginFlow(), "code=cold"); old.dispose()
            var key = "null:0"; var installed = 0; val ready = CompletableDeferred<Unit>()
            val router = AuthCallbackRouter(scope, { key }, { ready.await() }, { session() }, { installed++ }, {}, store)
            router.route(callback); key = restored; router.observeBoundary(initial = true); ready.complete(Unit)
            assertEquals(if (restored == "A:1") 1 else 0, installed); assertNull(store.read()); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun newerAttemptInTheSameSessionFencesOlderExchangeSuccess() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined); val gate = CompletableDeferred<Unit>(); var installed = 0
        val router = AuthCallbackRouter(scope, { "null:1" }, {}, { gate.await(); session() }, { installed++ }, {})
        router.route(link(router.beginFlow(), "code=first")); router.beginFlow(); gate.complete(Unit)
        assertEquals(0, installed); scope.cancel()
    }

    @Test(timeout = 15000) fun providerErrorFragmentRequiresTheOriginatingQueryAndCannotInstallTokens() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined); var errors = 0
        val router = AuthCallbackRouter(scope, { "null:1" }, {}, { fail("No exchange"); session() }, { fail("No import") }, { errors++ })
        val old = router.beginFlow(); val current = router.beginFlow()
        assertTrue(router.route(authRedirectUrl(old) + "#error=access_denied")); assertEquals(0, errors)
        assertFalse(router.route(authRedirectUrl(current) + "#access_token=fake"))
        assertEquals(current, router.pendingAttemptId)
        assertTrue(router.route(authRedirectUrl(current) + "#error=access_denied&error_description=cancelled"))
        assertEquals(1, errors); assertNull(router.pendingAttemptId); scope.cancel()
    }

    @Test(timeout = 15000) fun oldUriReceivedAfterANewAttemptCannotExchangeReportOrConsumeAndNewLinkStillWorks() = runBlocking {
        for (replacement in listOf("B:2", "A:3", "null:2")) {
            val scope = createApplicationScope(Dispatchers.Unconfined); var key = "A:1"; val exchanges = mutableListOf<String>(); val installed = mutableListOf<String>(); val errors = mutableListOf<String>()
            val router = AuthCallbackRouter(scope, { key }, {}, { exchanges += it; check(it == "current"); session("B") }, { installed += it.user!!.id }, { errors += it })
            val old = router.beginFlow(); key = replacement; router.observeBoundary(initial = false)
            val current = router.beginFlow()
            for (url in listOf(link(old, "code=old"), link(old, "error=access_denied"), link(old, "code=a&code=b"), "$AUTH_REDIRECT_URL?code=old", "$AUTH_REDIRECT_URL?attempt=$old&attempt=$current&code=old", "$AUTH_REDIRECT_URL?attempt=invalid&code=old")) assertTrue(router.route(url))
            assertTrue(exchanges.isEmpty()); assertTrue(errors.isEmpty()); assertEquals(current, router.pendingAttemptId)
            router.route(link(current, "code=current")); assertEquals(listOf("current"), exchanges); assertEquals(listOf("B"), installed); assertNull(router.pendingAttemptId)
            scope.cancel()
        }
    }
}
