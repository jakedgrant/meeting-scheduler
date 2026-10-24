package com.meetingscheduler.android.services

import com.meetingscheduler.android.models.Profile
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.sync.withLock

const val AUTH_REDIRECT_URL = "meetingscheduler://auth/callback"

/** Injected boundary retains the pinned SDK's persistence, PKCE verifier and refresh logic. */
interface AuthGateway {
    val status: Flow<SessionStatus>
    suspend fun loadProfile(userId: String): Profile
    suspend fun awaitInitialization()
    suspend fun exchangeCode(code: String): UserSession
    suspend fun googleSession(idToken: String, nonce: String?): UserSession
    suspend fun startMagicLink(email: String)
    suspend fun startBrowserGoogle()
    suspend fun signOut()
    suspend fun importSession(session: UserSession, isCurrent: () -> Boolean = { true })
}

class SupabaseAuthGateway(
    private val injectedClient: io.github.jan.supabase.SupabaseClient? = null,
    private val dispatcher: kotlinx.coroutines.CoroutineDispatcher = kotlinx.coroutines.Dispatchers.Main.immediate,
    private val revocationClient: (() -> io.github.jan.supabase.SupabaseClient)? = null,
) : AuthGateway {
    private val starts = kotlinx.coroutines.sync.Mutex()
    private val mutations = kotlinx.coroutines.sync.Mutex()
    private val client get() = injectedClient ?: SupabaseService.client
    override val status get() = client.auth.sessionStatus
    override suspend fun loadProfile(userId: String): Profile = client.from("profiles").select {
        filter { eq("id", userId) }
    }.decodeSingle()
    override suspend fun awaitInitialization() = client.auth.awaitInitialization()
    // Do not import until the router verifies that the initiating session still owns it.
    override suspend fun exchangeCode(code: String) = client.auth.exchangeCodeForSession(code, saveSession = false)
    override suspend fun googleSession(idToken: String, nonce: String?): UserSession {
        var result: UserSession? = null
        io.github.jan.supabase.auth.providers.builtin.IDToken.login(client, onSuccess = { result = it }, redirectUrl = null) {
            this.idToken = idToken
            provider = io.github.jan.supabase.auth.providers.Google
            this.nonce = nonce
        }
        return checkNotNull(result)
    }
    override suspend fun startMagicLink(email: String) = starts.withLock { client.auth.signInWith(io.github.jan.supabase.auth.providers.builtin.OTP, redirectUrl = AUTH_REDIRECT_URL) {
        this.email = email; createUser = true
    } }
    override suspend fun startBrowserGoogle() = starts.withLock { client.auth.signInWith(io.github.jan.supabase.auth.providers.Google, redirectUrl = AUTH_REDIRECT_URL) }
    override suspend fun signOut() {
        val previous = kotlinx.coroutines.withContext(dispatcher) { mutations.withLock {
            val previous = client.auth.currentSessionOrNull()
            client.auth.stopAutoRefreshForCurrentSession()
            client.auth.clearSession()
            previous
        } } ?: return
        // Revocation must not clear a later shared session on success or failure.
        // A separate ephemeral SDK client owns only the captured old credential.
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
