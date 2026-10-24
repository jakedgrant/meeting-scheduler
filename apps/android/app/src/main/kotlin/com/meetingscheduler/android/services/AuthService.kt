package com.meetingscheduler.android.services

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.models.Profile
import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class NativeSignInAttempt internal constructor(val revision: Long, val accountId: String?, val generation: Long)

/** Billing identity follows the auth session. Implemented by [PurchaseService]. */
interface BillingIdentity {
    suspend fun login(userId: String)
    suspend fun logout()
    fun resetIdentity(userId: String?, generation: Long) {}
}

/**
 * Process-lifetime auth state (F13). [scope] must be the application scope from
 * [com.meetingscheduler.android.AppContainer]: the session listener launched here has to
 * keep running across Activity recreation.
 */
class AuthService(
    private val scope: CoroutineScope,
    private val billingIdentity: BillingIdentity?,
    private val gateway: AuthGateway = SupabaseAuthGateway(),
    private val attempts: AuthAttemptStore = MemoryAuthAttemptStore(),
) : PollSessionIdentity {
    private val supabase by lazy { SupabaseService.client }
    override var identityGeneration by mutableStateOf(0L)
        private set
    var currentUser by mutableStateOf<UserInfo?>(null)
        private set
    var currentSession by mutableStateOf<UserSession?>(null)
        private set
    var profile by mutableStateOf<Profile?>(null)
        private set
    var profileError by mutableStateOf<String?>(null)
        private set
    var callbackError by mutableStateOf<String?>(null)
        private set
    var isLoading by mutableStateOf(true)
        private set
    override val pollAccessToken: String? get() = currentSession?.accessToken
    override val pollUserId: String? get() = currentUser?.id
    val isAuthenticated: Boolean get() = currentUser != null
    private var expiryJob: kotlinx.coroutines.Job? = null
    private var profileJob: kotlinx.coroutines.Job? = null
    private val boundaries = mutableListOf<() -> Unit>()
    private val identities = kotlinx.coroutines.channels.Channel<String?>(kotlinx.coroutines.channels.Channel.CONFLATED)
    private val jobs = mutableListOf<kotlinx.coroutines.Job>()

    /** App-owned observers run synchronously before any dependent I/O starts. */
    fun onBoundary(reset: () -> Unit): () -> Unit {
        boundaries += reset
        return { boundaries -= reset }
    }

    private var disposed = false
    private var authAttemptRevision = 0L
    private val ready = kotlinx.coroutines.CompletableDeferred<Unit>()
    private var initialized = false
    val callbackRouter: AuthCallbackRouter = AuthCallbackRouter(
        scope = scope,
        sessionKey = { "${currentUser?.id}:$identityGeneration" },
        awaitReady = { gateway.awaitInitialization(); ready.await() },
        exchange = { code ->
            val attemptId = callbackRouter.pendingAttemptId
            val id = currentUser?.id
            val generation = identityGeneration
            gateway.exchangeCode(code) { isCurrent(id, generation) && callbackRouter.isCurrentFlow(attemptId) }
        },
        install = { session ->
            val revision = authAttemptRevision
            val id = currentUser?.id
            val generation = identityGeneration
            gateway.importSession(session) { isCurrent(id, generation) && revision == authAttemptRevision }
        },
        reportError = { callbackError = it },
        attempts = attempts,
    )

    fun handleDeepLink(url: String) { callbackRouter.route(url) }


    init {
        // Never await provider work in the auth collector. One worker orders external
        // side effects and reconciles the latest desired identity after a slow old call.
        jobs += scope.launch {
            for (id in identities) {
                try {
                    if (id == null) billingIdentity?.logout() else billingIdentity?.login(id)
                } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (_: Exception) {
                    // Retry independently, always reconcile the newest desired identity.
                    kotlinx.coroutines.delay(1_000)
                    identities.trySend(currentUser?.id)
                }
            }
        }
        jobs += scope.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
            gateway.status.collect { status ->
                when (status) {
                    is io.github.jan.supabase.auth.status.SessionStatus.Authenticated -> acceptSession(status.session)
                    is io.github.jan.supabase.auth.status.SessionStatus.NotAuthenticated -> acceptSession(null)
                    is io.github.jan.supabase.auth.status.SessionStatus.RefreshFailure -> {
                        // Offline refresh retains a nonexpired session. An expired
                        // credential must stop exposing account-owned screens.
                        if (currentSession == null || currentSession?.expiresAt?.let { it <= kotlin.time.Clock.System.now() } == true) acceptSession(null)
                    }
                    else -> Unit
                }
            }
        }
    }

    private fun acceptSession(incoming: UserSession?) {
        val session = incoming?.takeIf { it.expiresAt > kotlin.time.Clock.System.now() }
        expiryJob?.cancel()
        val initial = !initialized
        initialized = true
        val changed = currentUser?.id != session?.user?.id
        currentSession = session
        currentUser = session?.user
        isLoading = false
        if (session != null) {
            val id = session.user?.id
            val token = session.accessToken
            expiryJob = scope.launch {
                val remaining = (session.expiresAt - kotlin.time.Clock.System.now()).inWholeMilliseconds
                kotlinx.coroutines.delay(remaining.coerceAtLeast(0))
                if (currentUser?.id == id && currentSession?.accessToken == token) acceptSession(null)
            }
        }
        if (!changed && !initial) return // Ordinary token refresh preserves generation and drafts.
        identityGeneration++
        callbackRouter.observeBoundary(initial = initial)
        ready.complete(Unit)
        profileJob?.cancel()
        profile = null
        profileError = null
        callbackError = null
        billingIdentity?.resetIdentity(currentUser?.id, identityGeneration)
        boundaries.toList().forEach { it() }
        identities.trySend(currentUser?.id)
        val id = currentUser?.id ?: return
        val generation = identityGeneration
        profileJob = scope.launch {
            try {
                val loaded = gateway.loadProfile(id)
                if (isCurrent(id, generation)) profile = loaded
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (isCurrent(id, generation)) profileError = "Your profile could not be loaded."
            }
        }
    }

    fun isCurrent(id: String?, generation: Long) = !disposed && currentUser?.id == id && identityGeneration == generation

    /** For explicit teardown in tests; process services otherwise live with Application. */
    fun dispose() {
        disposed = true
        ++authAttemptRevision
        callbackRouter.cancelFlow()
        jobs.forEach { it.cancel() }
        profileJob?.cancel()
        expiryJob?.cancel()
        boundaries.clear()
        identities.close()
        callbackRouter.dispose()
    }

    // MARK: - Sign In Methods

    fun beginNativeSignIn(): NativeSignInAttempt {
        check(!disposed) { "Authentication service disposed" }
        val revision = ++authAttemptRevision
        callbackRouter.cancelFlow()
        return NativeSignInAttempt(revision, currentUser?.id, identityGeneration)
    }

    fun isCurrent(attempt: NativeSignInAttempt) = isCurrent(attempt.accountId, attempt.generation) && attempt.revision == authAttemptRevision

    suspend fun signInWithGoogle(idToken: String, nonce: String? = null, attempt: NativeSignInAttempt = beginNativeSignIn()) {
        try {
            if (!isCurrent(attempt)) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
            val session = gateway.googleSession(idToken, nonce)
            if (!isCurrent(attempt)) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
            gateway.importSession(session) { isCurrent(attempt) }
        } catch (error: Exception) {
            if (!isCurrent(attempt)) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
            throw error
        }
    }

    suspend fun signInWithMagicLink(email: String) = startExternal { redirect, current -> gateway.startMagicLink(email, redirect, current) }
    suspend fun signInWithGoogleBrowser() = startExternal { redirect, current -> gateway.startBrowserGoogle(redirect, current) }

    private suspend fun startExternal(start: suspend (String, () -> Boolean) -> Unit) {
        val initiating = beginNativeSignIn() // Supersede before awaiting SDK initialization.
        var attemptId: String? = null
        var request = initiating
        try {
            gateway.awaitInitialization()
            ready.await()
            // The first signed-out initialization is not an account replacement.
            if (initiating.generation == 0L && identityGeneration == 1L && currentUser?.id == initiating.accountId) {
                request = NativeSignInAttempt(initiating.revision, currentUser?.id, identityGeneration)
            }
            if (!isCurrent(request)) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
            val id = callbackRouter.beginFlow(ready = false)
            attemptId = id
            val current = { isCurrent(request) && callbackRouter.isCurrentFlow(id) }
            start(authRedirectUrl(id), current)
            if (!current()) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
            callbackRouter.completeFlow(id)
        } catch (error: Exception) {
            val stillCurrent = isCurrent(request) && (attemptId == null || callbackRouter.isCurrentFlow(attemptId))
            attemptId?.let { callbackRouter.failFlow(it) }
            if (!stillCurrent) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
            throw error
        }
    }

    suspend fun signOut() {
        ++authAttemptRevision
        callbackRouter.cancelFlow()
        acceptSession(null)
        gateway.signOut()
    }

    // MARK: - Profile Updates

    suspend fun updateProfile(displayName: String?, avatarUrl: String?, timezone: String?) {
        val userId = currentUser?.id ?: throw AuthError.NotAuthenticated
        val generation = identityGeneration

        val updates = buildJsonObject {
            displayName?.let { put("display_name", it) }
            avatarUrl?.let { put("avatar_url", it) }
            timezone?.let { put("timezone", it) }
        }

        val response = supabase
            .from("profiles")
            .update(updates) {
                filter {
                    eq("id", userId)
                }
            }
            .decodeSingle<Profile>()

        if (!isCurrent(userId, generation)) throw kotlinx.coroutines.CancellationException("Account changed")
        profile = response
    }

    sealed class AuthError : Exception() {
        object NotAuthenticated : AuthError()
        data class AppleSignInFailed(override val message: String) : AuthError()
    }
}
