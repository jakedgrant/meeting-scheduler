package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.*
import com.russhwolf.settings.Settings
import io.github.jan.supabase.auth.*
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.postgrest.Postgrest
import io.ktor.client.engine.mock.*
import io.ktor.http.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy
import java.util.Base64
import java.util.concurrent.ConcurrentLinkedQueue

@OptIn(io.github.jan.supabase.annotations.SupabaseInternal::class, io.github.jan.supabase.annotations.SupabaseExperimental::class)
class ReviewedIsolationTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val stamp = kotlinx.datetime.Instant.parse("2026-10-23T00:00:00Z")
    private fun jwt(id: String, lineage: String, revision: Int = 1): String {
        val encode = Base64.getUrlEncoder().withoutPadding()
        fun b64(value: String) = encode.encodeToString(value.toByteArray())
        return "${b64("{\"alg\":\"HS256\"}")}.${b64("{\"sub\":\"$id\",\"session_id\":\"$lineage\",\"revision\":$revision}")}.signature"
    }
    private fun session(id: String, lineage: String, revision: Int = 1) = json.decodeFromString<UserSession>("""{"access_token":"${jwt(id, lineage, revision)}","refresh_token":"refresh-$lineage-$revision","expires_in":3600,"token_type":"bearer","user":{"id":"$id","aud":"authenticated"}}""")
    private fun profile(id: String, name: String = id) = Profile(id, "$id@example.test", displayName = name, createdAt = stamp, updatedAt = stamp)
    private fun profileBody(id: String, name: String = id) = "[" + Json.encodeToString(Profile.serializer(), profile(id, name)) + "]"
    private fun readBody(kind: String): String = when (kind) {
        "poll" -> "[" + Json.encodeToString(Poll.serializer(), Poll("poll-A", "A", "A title", createdAt = stamp, updatedAt = stamp, shareCode = "ABC123")) + "]"
        "options" -> "[" + Json.encodeToString(PollTimeOption.serializer(), PollTimeOption("option-A", "poll-A", stamp, stamp + kotlin.time.Duration.parse("1h"), createdAt = stamp)) + "]"
        "participants" -> "[" + Json.encodeToString(PollParticipant.serializer(), PollParticipant("member-A", "poll-A", "A", accessToken = "capability-A", createdAt = stamp, updatedAt = stamp)) + "]"
        "responses" -> "[" + Json.encodeToString(AvailabilityResponse.serializer(), AvailabilityResponse("response-A", "member-A", "option-A", AvailabilityStatus.AVAILABLE, createdAt = stamp, updatedAt = stamp)) + "]"
        else -> "[]"
    }
    private fun manager(disk: MutableMap<String, String> = mutableMapOf()): AtomicSessionManager {
        val settings = Proxy.newProxyInstance(Settings::class.java.classLoader, arrayOf(Settings::class.java)) { _, method, args ->
            when (method.name) {
                "putString" -> { disk[args!![0] as String] = args[1] as String; null }
                "getStringOrNull" -> disk[args!![0] as String]
                "remove" -> { disk.remove(args!![0] as String); null }
                "getKeys" -> disk.keys
                "getSize" -> disk.size
                "hasKey" -> disk.containsKey(args!![0] as String)
                else -> error(method.name)
            }
        } as Settings
        return AtomicSessionManager("review-session", settings)
    }
    private fun client(engine: MockEngine, persistence: AtomicSessionManager = manager(), restore: Boolean = false) = createSupabaseClient("https://unit.invalid", "unit-key") {
        httpEngine = engine
        install(Auth) {
            autoLoadFromStorage = restore; autoSaveToStorage = true; alwaysAutoRefresh = false
            autoSetupPlatform = false; enableLifecycleCallbacks = false
            coroutineDispatcher = Dispatchers.Unconfined
            sessionManager = persistence; codeVerifierCache = MemoryCodeVerifierCache("restored-verifier"); flowType = FlowType.PKCE
        }
        install(Postgrest); install(Functions)
    }
    private class HeldDispatcher : CoroutineDispatcher() {
        var held = false
        val queued = ConcurrentLinkedQueue<Runnable>()
        override fun isDispatchNeeded(context: kotlin.coroutines.CoroutineContext) = held
        override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) { queued.add(block) }
        fun release() { held = false; while (true) (queued.poll() ?: break).run() }
    }

    @Test(timeout = 15000) fun queuedLogoutRevokesOnlyCapturedAAndCannotClearBOrFreshAOnSuccessOrFailure() = runBlocking {
        for (newAccount in listOf("B", "A")) for (fails in listOf(false, true)) {
            val old = session("A", "old-session"); val replacement = session(newAccount, "fresh-session")
            val persistence = manager()
            val shared = client(MockEngine { request ->
                val id = request.url.parameters["id"]!!.removePrefix("eq.")
                respond(profileBody(id), headers = headersOf(HttpHeaders.ContentType, "application/json"))
            }, persistence)
            shared.auth.setSessionStatus(SessionStatus.NotAuthenticated())
            val remoteStarted = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>()
            val revoker = client(MockEngine { request ->
                assertEquals(listOf("Bearer ${old.accessToken}"), request.headers.getAll(HttpHeaders.Authorization))
                assertEquals("local", request.url.parameters["scope"])
                remoteStarted.complete(Unit); reply.await()
                if (fails) respond("{\"message\":\"offline revoke\"}", HttpStatusCode.InternalServerError, headersOf(HttpHeaders.ContentType, "application/json"))
                else respond("", HttpStatusCode.NoContent)
            })
            val dispatcher = HeldDispatcher()
            val gateway = SupabaseAuthGateway(shared, dispatcher, revocationClient = { revoker })
            val scope = createApplicationScope(Dispatchers.Unconfined); val auth = AuthService(scope, null, gateway)
            gateway.importSession(old)
            withTimeout(1000) { while (auth.currentSession?.accessToken != old.accessToken) yield() }
            dispatcher.held = true
            val logout = async(start = CoroutineStart.UNDISPATCHED) { runCatching { auth.signOut() } }
            assertFalse(auth.isAuthenticated); assertFalse(dispatcher.queued.isEmpty())
            shared.auth.importSession(replacement, autoRefresh = false)
            withTimeout(1000) { while (auth.currentSession?.accessToken != replacement.accessToken) yield() }
            dispatcher.release(); withTimeout(1000) { remoteStarted.await() }
            assertEquals(replacement.accessToken, shared.auth.currentSessionOrNull()!!.accessToken)
            assertEquals(replacement.accessToken, persistence.loadSession()!!.accessToken)
            reply.complete(Unit)
            val result = logout.await()
            if (fails) assertTrue(result.exceptionOrNull() is CancellationException) else assertTrue(result.isSuccess)
            assertEquals(replacement.accessToken, auth.currentSession!!.accessToken)
            assertEquals(replacement.accessToken, shared.auth.currentSessionOrNull()!!.accessToken)
            assertEquals(replacement.accessToken, persistence.loadSession()!!.accessToken)
            assertNull(auth.profileError)
            auth.dispose(); scope.cancel(); shared.close()
        }
    }

    @Test(timeout = 15000) fun screenCancellationCannotAbandonQueuedLogoutOrResurrectItsRefreshedSession() = runBlocking {
        for (replacement in listOf<String?>(null, "B", "A")) {
            val old = session("A", "original"); val persistence = manager()
            val shared = client(MockEngine { request -> respond(profileBody(request.url.parameters["id"]!!.removePrefix("eq.")), headers = headersOf(HttpHeaders.ContentType, "application/json")) }, persistence)
            shared.auth.setSessionStatus(SessionStatus.NotAuthenticated())
            val started = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>(); val closed = CompletableDeferred<Unit>()
            val remote = client(MockEngine { request ->
                assertEquals(listOf("Bearer ${old.accessToken}"), request.headers.getAll(HttpHeaders.Authorization))
                started.complete(Unit); reply.await(); respond("", HttpStatusCode.NoContent)
            })
            val revoker = object : io.github.jan.supabase.SupabaseClient by remote {
                override suspend fun close() { remote.close(); closed.complete(Unit) }
            }
            val dispatcher = HeldDispatcher(); val gateway = SupabaseAuthGateway(shared, dispatcher, revocationClient = { revoker })
            val scope = createApplicationScope(Dispatchers.Unconfined); val auth = AuthService(scope, null, gateway)
            gateway.importSession(old); withTimeout(1000) { while (!auth.isAuthenticated) yield() }
            dispatcher.held = true
            val caller = launch(start = CoroutineStart.UNDISPATCHED) { auth.signOut() }
            assertFalse(dispatcher.queued.isEmpty()); caller.cancel(); caller.join()
            val installed = if (replacement == null) session("A", "original", 2) else session(replacement, "replacement")
            shared.auth.importSession(installed, autoRefresh = false)
            if (replacement == null) { delay(20); assertFalse(auth.isAuthenticated) }
            else withTimeout(1000) { while (auth.currentSession?.accessToken != installed.accessToken) yield() }
            dispatcher.release(); withTimeout(1000) { started.await() }
            assertEquals(if (replacement == null) null else installed.accessToken, shared.auth.currentSessionOrNull()?.accessToken)
            reply.complete(Unit); withTimeout(1000) { closed.await() }
            assertEquals(if (replacement == null) null else installed.accessToken, persistence.loadSession()?.accessToken)
            assertEquals(replacement, auth.currentUser?.id)
            auth.dispose(); scope.cancel(); shared.close()
        }
    }

    @Test(timeout = 15000) fun logoutAlsoClearsARefreshedCredentialInTheSameServerSession() = runBlocking {
        val old = session("A", "same-session"); val refreshed = session("A", "same-session", 2)
        val persistence = manager(); val shared = client(MockEngine { error("Shared client cannot revoke") }, persistence)
        shared.auth.setSessionStatus(SessionStatus.NotAuthenticated()); shared.auth.importSession(old, autoRefresh = false)
        val revoker = client(MockEngine { request ->
            assertEquals(listOf("Bearer ${old.accessToken}"), request.headers.getAll(HttpHeaders.Authorization)); respond("", HttpStatusCode.NoContent)
        })
        val dispatcher = HeldDispatcher().apply { held = true }
        val gateway = SupabaseAuthGateway(shared, dispatcher, revocationClient = { revoker })
        val logout = async(start = CoroutineStart.UNDISPATCHED) { gateway.signOut(old) }
        shared.auth.importSession(refreshed, autoRefresh = false)
        dispatcher.release(); logout.await()
        assertNull(shared.auth.currentSessionOrNull()); assertNull(persistence.loadSession()); shared.close()
    }

    @Test(timeout = 15000) fun everyDirectPollReadDispatchesOnlyItsCapturedAccountCredential() = runBlocking {
        for (read in listOf("poll", "options", "participants", "responses", "status")) {
            var calls = 0
            val shared = client(MockEngine { request ->
                calls++; assertEquals(listOf("Bearer original-A"), request.headers.getAll(HttpHeaders.Authorization))
                val data = readBody(read)
                respond(data, headers = headersOf(HttpHeaders.ContentType, "application/json"))
            })
            // The shared SDK already owns B; this app request still belongs to A.
            shared.auth.setSessionStatus(SessionStatus.NotAuthenticated())
            shared.auth.importSession(session("B", "B-session"), autoRefresh = false)
            val owner = object : PollSessionIdentity { override val pollUserId = "A"; override val identityGeneration = 1L; override val pollAccessToken = "original-A" }
            val polls = PollService(owner, injectedClient = shared)
            val pending = async(start = CoroutineStart.UNDISPATCHED) {
                when (read) {
                    "poll" -> assertEquals("poll-A", polls.loadPoll("poll-A")!!.id)
                    "options" -> assertEquals("option-A", polls.loadTimeOptions("poll-A").single().id)
                    "participants" -> assertEquals("member-A", polls.loadParticipants("poll-A").single().id)
                    "status" -> polls.updatePollStatus("poll-A", PollStatus.CLOSED)
                    else -> assertEquals("response-A", polls.loadResponses(listOf("option-A")).single().id)
                }
            }
            pending.await(); assertEquals(1, calls); shared.close()
        }
    }

    @Test(timeout = 15000) fun profileLoadAndUpdatePinCredentialsWhenSharedSdkAlreadyOwnsB() = runBlocking {
        var calls = 0
        val shared = client(MockEngine { request ->
            calls++; assertEquals(listOf("Bearer ${jwt("A", "A-session")}"), request.headers.getAll(HttpHeaders.Authorization))
            respond(profileBody("A", if (request.method == HttpMethod.Patch) "updated-A" else "loaded-A"), headers = headersOf(HttpHeaders.ContentType, "application/json"))
        })
        shared.auth.setSessionStatus(SessionStatus.NotAuthenticated())
        shared.auth.importSession(session("B", "B-session"), autoRefresh = false)
        val events = MutableSharedFlow<SessionStatus>()
        val gateway = SupabaseAuthGateway(shared, Dispatchers.Unconfined)
        val scope = createApplicationScope(Dispatchers.Unconfined)
        val auth = AuthService(scope, null, object : AuthGateway by gateway { override val status = events })
        events.emit(SessionStatus.Authenticated(session("A", "A-session")))
        val update = async(start = CoroutineStart.UNDISPATCHED) { auth.updateProfile("updated-A", null, "UTC") }
        update.await(); withTimeout(1000) { while (calls != 2) yield() }
        assertEquals("A", auth.profile!!.id)
        auth.dispose(); scope.cancel(); shared.close()
    }

    @Test(timeout = 15000) fun freshSameAccountLineageResetsStateButRefreshRetainsGenerationAndFencesOldProfileResults() = runBlocking {
        for (fails in listOf(false, true)) {
            val old = session("A", "old-lineage"); val fresh = session("A", "fresh-lineage")
            val started = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>(); var exchanges = 0
            val shared = client(MockEngine { request ->
                if (request.url.encodedPath.endsWith("/profiles")) {
                    val isOld = request.headers[HttpHeaders.Authorization] == "Bearer ${old.accessToken}"
                    if (isOld) { started.complete(Unit); withContext(NonCancellable) { reply.await() } }
                    if (isOld && fails) respond("{\"message\":\"old profile denied\"}", HttpStatusCode.Forbidden, headersOf(HttpHeaders.ContentType, "application/json"))
                    else respond(profileBody("A", if (isOld) "obsolete-A" else "fresh-A"), headers = headersOf(HttpHeaders.ContentType, "application/json"))
                } else { exchanges++; error("Obsolete callback must not reach SDK token transport") }
            })
            shared.auth.setSessionStatus(SessionStatus.NotAuthenticated())
            val scope = createApplicationScope(Dispatchers.Unconfined); val gateway = SupabaseAuthGateway(shared, Dispatchers.Unconfined)
            val auth = AuthService(scope, null, gateway); gateway.importSession(old); started.await()
            val generation = auth.identityGeneration; val oldAttempt = auth.callbackRouter.beginFlow()
            gateway.importSession(fresh)
            withTimeout(1000) { while (auth.currentSession?.accessToken != fresh.accessToken || auth.profile?.displayName != "fresh-A") yield() }
            assertTrue(auth.identityGeneration > generation); assertNull(auth.callbackRouter.pendingAttemptId)
            val current = auth.callbackRouter.beginFlow(); val currentGeneration = auth.identityGeneration
            gateway.importSession(session("A", "fresh-lineage", 2))
            withTimeout(1000) { while (auth.currentSession?.accessToken != jwt("A", "fresh-lineage", 2)) yield() }
            assertEquals(currentGeneration, auth.identityGeneration); assertEquals(current, auth.callbackRouter.pendingAttemptId)
            auth.handleDeepLink(authRedirectUrl(oldAttempt) + "&code=old")
            auth.handleDeepLink(authRedirectUrl(oldAttempt) + "&error=access_denied")
            reply.complete(Unit); delay(30)
            assertEquals(0, exchanges); assertNull(auth.callbackError); assertNull(auth.profileError)
            assertEquals("fresh-A", auth.profile!!.displayName); assertEquals(current, auth.callbackRouter.pendingAttemptId)
            auth.dispose(); scope.cancel(); shared.close()
        }
    }

    @Test(timeout = 15000) fun persistedCallbackRestoresOnlySameAccountAndServerLineageAcrossColdSdkRestoration() = runBlocking {
        for (sameLineage in listOf(false, true)) {
            val disk = mutableMapOf<String, String>(); val persistence = manager(disk); val attempts = MemoryAuthAttemptStore()
            val oldClient = client(MockEngine { respond(profileBody("A"), headers = headersOf(HttpHeaders.ContentType, "application/json")) }, persistence)
            oldClient.auth.setSessionStatus(SessionStatus.NotAuthenticated())
            val oldScope = createApplicationScope(Dispatchers.Unconfined); val oldGateway = SupabaseAuthGateway(oldClient, Dispatchers.Unconfined)
            val oldAuth = AuthService(oldScope, null, oldGateway, attempts)
            oldGateway.importSession(session("A", "original"))
            withTimeout(1000) { while (oldAuth.currentUser?.id != "A") yield() }
            val id = oldAuth.callbackRouter.beginFlow()
            // Process death preserves pending storage; explicit disposal intentionally clears it.
            oldScope.cancel(); oldClient.close()
            persistence.saveSession(session("A", if (sameLineage) "original" else "fresh", 2))
            var exchanges = 0
            val restarted = client(MockEngine { request ->
                if (request.url.parameters["grant_type"] == "pkce") {
                    exchanges++; respond(Json.encodeToString(UserSession.serializer(), session("A", "callback-result")), headers = headersOf(HttpHeaders.ContentType, "application/json"))
                } else respond(profileBody("A"), headers = headersOf(HttpHeaders.ContentType, "application/json"))
            }, persistence, restore = true)
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val auth = AuthService(scope, null, SupabaseAuthGateway(restarted, Dispatchers.Unconfined), attempts)
            withTimeout(1000) { while (auth.isLoading) yield() }
            auth.handleDeepLink(authRedirectUrl(id) + "&code=cold")
            if (sameLineage) withTimeout(1000) { while (restarted.auth.currentSessionOrNull()?.accessToken != jwt("A", "callback-result")) yield() }
            else delay(30)
            assertEquals(if (sameLineage) 1 else 0, exchanges); assertNull(attempts.read()); assertNull(auth.callbackError)
            if (!sameLineage) assertEquals(jwt("A", "fresh", 2), restarted.auth.currentSessionOrNull()!!.accessToken)
            auth.dispose(); scope.cancel(); restarted.close()
        }
    }

    @Test(timeout = 15000) fun lateDirectReadsAndProfileWritesCannotPublishSuccessOrFailureToReplacementOrFreshA() = runBlocking {
        for (kind in listOf("poll", "options", "participants", "responses", "profile")) for (replacement in listOf("B", "A")) for (fails in listOf(false, true)) {
            val started = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>()
            val shared = client(MockEngine { request ->
                assertEquals(listOf("Bearer ${jwt("A", "original")}"), request.headers.getAll(HttpHeaders.Authorization))
                started.complete(Unit); reply.await()
                if (fails) respond("{\"message\":\"late denied\"}", HttpStatusCode.Forbidden, headersOf(HttpHeaders.ContentType, "application/json"))
                else respond(if (kind == "profile") profileBody("A", "obsolete-update") else readBody(kind), headers = headersOf(HttpHeaders.ContentType, "application/json"))
            })
            shared.auth.setSessionStatus(SessionStatus.NotAuthenticated()); shared.auth.importSession(session("B", "SDK-B"), autoRefresh = false)
            val events = MutableSharedFlow<SessionStatus>(); val scope = createApplicationScope(Dispatchers.Unconfined)
            val gateway = SupabaseAuthGateway(shared, Dispatchers.Unconfined)
            val auth = AuthService(scope, null, object : AuthGateway by gateway {
                override val status = events
                override suspend fun loadProfile(userId: String, credential: String) = profile(userId, "current-$userId")
            })
            events.emit(SessionStatus.Authenticated(session("A", "original")))
            val polls = PollService(auth, injectedClient = shared)
            val pending = async { runCatching {
                when (kind) {
                    "poll" -> polls.loadPoll("poll-A")
                    "options" -> polls.loadTimeOptions("poll-A")
                    "participants" -> polls.loadParticipants("poll-A")
                    "responses" -> polls.loadResponses(listOf("option-A"))
                    else -> auth.updateProfile("obsolete-update", null, "UTC")
                }
            } }
            started.await(); events.emit(SessionStatus.Authenticated(session(replacement, "replacement"))); reply.complete(Unit)
            assertTrue(pending.await().exceptionOrNull() is CancellationException)
            assertEquals("current-$replacement", auth.profile!!.displayName); assertNull(auth.profileError)
            auth.dispose(); scope.cancel(); shared.close()
        }
    }

    @Test(timeout = 15000) fun conflictBackendPinsOriginatingCredentialAndFencesDelayedSuccessAndFailure() = runBlocking {
        for (replacement in listOf("B", "A")) for (fails in listOf(false, true)) {
            val started = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>(); var calls = 0
            val shared = client(MockEngine { request ->
                calls++; assertEquals(listOf("Bearer ${jwt("A", "original")}"), request.headers.getAll(HttpHeaders.Authorization))
                started.complete(Unit); reply.await()
                if (fails) respond("{\"message\":\"old conflict failure\"}", HttpStatusCode.InternalServerError, headersOf(HttpHeaders.ContentType, "application/json"))
                else respond("{\"success\":true,\"coverage\":\"primary\",\"conflictingIds\":[\"option-A\"]}", headers = headersOf(HttpHeaders.ContentType, "application/json"))
            })
            shared.auth.setSessionStatus(SessionStatus.NotAuthenticated()); shared.auth.importSession(session("B", "SDK-B"), autoRefresh = false)
            val events = MutableSharedFlow<SessionStatus>(); val gateway = SupabaseAuthGateway(shared, Dispatchers.Unconfined)
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val auth = AuthService(scope, null, object : AuthGateway by gateway {
                override val status = events
                override suspend fun loadProfile(userId: String, credential: String) = profile(userId)
            })
            val calendar = CalendarService(null, auth, scope, connectionTransport = { _, _ -> "{\"connected\":true,\"accountEmail\":\"current@example.test\",\"requiresReconnect\":false,\"revocationPending\":false}" }, readDevicePreference = { true }, readPermission = { true }, injectedClient = shared, readDeviceConflicts = { _, _ -> emptySet() })
            auth.onBoundary { calendar.resetSession() }; events.emit(SessionStatus.Authenticated(session("A", "original")))
            val old = async { calendar.checkPollConflicts(listOf(PollTimeOption("option-A", "poll-A", stamp, stamp + kotlin.time.Duration.parse("1h"), createdAt = stamp)), "UTC") }
            started.await(); events.emit(SessionStatus.Authenticated(session(replacement, "replacement"))); reply.complete(Unit)
            assertEquals(CalendarCheck.NONE, old.await()); assertEquals(1, calls); assertNull(calendar.calendarError)
            assertEquals("current@example.test", calendar.googleCalendarAccountEmail)
            auth.dispose(); scope.cancel(); shared.close()
        }
    }

    @Test(timeout = 15000) fun conflictCheckReportsFailedSourcesAsUncheckedInsteadOfConflictFree() = runBlocking {
        val hour = kotlin.time.Duration.parse("1h")
        val options = listOf(
            PollTimeOption("device-busy", "poll-A", stamp, stamp + hour, createdAt = stamp),
            PollTimeOption("google-busy", "poll-A", stamp + hour * 2, stamp + hour * 3, createdAt = stamp),
            PollTimeOption("free", "poll-A", stamp + hour * 4, stamp + hour * 5, createdAt = stamp),
        )
        for (deviceFails in listOf(false, true)) for (google in listOf("primary", "error", "unrecognized-coverage")) {
            val shared = client(MockEngine {
                when (google) {
                    "error" -> respond("{\"message\":\"provider unavailable\"}", HttpStatusCode.ServiceUnavailable, headersOf(HttpHeaders.ContentType, "application/json"))
                    "unrecognized-coverage" -> respond("{\"success\":true,\"coverage\":\"all\",\"conflictingIds\":[]}", headers = headersOf(HttpHeaders.ContentType, "application/json"))
                    else -> respond("{\"success\":true,\"coverage\":\"primary\",\"conflictingIds\":[\"google-busy\",\"unknown-id\"]}", headers = headersOf(HttpHeaders.ContentType, "application/json"))
                }
            })
            shared.auth.setSessionStatus(SessionStatus.NotAuthenticated()); shared.auth.importSession(session("A", "original"), autoRefresh = false)
            val events = MutableSharedFlow<SessionStatus>(); val gateway = SupabaseAuthGateway(shared, Dispatchers.Unconfined)
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val auth = AuthService(scope, null, object : AuthGateway by gateway {
                override val status = events
                override suspend fun loadProfile(userId: String, credential: String) = profile(userId)
            })
            val calendar = CalendarService(null, auth, scope, connectionTransport = { _, _ -> "{\"connected\":true,\"accountEmail\":\"current@example.test\",\"requiresReconnect\":false,\"revocationPending\":false}" }, readDevicePreference = { true }, readPermission = { true }, injectedClient = shared,
                readDeviceConflicts = { _, zone -> assertEquals("Pacific/Auckland", zone); if (deviceFails) error("permission revoked"); setOf("device-busy") })
            auth.onBoundary { calendar.resetSession() }; events.emit(SessionStatus.Authenticated(session("A", "original")))
            val check = calendar.checkPollConflicts(options, "Pacific/Auckland")
            val googleChecked = google == "primary"
            val busy = (if (deviceFails) emptySet() else setOf("device-busy")) + (if (googleChecked) setOf("google-busy") else emptySet())
            assertEquals(busy, check.busy)
            assertEquals(if (deviceFails || !googleChecked) setOf("device-busy", "google-busy", "free") - busy else emptySet(), check.unchecked)
            assertEquals(listOfNotNull(CalendarSource.APPLE_CALENDAR.takeIf { !deviceFails }, CalendarSource.GOOGLE_CALENDAR.takeIf { googleChecked }), check.checkedSources)
            assertEquals(listOfNotNull(CalendarSource.APPLE_CALENDAR.takeIf { deviceFails }, CalendarSource.GOOGLE_CALENDAR.takeIf { !googleChecked }), check.failedSources)
            assertNull(calendar.calendarError)
            auth.dispose(); scope.cancel(); shared.close()
        }
    }

    @Test(timeout = 15000) fun nonstandardTokenFallbackUsesExactCredentialAndAccountInsteadOfGuessingRefreshLineage() {
        val old = session("A", "lineage").copy(accessToken = "opaque-original")
        assertEquals(authSessionIdentity(old), authSessionIdentity(old.copy(refreshToken = "rotated-refresh")))
        assertNotEquals(authSessionIdentity(old), authSessionIdentity(old.copy(accessToken = "opaque-new-login")))
        assertNotEquals(authSessionIdentity(old), authSessionIdentity(old.copy(user = old.user!!.copy(id = "B"))))
        assertEquals(authSessionIdentity(session("A", "same", 1)), authSessionIdentity(session("A", "same", 2)))
        assertNotEquals(authSessionIdentity(session("A", "same")), authSessionIdentity(session("A", "fresh")))
    }

    @Test(timeout = 15000) fun deviceCalendarSuspensionCannotDispatchBackendAsReplacementOrLeakOldFailure() = runBlocking {
        for (newAccount in listOf("B", "A")) for (fails in listOf(false, true)) {
            var backendCalls = 0
            val shared = client(MockEngine { backendCalls++; error("Obsolete conflict request reached backend") })
            shared.auth.setSessionStatus(SessionStatus.NotAuthenticated()); shared.auth.importSession(session("B", "SDK-B"), autoRefresh = false)
            val events = MutableSharedFlow<SessionStatus>(); val gateway = SupabaseAuthGateway(shared, Dispatchers.Unconfined)
            val scope = createApplicationScope(Dispatchers.Unconfined)
            val auth = AuthService(scope, null, object : AuthGateway by gateway {
                override val status = events
                override suspend fun loadProfile(userId: String, credential: String) = profile(userId)
            })
            val gate = CompletableDeferred<Unit>(); val started = CompletableDeferred<Unit>()
            val calendar = CalendarService(null, auth, scope, connectionTransport = { _, _ -> "{\"connected\":true,\"accountEmail\":\"current@example.test\",\"requiresReconnect\":false,\"revocationPending\":false}" }, readDevicePreference = { true }, readPermission = { true }, injectedClient = shared,
                readDeviceConflicts = { _, _ -> started.complete(Unit); gate.await(); if (fails) error("old device failure"); setOf("old-conflict") })
            auth.onBoundary { calendar.resetSession() }
            events.emit(SessionStatus.Authenticated(session("A", "old-session")))
            val pending = async { calendar.checkPollConflicts(listOf(PollTimeOption("option-A", "poll-A", stamp, stamp + kotlin.time.Duration.parse("1h"), createdAt = stamp)), "UTC") }
            started.await(); events.emit(SessionStatus.Authenticated(session(newAccount, "new-session")))
            gate.complete(Unit); assertEquals(CalendarCheck.NONE, pending.await())
            assertEquals(0, backendCalls); assertNull(calendar.calendarError)
            assertTrue(calendar.appleCalendarEnabled); assertTrue(calendar.googleCalendarEnabled)
            auth.dispose(); scope.cancel(); shared.close()
        }
    }
}
