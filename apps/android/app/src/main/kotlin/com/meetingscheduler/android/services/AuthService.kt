package com.meetingscheduler.android.services

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.FailureLog
import com.meetingscheduler.android.models.DisplayNameInput
import com.meetingscheduler.android.models.OnboardingStatus
import com.meetingscheduler.android.models.Profile
import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.async
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.time.Clock

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
    private val gateway: AuthGateway,
    /** Decides when a session has expired and when a sign-in link has. */
    private val clock: Clock,
    private val attempts: AuthAttemptStore = MemoryAuthAttemptStore(),
    /** Accounts this device has recorded as having completed onboarding. */
    private val onboardingMirror: OnboardingMirror = MemoryOnboardingMirror(),
    /** Waits before retry [attempt] (0 for the first retry) of an onboarding write. */
    private val retryDelay: suspend (attempt: Int) -> Unit = { kotlinx.coroutines.delay(1_000L shl it) },
) : PollSessionIdentity, AccountScreenAuth, SignInAuth {
    override var identityGeneration by mutableStateOf(0L)
        private set
    var currentUser by mutableStateOf<UserInfo?>(null)
        private set
    var currentSession by mutableStateOf<UserSession?>(null)
        private set
    override var profile by mutableStateOf<Profile?>(null)
        private set
    var profileError by mutableStateOf<String?>(null)
        private set
    override var callbackError by mutableStateOf<String?>(null)
        private set
    var isLoading by mutableStateOf(true)
        private set
    override val pollAccessToken: String? get() = currentSession?.accessToken
    override val pollUserId: String? get() = currentUser?.id
    override val accountId: String? get() = currentUser?.id
    override val accountEmail: String? get() = currentUser?.email
    val isAuthenticated: Boolean get() = currentUser != null

    /**
     * This device recorded the account's onboarding as complete. It lets an offline launch skip
     * onboarding and resends a completion the server has not stored yet.
     */
    private var onboardingMirrored by mutableStateOf(false)
    private var onboardingJob: kotlinx.coroutines.Job? = null
    private var nameJob: kotlinx.coroutines.Job? = null

    val onboardingStatus: OnboardingStatus
        get() = when {
            onboardingMirrored || profile?.onboardingCompletedAt != null -> OnboardingStatus.NOT_REQUIRED
            profile != null -> OnboardingStatus.REQUIRED
            profileError != null -> OnboardingStatus.NOT_REQUIRED
            else -> OnboardingStatus.UNDETERMINED
        }
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

    private val signedOutSessions = mutableSetOf<String>()
    private var disposed = false
    private var authAttemptRevision = 0L
    private val ready = kotlinx.coroutines.CompletableDeferred<Unit>()
    private var initialized = false
    val callbackRouter: AuthCallbackRouter = AuthCallbackRouter(
        scope = scope,
        sessionKey = { "${authSessionIdentity(currentSession) ?: "null"}:$identityGeneration" },
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
        clock = clock,
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
                        if (currentSession == null || currentSession?.expiresAt?.let { it <= clock.now() } == true) acceptSession(null)
                    }
                    else -> Unit
                }
            }
        }
    }

    private fun acceptSession(incoming: UserSession?) {
        val session = incoming?.takeIf { it.expiresAt > clock.now() && authSessionIdentity(it) !in signedOutSessions }
        expiryJob?.cancel()
        val initial = !initialized
        initialized = true
        val changed = authSessionIdentity(currentSession) != authSessionIdentity(session)
        currentSession = session
        currentUser = session?.user
        isLoading = false
        if (session != null) {
            val id = session.user?.id
            val token = session.accessToken
            expiryJob = scope.launch {
                val remaining = (session.expiresAt - clock.now()).inWholeMilliseconds
                kotlinx.coroutines.delay(remaining.coerceAtLeast(0))
                if (currentUser?.id == id && currentSession?.accessToken == token) acceptSession(null)
            }
        }
        if (!changed && !initial) return // Ordinary token refresh preserves generation and drafts.
        identityGeneration++
        callbackRouter.observeBoundary(initial = initial)
        ready.complete(Unit)
        profileJob?.cancel()
        onboardingJob?.cancel()
        onboardingJob = null
        nameJob?.cancel()
        profile = null
        profileError = null
        onboardingMirrored = currentUser?.id?.let(onboardingMirror::isComplete) ?: false
        callbackError = null
        billingIdentity?.resetIdentity(currentUser?.id, identityGeneration)
        boundaries.toList().forEach { it() }
        identities.trySend(currentUser?.id)
        val id = currentUser?.id ?: return
        val generation = identityGeneration
        val credential = checkNotNull(session).accessToken
        profileJob = scope.launch {
            try {
                val loaded = gateway.loadProfile(id, credential)
                if (isCurrent(id, generation)) acceptServerProfile(loaded)
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (isCurrent(id, generation)) profileError = "Your profile could not be loaded."
            }
        }
    }

    override fun isCurrent(id: String?, generation: Long) = !disposed && currentUser?.id == id && identityGeneration == generation

    /** For explicit teardown in tests; process services otherwise live with Application. */
    fun dispose() {
        disposed = true
        ++authAttemptRevision
        callbackRouter.cancelFlow()
        jobs.toList().forEach { it.cancel() }
        profileJob?.cancel()
        onboardingJob?.cancel()
        nameJob?.cancel()
        expiryJob?.cancel()
        boundaries.clear()
        identities.close()
        callbackRouter.dispose()
    }

    // MARK: - Sign In Methods

    override fun beginNativeSignIn(): NativeSignInAttempt {
        check(!disposed) { "Authentication service disposed" }
        val revision = ++authAttemptRevision
        callbackRouter.cancelFlow()
        return NativeSignInAttempt(revision, currentUser?.id, identityGeneration)
    }

    override fun isCurrent(attempt: NativeSignInAttempt) = isCurrent(attempt.accountId, attempt.generation) && attempt.revision == authAttemptRevision

    override suspend fun signInWithGoogle(idToken: String, nonce: String?, attempt: NativeSignInAttempt) {
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

    override suspend fun signInWithMagicLink(email: String) = startExternal { redirect, current -> gateway.startMagicLink(email, redirect, current) }
    override suspend fun signInWithGoogleBrowser() = startExternal { redirect, current -> gateway.startBrowserGoogle(redirect, current) }

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

    override suspend fun signOut() {
        val original = currentSession // Capture before resetting UI or suspending.
        authSessionIdentity(original)?.let { signedOutSessions += it }
        ++authAttemptRevision
        callbackRouter.cancelFlow()
        acceptSession(null)
        val generation = identityGeneration
        // Resetting the authenticated subtree disposes the caller's screen scope.
        // The application owns cleanup/revocation even if that caller stops waiting.
        val cleanup = scope.async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { gateway.signOut(original) }
        jobs += cleanup
        cleanup.invokeOnCompletion { jobs -= cleanup }
        try { cleanup.await() }
        catch (error: Exception) {
            if (!isCurrent(null, generation)) throw kotlinx.coroutines.CancellationException("Session changed during sign-out")
            throw error
        }
    }

    // MARK: - Profile Updates

    override suspend fun updateProfile(displayName: String?, avatarUrl: String?, timezone: String?) {
        val userId = currentUser?.id ?: throw AuthError.NotAuthenticated
        val generation = identityGeneration

        val updates = buildJsonObject {
            displayName?.let { put("display_name", it) }
            avatarUrl?.let { put("avatar_url", it) }
            timezone?.let { put("timezone", it) }
        }

        val credential = currentSession?.accessToken ?: throw AuthError.NotAuthenticated
        try {
            val response = gateway.updateProfile(userId, credential, updates)
            if (!isCurrent(userId, generation)) throw kotlinx.coroutines.CancellationException("Account changed")
            acceptServerProfile(response)
        } catch (error: Exception) {
            if (!isCurrent(userId, generation)) throw kotlinx.coroutines.CancellationException("Account changed")
            throw error
        }
    }

    private fun acceptServerProfile(loaded: Profile) {
        profile = loaded
        val id = currentUser?.id ?: return
        if (loaded.onboardingCompletedAt != null) {
            if (!onboardingMirrored) onboardingMirror.markComplete(id)
            onboardingMirrored = true
        } else if (onboardingMirrored && onboardingJob == null) {
            // Completed on this device, but the server never stored it.
            sendOnboardingCompletion(id)
        }
    }

    // MARK: - Onboarding

    /**
     * Shows [name] at once and stores it in the background, retrying failures. A blank name is
     * stored as null, so others see "Anonymous".
     */
    fun saveOnboardingName(name: String) {
        val id = currentUser?.id ?: return
        val stored = DisplayNameInput.stored(name)
        profile = profile?.copy(displayName = stored)
        val generation = identityGeneration
        nameJob?.cancel()
        nameJob = scope.launch {
            retrying("Failed to save onboarding name", id, generation) {
                val credential = currentSession?.accessToken ?: throw AuthError.NotAuthenticated
                val response = gateway.updateProfile(id, credential, buildJsonObject { put("display_name", stored) })
                if (isCurrent(id, generation)) acceptServerProfile(response)
            }
        }
    }

    /** Records onboarding as complete on this device at once, then on the server in the background. */
    fun completeOnboarding() {
        val id = currentUser?.id ?: return
        onboardingMirror.markComplete(id)
        onboardingMirrored = true
        sendOnboardingCompletion(id)
    }

    private fun sendOnboardingCompletion(id: String) {
        val generation = identityGeneration
        val credential = currentSession?.accessToken ?: return
        onboardingJob?.cancel()
        onboardingJob = scope.launch {
            retrying("Failed to store onboarding completion", id, generation) { gateway.completeOnboarding(credential) }
        }
    }

    /** Runs [operation] until it succeeds, the account changes or the attempts run out. */
    private suspend fun retrying(failure: String, id: String, generation: Long, operation: suspend () -> Unit) {
        for (attempt in 0 until ONBOARDING_WRITE_ATTEMPTS) {
            if (!isCurrent(id, generation)) return
            try {
                operation()
                return
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                FailureLog.record("AuthService", failure, error)
                if (attempt + 1 == ONBOARDING_WRITE_ATTEMPTS) return
                retryDelay(attempt)
            }
        }
    }

    companion object {
        /** How many times a fire-and-forget onboarding write is tried before it waits for a later launch. */
        const val ONBOARDING_WRITE_ATTEMPTS = 4
    }

    sealed class AuthError : Exception() {
        object NotAuthenticated : AuthError()
        data class AppleSignInFailed(override val message: String) : AuthError()
    }
}

/** Accounts this device has recorded as having completed onboarding. */
interface OnboardingMirror {
    fun isComplete(accountId: String): Boolean
    fun markComplete(accountId: String)
}

class MemoryOnboardingMirror : OnboardingMirror {
    private val completed = mutableSetOf<String>()
    override fun isComplete(accountId: String) = accountId in completed
    override fun markComplete(accountId: String) { completed += accountId }
}
