package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.*
import com.revenuecat.purchases.*
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

private val codec = Json { ignoreUnknownKeys = true }
private fun session(id: String, expires: Long = 3600): UserSession = codec.decodeFromString("""{"access_token":"token-$id","refresh_token":"refresh-$id","expires_in":$expires,"token_type":"bearer","user":{"id":"$id","aud":"authenticated"}}""")
private fun profile(id: String) = Profile(id, "$id@example.test", createdAt = kotlinx.datetime.Instant.parse("2026-10-23T00:00:00Z"), updatedAt = kotlinx.datetime.Instant.parse("2026-10-23T00:00:00Z"))
private class Gateway : AuthGateway {
    override val status = MutableSharedFlow<SessionStatus>()
    var load: suspend (String) -> Profile = { profile(it) }
    var initialize: suspend () -> Unit = {}
    var browser: suspend () -> Unit = {}
    var magic: suspend () -> Unit = {}
    var native: suspend () -> UserSession = { session("A") }
    val installed = mutableListOf<String>()
    override suspend fun loadProfile(userId: String, credential: String) = load(userId)
    override suspend fun awaitInitialization() = initialize()
    override suspend fun exchangeCode(code: String, isCurrent: () -> Boolean) = session("A")
    override suspend fun googleSession(idToken: String, nonce: String?) = native()
    override suspend fun startMagicLink(email: String, redirectUrl: String, isCurrent: () -> Boolean) = magic()
    override suspend fun startBrowserGoogle(redirectUrl: String, isCurrent: () -> Boolean) = browser()
    override suspend fun signOut(previous: UserSession?) {}
    override suspend fun importSession(session: UserSession, isCurrent: () -> Boolean) { installed += session.user!!.id }
    suspend fun user(id: String?) { status.emit(if (id == null) SessionStatus.NotAuthenticated() else SessionStatus.Authenticated(session(id))) }
}

class SessionLifecycleTest {
    private fun customer(id: String, entitlement: String): CustomerInfo {
        val date = java.util.Date(1_700_000_000_000)
        val info = EntitlementInfo(entitlement, true, true, PeriodType.NORMAL, date, date,
            java.util.Date(4_000_000_000_000), Store.PLAY_STORE, "product-$id", null, true,
            null, null, OwnershipType.PURCHASED, org.json.JSONObject())
        return CustomerInfo(EntitlementInfos(mapOf(entitlement to info)), emptyMap(), emptyMap(), date,
            3, date, id, null, null, org.json.JSONObject("{\"subscriber\":{}}"))
    }

    @Test(timeout = 15000) fun authCollectorDoesNotWaitForProfileOrBillingAndFencesLateSuccessAndFailure() = runBlocking {
        for (fails in listOf(false, true)) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val gateway = Gateway()
            val old = CompletableDeferred<Unit>()
            gateway.load = { id ->
                if (id == "A") withContext(NonCancellable) { old.await(); if (fails) error("late A failure") }
                profile(id)
            }
            val billingGate = CompletableDeferred<Unit>()
            val calls = mutableListOf<String?>()
            val billing = object : BillingIdentity {
                override suspend fun login(userId: String) { calls += userId; if (userId == "A") billingGate.await() }
                override suspend fun logout() { calls += null }
            }
            val auth = AuthService(scope, billing, gateway)
            gateway.user("A")
            gateway.user("B")
            assertEquals("B", auth.currentUser!!.id)
            assertEquals("B", auth.profile!!.id)
            val generation = auth.identityGeneration
            gateway.user("B") // refresh does not reset B's projection or restart providers
            assertEquals(generation, auth.identityGeneration)
            old.complete(Unit)
            assertEquals("B", auth.profile!!.id)
            assertNull(auth.profileError)
            billingGate.complete(Unit)
            assertEquals(listOf("A", "B"), calls)
            auth.dispose(); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun logoutReturningAHasANewGenerationAndDisposalStopsObservation() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
        var resets = 0; val remove = auth.onBoundary { resets++ }
        gateway.user("A"); val original = auth.identityGeneration
        gateway.user(null); assertNull(auth.profile)
        gateway.user("A"); assertTrue(auth.identityGeneration > original)
        assertEquals(3, resets)
        remove(); gateway.user("B"); assertEquals(3, resets)
        auth.dispose(); gateway.user("A"); assertEquals("B", auth.currentUser!!.id)
        scope.cancel()
    }

    @Test(timeout = 15000) fun expiredRestorationAndOfflineExpiryCannotClearNewAccount() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
        gateway.status.emit(SessionStatus.RefreshFailure(io.github.jan.supabase.auth.status.RefreshFailureCause.NetworkError(IllegalStateException("offline expired restoration"))))
        assertFalse(auth.isLoading); assertFalse(auth.isAuthenticated)
        gateway.status.emit(SessionStatus.Authenticated(session("A", -1)))
        assertFalse(auth.isAuthenticated)
        gateway.status.emit(SessionStatus.Authenticated(session("A", 1)))
        gateway.user("B")
        delay(1100)
        assertEquals("B", auth.currentUser!!.id)
        gateway.status.emit(SessionStatus.Authenticated(session("A", 1)))
        delay(1100)
        assertFalse(auth.isAuthenticated)
        assertNull(auth.profile)
        gateway.user("A"); assertTrue(auth.isAuthenticated)
        auth.dispose(); scope.cancel()
    }

    @Test(timeout = 15000) fun delayedNativeGoogleDoesNotInstallInReplacementAccount() = runBlocking {
        for (fails in listOf(false, true)) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
            val ready = CompletableDeferred<Unit>()
            gateway.native = { ready.await(); if (fails) error("old native failure"); session("A") }
            val old = async { runCatching { auth.signInWithGoogle("id-token", "nonce") } }
            yield(); gateway.user("B"); ready.complete(Unit); old.await()
            assertTrue(gateway.installed.isEmpty())
            assertEquals("B", auth.currentUser!!.id)
            auth.dispose(); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun actualPollServiceOldCleanupCannotClearNewLoadingAndAbaCannotPublish() = runBlocking {
        val identity = object : PollSessionIdentity { override var pollUserId: String? = "A"; override var identityGeneration = 1L }
        val requests = mutableListOf<CompletableDeferred<Pair<List<Poll>, List<Poll>>>>()
        val polls = PollService(identity, listTransport = { CompletableDeferred<Pair<List<Poll>, List<Poll>>>().also { requests += it }.await() })
        val old = async { polls.loadMyPolls() }; yield()
        identity.pollUserId = "B"; identity.identityGeneration++; polls.resetSession()
        val new = async { polls.loadMyPolls() }; yield()
        requests[0].completeExceptionally(IllegalStateException("late offline A")); old.await()
        assertTrue(polls.isLoading)
        requests[1].complete(emptyList<Poll>() to emptyList()); new.await(); assertFalse(polls.isLoading)
        identity.pollUserId = "A"; identity.identityGeneration++; polls.resetSession()
        assertTrue(polls.myPolls.isEmpty())
    }

    @Test(timeout = 15000) fun calendarLateSuccessFailureAndOldCleanupAreSessionFenced() = runBlocking {
        for (fails in listOf(false, true)) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
            val old = CompletableDeferred<Unit>(); var calls = 0
            val calendar = CalendarService(null, auth, scope, connectionTransport = { _, _ ->
                val call = ++calls
                if (call == 1) withContext(NonCancellable) { old.await(); if (fails) error("old calendar failure") }
                """{"connected":true,"accountEmail":"${if (call == 1) "A" else "B"}@example.test","requiresReconnect":false,"revocationPending":false}"""
            }, readDevicePreference = { false })
            auth.onBoundary { calendar.resetSession() }
            gateway.user("A"); gateway.user("B")
            assertEquals("B@example.test", calendar.googleCalendarAccountEmail)
            old.complete(Unit)
            assertEquals("B@example.test", calendar.googleCalendarAccountEmail)
            assertNull(calendar.calendarError)
            auth.dispose(); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun actualPurchaseServiceOrdersExternalIdentitiesAcrossSlowLogoutAndReplacement() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val log = mutableListOf<String>(); val gate = CompletableDeferred<Unit>()
        val provider = object : BillingProvider {
            override suspend fun login(id: String): CustomerInfo? { log += "login:$id"; return customer(id, if (id == "A") "pro_access" else "team_access") }
            override suspend fun logout() { log += "logout:start"; gate.await(); log += "logout:end" }
            override suspend fun customerInfo(): CustomerInfo? = null
            override suspend fun offerings(): Offerings? = null
            override suspend fun purchase(params: PurchaseParams): CustomerInfo = error("unused")
            override suspend fun restore(): CustomerInfo = error("unused")
        }
        val purchases = PurchaseService(null, scope, provider)
        val gateway = Gateway(); val auth = AuthService(scope, purchases, gateway)
        gateway.user("A"); assertTrue(purchases.hasProAccess); assertFalse(purchases.hasTeamAccess)
        gateway.user(null); assertFalse(purchases.hasProAccess); gateway.user("B")
        assertEquals("B", auth.currentUser!!.id)
        assertNull(purchases.customerInfo)
        assertEquals(listOf("login:A", "logout:start"), log)
        gate.complete(Unit)
        assertEquals(listOf("login:A", "logout:start", "logout:end", "login:B"), log)
        assertTrue(purchases.hasTeamAccess)
        assertEquals("B", purchases.customerInfo!!.originalAppUserId)
        auth.dispose(); scope.cancel()
    }

    @Test(timeout = 15000) fun availabilityRetrySurvivesLogoutAnotherAccountAndRecreationWithoutOldCleanupDeletingIt() = runBlocking {
        val disk = mutableMapOf<String, String>()
        val store = AvailabilityRecoveryStore({ disk[it] }, { key, value -> disk[key] = value })
        val a = store.open("A", "poll")
        val snapshot = AvailabilitySnapshot("member-A", "poll", 7, "saved", emptyList())
        a.acceptLoaded(snapshot)
        val draft = AvailabilityDraft(emptyMap(), "A draft")
        var original: AvailabilitySaveRequest? = null
        try { a.save(draft) { original = it; error("offline") } } catch (_: IllegalStateException) { }
        val b = store.open("B", "poll"); assertNull(b.snapshot); assertNull(b.pendingDraft)
        val returned = store.open("A", "poll")
        val loaded = returned.loadIfCurrent({ snapshot.copy(version = 8) }, { true })
        assertEquals(7L, loaded!!.version)
        assertEquals(draft, returned.pendingDraft)
        returned.save(draft) { assertEquals(original, it); snapshot.copy(version = 8) }
        assertNull(store.open("A", "poll").pendingDraft)
        assertNull(store.open("B", "poll").snapshot)
    }

    @Test(timeout = 15000) fun personalizedOfferingsAndTheirCleanupCannotCrossAccountBoundaries() = runBlocking {
        for (fails in listOf(false, true)) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val first = CompletableDeferred<Unit>(); val second = CompletableDeferred<Unit>()
            var calls = 0
            fun offerings(id: String): Offerings {
                val offering = Offering(id, "Offers for $id", mapOf("account" to id), emptyList())
                return Offerings(offering, mapOf(id to offering))
            }
            val provider = object : BillingProvider {
                override suspend fun login(id: String) = customer(id, "pro_access")
                override suspend fun logout() {}
                override suspend fun customerInfo(): CustomerInfo? = null
                override suspend fun offerings(): Offerings {
                    val call = ++calls
                    if (call == 1) { first.await(); if (fails) error("late A offerings error") }
                    else second.await()
                    return offerings(if (call == 1) "A" else "B")
                }
                override suspend fun purchase(params: PurchaseParams): CustomerInfo = error("unused")
                override suspend fun restore(): CustomerInfo = error("unused")
            }
            val purchases = PurchaseService(null, scope, provider)
            purchases.resetIdentity("A", 1); purchases.login("A")
            val old = async(start = CoroutineStart.UNDISPATCHED) { purchases.loadOfferings() }
            purchases.resetIdentity("B", 2)
            assertNull(purchases.offerings)
            val login = async(start = CoroutineStart.UNDISPATCHED) { purchases.login("B") }
            val current = async(start = CoroutineStart.UNDISPATCHED) { purchases.loadOfferings() }
            first.complete(Unit); old.await(); login.await()
            assertTrue(purchases.isLoading)
            assertNull(purchases.offerings)
            second.complete(Unit); current.await()
            assertEquals("B", purchases.currentOffering!!.identifier)
            assertFalse(purchases.isLoading)
            purchases.resetIdentity(null, 3); purchases.loadOfferings()
            assertNull(purchases.offerings); assertEquals(2, calls)
            scope.cancel()
        }
    }

    @Test(timeout = 15000) fun returningARejectsOldProfileSuccessAndFailureFromThePreviousAGeneration() = runBlocking {
        for (fails in listOf(false, true)) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val gateway = Gateway(); val gate = CompletableDeferred<Unit>(); var aLoads = 0
            gateway.load = { id ->
                val oldA = id == "A" && ++aLoads == 1
                if (oldA) withContext(NonCancellable) { gate.await(); if (fails) error("previous A failed") }
                profile(id).copy(displayName = if (oldA) "Old A profile" else "Current $id profile")
            }
            val auth = AuthService(scope, null, gateway)
            gateway.user("A"); gateway.user(null); gateway.user("A")
            assertEquals("Current A profile", auth.profile!!.displayName)
            gate.complete(Unit)
            assertEquals("Current A profile", auth.profile!!.displayName); assertNull(auth.profileError)
            auth.dispose(); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun oldDevicePreferenceReadsCannotEnableANewAccountsCalendarOrOverwriteItsError() = runBlocking {
        for (fails in listOf(false, true)) {
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
            val old = CompletableDeferred<Unit>()
            val calendar = CalendarService(null, auth, scope,
                connectionTransport = { _, _ -> """{"connected":false,"accountEmail":null,"requiresReconnect":false,"revocationPending":false}""" },
                readDevicePreference = { id ->
                    if (id == "A") withContext(NonCancellable) { old.await(); if (fails) error("old disk failure") }
                    id == "A"
                }, readPermission = { true })
            auth.onBoundary { calendar.resetSession() }
            gateway.user("A"); gateway.user("B")
            assertFalse(calendar.appleCalendarEnabled)
            old.complete(Unit)
            assertFalse(calendar.appleCalendarEnabled); assertNull(calendar.calendarError)
            auth.dispose(); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun newerBrowserAttemptPreventsOldNativeGoogleFromInstallingInSameSignedOutSession() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
        gateway.user(null)
        val reply = CompletableDeferred<Unit>()
        gateway.native = { reply.await(); session("A") }
        val native = async { runCatching { auth.signInWithGoogle("token", "nonce") } }
        yield(); auth.signInWithGoogleBrowser(); reply.complete(Unit); native.await()
        assertTrue(gateway.installed.isEmpty())
        auth.dispose(); scope.cancel()
    }

    @Test(timeout = 15000) fun oldBrowserFailureCannotDeleteANewerOtpAttempt() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
        gateway.user(null)
        val reply = CompletableDeferred<Unit>()
        gateway.browser = { reply.await(); error("browser cancelled") }
        val old = async { runCatching { auth.signInWithGoogleBrowser() } }
        yield(); auth.signInWithMagicLink("A@example.test"); reply.complete(Unit); old.await()
        auth.callbackRouter.route(authRedirectUrl(auth.callbackRouter.pendingAttemptId!!) + "&code=latest-otp")
        assertEquals(listOf("A"), gateway.installed)
        auth.dispose(); scope.cancel()
    }

    @Test(timeout = 15000) fun initializationPublishesOnlyLatestRequestedIntentAndRestoredAccountReplacementRejectsIt() = runBlocking {
        for (restored in listOf<String?>(null, "B")) {
            val scope = createApplicationScope(Dispatchers.Unconfined); val gateway = Gateway()
            val ready = CompletableDeferred<Unit>(); gateway.initialize = { ready.await() }
            var browser = 0; var magic = 0
            gateway.browser = { browser++ }; gateway.magic = { magic++ }
            val auth = AuthService(scope, null, gateway)
            val old = async { runCatching { auth.signInWithMagicLink("old@example.test") } }; yield()
            val current = async { runCatching { auth.signInWithGoogleBrowser() } }; yield()
            gateway.user(restored); ready.complete(Unit)
            assertTrue(old.await().exceptionOrNull() is CancellationException)
            assertEquals(0, magic)
            if (restored == null) { assertTrue(current.await().isSuccess); assertEquals(1, browser); assertNotNull(auth.callbackRouter.pendingAttemptId) }
            else { assertTrue(current.await().exceptionOrNull() is CancellationException); assertEquals(0, browser); assertNull(auth.callbackRouter.pendingAttemptId) }
            auth.dispose(); scope.cancel()
        }
    }

    @Test(timeout = 15000) fun credentialManagerAttemptIsSupersededBeforeNativeSdkCallAndSignoutCancelsPendingLink() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
        gateway.user(null); var nativeCalls = 0
        gateway.native = { nativeCalls++; session("A") }
        val credentialManagerAttempt = auth.beginNativeSignIn()
        auth.signInWithMagicLink("latest@example.test")
        assertNotNull(auth.callbackRouter.pendingAttemptId)
        val old = runCatching { auth.signInWithGoogle("old-token", "nonce", credentialManagerAttempt) }
        assertTrue(old.exceptionOrNull() is CancellationException); assertEquals(0, nativeCalls)
        auth.signOut(); assertNull(auth.callbackRouter.pendingAttemptId)
        auth.dispose(); scope.cancel()
    }

    @Test(timeout = 15000) fun creationRetryReturnsOriginalPollAfterAccountChangesWithoutAnotherPass() = runBlocking {
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val gateway = Gateway(); val auth = AuthService(scope, null, gateway)
        val disk = mutableMapOf<String, PollCreationRequest?>()
        val stamp = kotlinx.datetime.Instant.parse("2026-10-23T00:00:00Z")
        val payload = PollCreationPayload("A draft", timezone = "UTC", useEventPass = true,
            timeOptions = listOf(CreationTimeOption(stamp, stamp + kotlin.time.Duration.parse("1h"))))
        val authoritative = PollCreationResult(
            Poll("original-poll", "A", "A draft", status = PollStatus.ACTIVE, isPremium = true,
                maxParticipants = 50, createdAt = stamp, updatedAt = stamp, shareCode = "ABC123"),
            listOf(PollTimeOption("option", "original-poll", stamp, stamp + kotlin.time.Duration.parse("1h"), createdAt = stamp)),
            "oldest-pass", "event_pass")
        val receipts = mutableMapOf<String, PollCreationResult>(); var redeemed = 0
        val polls = PollService(auth, createTransport = { request ->
            receipts[request.operationId]?.copy(replayed = true) ?: authoritative.also {
                assertEquals(payload, request.payload)
                receipts[request.operationId] = it; redeemed++
                error("Lost reply after transaction committed")
            }
        })
        auth.onBoundary { polls.resetSession() }
        gateway.user("A")
        val a = PollCreationSession(persist = { disk["A"] = it }, newId = { "original-operation" })
        try { a.submit(payload, polls::createPoll, { auth.currentUser?.id == "A" }) } catch (_: IllegalStateException) { }
        assertEquals("original-operation", disk["A"]!!.operationId)
        gateway.user(null); gateway.user("B")
        assertTrue(polls.myPolls.isEmpty()); assertNull(disk["B"])
        gateway.user("A")
        val returned = PollCreationSession(initial = disk["A"], persist = { disk["A"] = it })
        val result = returned.submit(payload.copy(title = "Ignored edited retry"), polls::createPoll, { auth.currentUser?.id == "A" })!!
        assertEquals("original-poll", result.poll.id); assertTrue(result.replayed)
        assertEquals(1, redeemed); assertEquals(1, receipts.size); assertNull(disk["A"])
        assertEquals(listOf("original-poll"), polls.myPolls.map { it.id })
        auth.dispose(); scope.cancel()
    }
}
