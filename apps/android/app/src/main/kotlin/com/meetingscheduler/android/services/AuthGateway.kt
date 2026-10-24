package com.meetingscheduler.android.services

import com.meetingscheduler.android.models.Profile
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.sync.withLock

const val AUTH_REDIRECT_URL = "meetingscheduler://auth/callback"
fun authRedirectUrl(attemptId: String): String {
    require(java.util.UUID.fromString(attemptId).toString() == attemptId)
    return "$AUTH_REDIRECT_URL?attempt=$attemptId"
}

/** Injected boundary retains the pinned SDK's persistence, PKCE verifier and refresh logic. */
interface AuthGateway {
    val status: Flow<SessionStatus>
    suspend fun loadProfile(userId: String, credential: String): Profile
    suspend fun updateProfile(userId: String, credential: String, updates: kotlinx.serialization.json.JsonObject): Profile = error("Profile updates unavailable")
    suspend fun awaitInitialization()
    suspend fun exchangeCode(code: String, isCurrent: () -> Boolean = { true }): UserSession
    suspend fun googleSession(idToken: String, nonce: String?): UserSession
    suspend fun startMagicLink(email: String, redirectUrl: String, isCurrent: () -> Boolean = { true })
    suspend fun startBrowserGoogle(redirectUrl: String, isCurrent: () -> Boolean = { true })
    suspend fun signOut(previous: UserSession?)
    suspend fun importSession(session: UserSession, isCurrent: () -> Boolean = { true })
}

@OptIn(io.github.jan.supabase.annotations.SupabaseExperimental::class)
class SupabaseAuthGateway(
    private val injectedClient: io.github.jan.supabase.SupabaseClient? = null,
    private val dispatcher: kotlinx.coroutines.CoroutineDispatcher = kotlinx.coroutines.Dispatchers.Main.immediate,
    private val revocationClient: (() -> io.github.jan.supabase.SupabaseClient)? = null,
) : AuthGateway {
    private val starts = kotlinx.coroutines.sync.Mutex()
    private val mutations = kotlinx.coroutines.sync.Mutex()
    private val client get() = injectedClient ?: SupabaseService.client
    override val status get() = client.auth.sessionStatus
    override suspend fun loadProfile(userId: String, credential: String): Profile = accountPostgrest(client, credential).from("profiles").select {
        filter { eq("id", userId) }
    }.decodeSingle()
    override suspend fun updateProfile(userId: String, credential: String, updates: kotlinx.serialization.json.JsonObject): Profile =
        accountPostgrest(client, credential).from("profiles").update(updates) {
            filter { eq("id", userId) }
        }.decodeSingle()
    override suspend fun awaitInitialization() = client.auth.awaitInitialization()
    // Do not import until the router verifies that the initiating session still owns it.
    override suspend fun exchangeCode(code: String, isCurrent: () -> Boolean) = starts.withLock {
        if (!isCurrent()) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
        client.auth.exchangeCodeForSession(code, saveSession = false)
    }
    override suspend fun googleSession(idToken: String, nonce: String?): UserSession {
        var result: UserSession? = null
        io.github.jan.supabase.auth.providers.builtin.IDToken.login(client, onSuccess = { result = it }, redirectUrl = null) {
            this.idToken = idToken
            provider = io.github.jan.supabase.auth.providers.Google
            this.nonce = nonce
        }
        return checkNotNull(result)
    }
    override suspend fun startMagicLink(email: String, redirectUrl: String, isCurrent: () -> Boolean) = starts.withLock {
        if (!isCurrent()) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
        client.auth.signInWith(io.github.jan.supabase.auth.providers.builtin.OTP, redirectUrl = redirectUrl) {
            this.email = email; createUser = true
        }
        if (!isCurrent()) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
    }
    override suspend fun startBrowserGoogle(redirectUrl: String, isCurrent: () -> Boolean) = starts.withLock {
        if (!isCurrent()) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
        client.auth.signInWith(io.github.jan.supabase.auth.providers.Google, redirectUrl = redirectUrl)
        if (!isCurrent()) throw kotlinx.coroutines.CancellationException("Authentication attempt changed")
    }
    override suspend fun signOut(previous: UserSession?) {
        if (previous == null) return
        kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + dispatcher) { mutations.withLock {
            // This bounded local mutation survives teardown; remote I/O below remains cancellable.
            // A queued cleanup may remove only its initiating server session. A
            // refreshed token in that same lineage still belongs to this logout.
            if (authSessionIdentity(client.auth.currentSessionOrNull()) == authSessionIdentity(previous)) {
                client.auth.stopAutoRefreshForCurrentSession()
                client.auth.clearSession()
            }
        } }
        // Revoke the captured original even if a replacement was installed while
        // waiting. The ephemeral SDK cannot clear or revoke the shared replacement.
        revokeSnapshot(previous)
    }

    @OptIn(io.github.jan.supabase.annotations.SupabaseInternal::class)
    private suspend fun revokeSnapshot(previous: UserSession) {
        val isolated = revocationClient?.invoke() ?: io.github.jan.supabase.createSupabaseClient(client.supabaseUrl, client.supabaseKey) {
            install(io.github.jan.supabase.auth.Auth) {
                autoLoadFromStorage = false; autoSaveToStorage = false; alwaysAutoRefresh = false
                autoSetupPlatform = false; enableLifecycleCallbacks = false
                sessionManager = io.github.jan.supabase.auth.MemorySessionManager()
                codeVerifierCache = io.github.jan.supabase.auth.MemoryCodeVerifierCache()
            }
        }
        try {
            isolated.auth.importSession(previous, autoRefresh = false)
            isolated.auth.signOut(io.github.jan.supabase.auth.SignOutScope.LOCAL)
        } finally { isolated.close() }
    }
    override suspend fun importSession(session: UserSession, isCurrent: () -> Boolean) = kotlinx.coroutines.withContext(dispatcher) { mutations.withLock {
        if (!isCurrent()) throw kotlinx.coroutines.CancellationException("Account changed")
        // Stop old refresh before installing. The supported custom SessionManager has
        // no suspension point, so this import publishes one atomic credential change.
        client.auth.stopAutoRefreshForCurrentSession()
        client.auth.importSession(session, autoRefresh = false)
        if (client.auth.config.alwaysAutoRefresh && client.auth.currentSessionOrNull()?.accessToken == session.accessToken) {
            client.auth.startAutoRefreshForCurrentSession()
        }
    } }
}
