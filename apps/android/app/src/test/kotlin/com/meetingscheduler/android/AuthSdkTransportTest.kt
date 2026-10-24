package com.meetingscheduler.android

import com.meetingscheduler.android.services.*
import com.meetingscheduler.android.models.*
import com.russhwolf.settings.Settings
import io.github.jan.supabase.auth.*
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.createSupabaseClient
import io.ktor.client.engine.mock.*
import io.ktor.http.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy

@OptIn(io.github.jan.supabase.annotations.SupabaseInternal::class, io.github.jan.supabase.annotations.SupabaseExperimental::class)
class AuthSdkTransportTest {
    private val json = Json { ignoreUnknownKeys = true }
    private fun body(id: String, seconds: Long = 3600, token: String = "token-$id") = """{"access_token":"$token","refresh_token":"refresh-$id","expires_in":$seconds,"token_type":"bearer","user":{"id":"$id","aud":"authenticated"}}"""
    private fun session(id: String, seconds: Long = 3600, token: String = "token-$id") = json.decodeFromString<UserSession>(body(id, seconds, token))
    private fun settings(disk: MutableMap<String, String>): Settings = Proxy.newProxyInstance(Settings::class.java.classLoader, arrayOf(Settings::class.java)) { _, method, args ->
        when (method.name) {
            "putString" -> { disk[args!![0] as String] = args[1] as String; null }
            "getStringOrNull" -> disk[args!![0] as String]
            "remove" -> { disk.remove(args!![0] as String); null }
            "getKeys" -> disk.keys
            "getSize" -> disk.size
            "hasKey" -> disk.containsKey(args!![0] as String)
            "clear" -> { disk.clear(); null }
            else -> error("Unexpected Settings call ${method.name}")
        }
    } as Settings

    private fun client(engine: MockEngine, manager: AtomicSessionManager, refresh: Boolean = false, launch: ((String) -> Unit)? = null) = createSupabaseClient("https://unit.invalid", "unit-key") {
        httpEngine = engine
        install(Auth) {
            autoLoadFromStorage = true; autoSaveToStorage = true; alwaysAutoRefresh = refresh
            autoSetupPlatform = false; enableLifecycleCallbacks = false
            coroutineDispatcher = Dispatchers.Unconfined
            if (launch != null) urlLauncher = object : UrlLauncher {
                override suspend fun openUrl(supabase: io.github.jan.supabase.SupabaseClient, url: String) { launch(url) }
            }
            flowType = FlowType.PKCE
            codeVerifierCache = MemoryCodeVerifierCache("persisted-verifier")
            sessionManager = manager
        }
    }

    @Test(timeout = 15000) fun pinnedSdkPkceExchangeDoesNotImportUntilExplicitInstallAndUsesVerifier() = runBlocking {
        val requests = mutableListOf<String>()
        val disk = mutableMapOf<String, String>()
        val manager = AtomicSessionManager("session-key", settings(disk))
        val engine = MockEngine { request ->
            requests += request.url.toString() + " " + request.body.toByteArray().decodeToString()
            respond(body("A"), headers = headersOf(HttpHeaders.ContentType, "application/json"))
        }
        val client = client(engine, manager)
        // Android platform setup publishes the signed-out status; JVM has no Activity.
        client.auth.setSessionStatus(SessionStatus.NotAuthenticated())
        val gateway = SupabaseAuthGateway(client, Dispatchers.Unconfined)
        withTimeout(1000) { gateway.awaitInitialization() }
        val exchanged = withTimeout(1000) { gateway.exchangeCode("one-time-code") }
        assertNull(client.auth.currentSessionOrNull()); assertTrue(disk.isEmpty())
        assertTrue(requests.single().contains("grant_type=pkce"))
        assertTrue(requests.single().contains("one-time-code"))
        assertTrue(requests.single().contains("persisted-verifier"))
        assertNull(client.auth.codeVerifierCache.loadCodeVerifier())
        gateway.importSession(exchanged)
        assertEquals("A", client.auth.currentUserOrNull()!!.id)
        assertEquals("A", manager.loadSession()!!.user!!.id)
        // The exact production manager restores the existing SDK-compatible record.
        val restoredManager = AtomicSessionManager("session-key", settings(disk))
        val restarted = client(MockEngine { error("Restoration must not make a request") }, restoredManager)
        withTimeout(1000) { restarted.auth.awaitInitialization() }
        assertEquals("token-A", restarted.auth.currentSessionOrNull()!!.accessToken)
        restarted.close(); client.close()
    }

    @Test(timeout = 15000) fun gatewayRejectsAnInstallThatBecameStaleWhileWaitingForAnotherMutation() = runBlocking {
        val manager = AtomicSessionManager("session-key", settings(mutableMapOf()))
        val client = client(MockEngine { error("No network expected") }, manager)
        client.auth.setSessionStatus(SessionStatus.NotAuthenticated())
        val gateway = SupabaseAuthGateway(client, Dispatchers.Unconfined)
        gateway.importSession(session("B"))
        try { gateway.importSession(session("A")) { false }; fail("stale install accepted") }
        catch (_: CancellationException) { }
        assertEquals("B", client.auth.currentUserOrNull()!!.id)
        assertEquals("B", manager.loadSession()!!.user!!.id)
        client.close()
    }

    @Test(timeout = 15000) fun cancelledOldSdkRefreshCannotOverwriteReplacementOrReturningAccountOnSuccessOrFailure() = runBlocking {
        for (returnToA in listOf(false, true)) for (fails in listOf(false, true)) {
            val disk = mutableMapOf<String, String>()
            val manager = AtomicSessionManager("session-key", settings(disk))
            val started = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>()
            val engine = MockEngine {
                started.complete(Unit)
                withContext(NonCancellable) { reply.await() }
                if (fails) respond("""{"error":"invalid_grant","error_description":"expired refresh"}""", HttpStatusCode.BadRequest, headersOf(HttpHeaders.ContentType, "application/json"))
                else respond(body("A", token = "old-refresh-A"), headers = headersOf(HttpHeaders.ContentType, "application/json"))
            }
            val client = client(engine, manager, refresh = true)
            client.auth.setSessionStatus(SessionStatus.NotAuthenticated())
            val gateway = SupabaseAuthGateway(client, Dispatchers.Unconfined)
            gateway.importSession(session("A", seconds = 1))
            withTimeout(3000) { started.await() }
            val replacement = async { gateway.importSession(session("B")) }
            withTimeout(1000) { while (client.auth.currentUserOrNull()?.id != "B") yield() }
            assertEquals("token-B", manager.loadSession()!!.accessToken)
            reply.complete(Unit); withTimeout(2000) { replacement.await() }
            if (returnToA) {
                gateway.importSession(session("A", token = "new-session-A"))
            }
            delay(30)
            assertEquals(if (returnToA) "new-session-A" else "token-B", client.auth.currentSessionOrNull()!!.accessToken)
            assertEquals(client.auth.currentSessionOrNull()!!.accessToken, manager.loadSession()!!.accessToken)
            client.close()
        }
    }

    @Test(timeout = 15000) fun atomicManagerPreservesLegacyMigrationAndHasNoSuspensionDuringSaveOrRemove() = runBlocking {
        val disk = mutableMapOf("session" to Json.encodeToString(UserSession.serializer(), session("A")))
        val manager = AtomicSessionManager("scoped-key", settings(disk))
        assertFalse(disk.containsKey("session")); assertEquals("A", manager.loadSession()!!.user!!.id)
        var savedSynchronously = false
        val pending = launch(start = CoroutineStart.UNDISPATCHED) { manager.saveSession(session("B")); savedSynchronously = true }
        assertTrue(savedSynchronously); pending.join()
        manager.deleteSession(); assertTrue(disk.isEmpty())
    }

    @Test(timeout = 15000) fun delayedRemoteLogoutSuccessAndFailureCannotRetainOldSdkCredentialsOrClearReplacement() = runBlocking {
        for (replacement in listOf<String?>(null, "B", "A")) for (fails in listOf(false, true)) {
            val manager = AtomicSessionManager("main-session", settings(mutableMapOf()))
            val client = client(MockEngine { error("Shared client must not revoke credentials") }, manager)
            client.auth.setSessionStatus(SessionStatus.NotAuthenticated())
            val remoteStarted = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>()
            val revoker = client(MockEngine { request ->
                assertTrue(request.url.encodedPath.endsWith("/logout"))
                assertEquals("local", request.url.parameters["scope"])
                assertEquals("Bearer token-A", request.headers[HttpHeaders.Authorization])
                remoteStarted.complete(Unit); reply.await()
                if (fails) respond("{\"message\":\"offline\"}", HttpStatusCode.InternalServerError, headersOf(HttpHeaders.ContentType, "application/json"))
                else respond("", HttpStatusCode.NoContent)
            }, AtomicSessionManager("ephemeral", settings(mutableMapOf())))
            val gateway = SupabaseAuthGateway(client, Dispatchers.Unconfined, revocationClient = { revoker })
            gateway.importSession(session("A"))
            val signout = async { runCatching { gateway.signOut() } }
            withTimeout(1000) { remoteStarted.await() }
            assertNull(client.auth.currentSessionOrNull()); assertNull(manager.loadSession())
            if (replacement != null) gateway.importSession(session(replacement, token = "new-$replacement"))
            reply.complete(Unit); withTimeout(2000) { signout.await() }
            assertEquals(replacement?.let { "new-$it" }, client.auth.currentSessionOrNull()?.accessToken)
            assertEquals(replacement?.let { "new-$it" }, manager.loadSession()?.accessToken)
            client.close()
        }
    }

    @Test(timeout = 15000) fun otpBrowserAndNativeGoogleUsePinnedSdkPkceRedirectAndNonceContracts() = runBlocking {
        val requests = mutableListOf<String>(); val urls = mutableListOf<String>()
        val client = client(MockEngine { request ->
            val text = request.body.toByteArray().decodeToString()
            requests += request.url.toString() + " " + text
            if (request.url.parameters["grant_type"] == "id_token") respond(body("A"), headers = headersOf(HttpHeaders.ContentType, "application/json"))
            else respond("{}", headers = headersOf(HttpHeaders.ContentType, "application/json"))
        }, AtomicSessionManager("session", settings(mutableMapOf())), launch = { urls += it })
        client.auth.setSessionStatus(SessionStatus.NotAuthenticated())
        val gateway = SupabaseAuthGateway(client, Dispatchers.Unconfined)
        gateway.startMagicLink("A@example.test")
        assertTrue(requests.single().contains("redirect_to=meetingscheduler%3A%2F%2Fauth%2Fcallback"))
        assertTrue(requests.single().contains("code_challenge"))
        gateway.startBrowserGoogle()
        val browser = Url(urls.single())
        assertEquals(AUTH_REDIRECT_URL, browser.parameters["redirect_to"])
        assertEquals("google", browser.parameters["provider"])
        assertNotNull(browser.parameters["code_challenge"])
        val native = gateway.googleSession("google-id-token", "original-nonce")
        assertEquals("A", native.user!!.id)
        assertTrue(requests.last().contains("google-id-token")); assertTrue(requests.last().contains("original-nonce"))
        assertNull(client.auth.currentSessionOrNull())
        client.close()
    }

    @Test(timeout = 15000) fun commandDispatchKeepsTheOriginatingCredentialWhenSdkTokenResolutionWaitsAcrossAccountChanges() = runBlocking {
        for (command in listOf("create_poll", "join_poll", "save_availability")) for (returnToA in listOf(false, true)) {
            var transported = 0; var bMutations = 0
            lateinit var client: io.github.jan.supabase.SupabaseClient
            val stamp = kotlinx.datetime.Instant.parse("2026-10-23T00:00:00Z")
            val payload = PollCreationPayload("A envelope", timezone = "UTC", useEventPass = true,
                timeOptions = listOf(CreationTimeOption(stamp, stamp + kotlin.time.Duration.parse("1h"))))
            val result = PollCreationResult(Poll("poll-A", "A", "A envelope", status = PollStatus.ACTIVE,
                isPremium = true, maxParticipants = 50, createdAt = stamp, updatedAt = stamp, shareCode = "ABC123"),
                listOf(PollTimeOption("option", "poll-A", stamp, stamp + kotlin.time.Duration.parse("1h"), createdAt = stamp)), "pass-A", "event_pass")
            client = createSupabaseClient("https://unit.invalid", "unit-key") {
                httpEngine = MockEngine { request ->
                    transported++
                    if (request.headers[HttpHeaders.Authorization] == "Bearer token-B") bMutations++
                    assertEquals(listOf("Bearer original-A"), request.headers.getAll(HttpHeaders.Authorization))
                    val response = when (command) {
                        "create_poll" -> Json.encodeToString(PollCreationResult.serializer(), result)
                        "join_poll" -> "{\"participant\":" + Json.encodeToString(PollParticipant.serializer(), PollParticipant("member-A", "poll-A", "A", accessToken = "", createdAt = stamp, updatedAt = stamp)) + ",\"created\":true}"
                        else -> Json.encodeToString(AvailabilitySnapshot.serializer(), AvailabilitySnapshot("member-A", "poll-A", 1, "A draft", emptyList()))
                    }
                    respond(response, headers = headersOf(HttpHeaders.ContentType, "application/json"))
                }
                install(Auth) {
                    autoLoadFromStorage = false; autoSaveToStorage = false; alwaysAutoRefresh = false
                    autoSetupPlatform = false; enableLifecycleCallbacks = false
                    sessionManager = MemorySessionManager(); codeVerifierCache = MemoryCodeVerifierCache()
                }
                install(io.github.jan.supabase.postgrest.Postgrest)
            }
            // Keep the real SDK in Initializing so its authenticated request must
            // suspend before resolving credentials. The service already owns A.
            val owner = object : PollSessionIdentity {
                override var pollUserId: String? = "A"
                override var identityGeneration = 1L
                override var pollAccessToken: String? = "original-A"
            }
            val polls = PollService(owner, injectedClient = client)
            val pending = async(start = CoroutineStart.UNDISPATCHED) { runCatching {
                when (command) {
                    "create_poll" -> polls.createPoll(PollCreationRequest("operation-A", payload))
                    "join_poll" -> polls.joinPoll("poll-A")
                    else -> polls.saveAvailability("poll-A", AvailabilitySaveRequest("request-A", AvailabilityDraft(emptyMap(), "A draft"), 0))
                }
            } }
            assertEquals(0, transported)
            owner.pollUserId = if (returnToA) "A" else "B"; owner.identityGeneration = if (returnToA) 3 else 2
            owner.pollAccessToken = if (returnToA) "new-A" else "token-B"
            client.auth.importSession(session(owner.pollUserId!!, token = owner.pollAccessToken!!), autoRefresh = false)
            assertTrue(withTimeout(1000) { pending.await() }.isFailure)
            assertEquals(1, transported); assertEquals(0, bMutations); assertTrue(polls.myPolls.isEmpty())
            client.close()
        }
    }

    @Test(timeout = 15000) fun calendarDisconnectUsesOnlyCapturedCredentialEvenWhenSdkAlreadyHasB() = runBlocking {
        var transported = 0
        val sent = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>()
        val client = createSupabaseClient("https://unit.invalid", "unit-key") {
            httpEngine = MockEngine { request ->
                transported++
                assertEquals(listOf("Bearer token-A"), request.headers.getAll(HttpHeaders.Authorization))
                assertTrue(request.body.toByteArray().decodeToString().contains("disconnect"))
                sent.complete(Unit); reply.await()
                respond("""{"connected":false,"accountEmail":null,"requiresReconnect":false,"revocationPending":false}""", headers = headersOf(HttpHeaders.ContentType, "application/json"))
            }
            install(Auth) {
                autoLoadFromStorage = false; autoSaveToStorage = false; alwaysAutoRefresh = false
                autoSetupPlatform = false; enableLifecycleCallbacks = false
                sessionManager = MemorySessionManager(); codeVerifierCache = MemoryCodeVerifierCache()
            }
            install(io.github.jan.supabase.functions.Functions)
        }
        val events = kotlinx.coroutines.flow.MutableSharedFlow<SessionStatus>()
        val stamp = kotlinx.datetime.Instant.parse("2026-10-23T00:00:00Z")
        val gateway = object : AuthGateway {
            override val status = events
            override suspend fun loadProfile(userId: String) = Profile(userId, "$userId@example.test", createdAt = stamp, updatedAt = stamp)
            override suspend fun awaitInitialization() {}
            override suspend fun exchangeCode(code: String): UserSession = error("unused")
            override suspend fun googleSession(idToken: String, nonce: String?): UserSession = error("unused")
            override suspend fun startMagicLink(email: String) {}
            override suspend fun startBrowserGoogle() {}
            override suspend fun signOut() {}
            override suspend fun importSession(session: UserSession, isCurrent: () -> Boolean) {}
        }
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val auth = AuthService(scope, null, gateway)
        events.emit(SessionStatus.Authenticated(session("A")))
        val calendar = CalendarService(null, auth, scope, injectedClient = client)
        client.auth.importSession(session("B"), autoRefresh = false)
        val old = async(start = CoroutineStart.UNDISPATCHED) { calendar.setGoogleCalendarEnabled(false) }
        withTimeout(1000) { sent.await() }
        events.emit(SessionStatus.Authenticated(session("B"))); calendar.resetGoogleCalendarState()
        reply.complete(Unit)
        withTimeout(1000) { old.await() }
        assertEquals(1, transported); assertFalse(calendar.googleCalendarLoading); assertNull(calendar.calendarError)
        auth.dispose(); scope.cancel(); client.close()
    }
}
