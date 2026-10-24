package com.meetingscheduler.android.services

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.Config
import com.meetingscheduler.android.models.Profile
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.Google
import io.github.jan.supabase.auth.providers.builtin.IDToken
import io.github.jan.supabase.auth.providers.builtin.OTP
import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Billing identity follows the auth session. Implemented by [PurchaseService]. */
interface BillingIdentity {
    suspend fun login(userId: String)
    suspend fun logout()
}

/**
 * Process-lifetime auth state (F13). [scope] must be the application scope from
 * [com.meetingscheduler.android.AppContainer]: the session listener launched here has to
 * keep running across Activity recreation.
 */
class AuthService(
    private val scope: CoroutineScope,
    private val billingIdentity: BillingIdentity?,
) : PollSessionIdentity {
    private val supabase = SupabaseService.client

    override var identityGeneration by mutableStateOf(0L)
        private set
    private var observedIdentity: String? = null

    private fun observeIdentity(user: UserInfo?) {
        if (observedIdentity != user?.id) {
            observedIdentity = user?.id
            identityGeneration += 1
        }
    }

    var currentUser by mutableStateOf<UserInfo?>(null)
        private set
    var currentSession by mutableStateOf<UserSession?>(null)
        private set
    var profile by mutableStateOf<Profile?>(null)
        private set
    var isLoading by mutableStateOf(true)
        private set

    override val pollUserId: String? get() = currentUser?.id

    val isAuthenticated: Boolean
        get() = currentUser != null

    init {
        initialize()
    }

    private fun initialize() {
        scope.launch {
            // Get initial session
            try {
                val session = supabase.auth.currentSessionOrNull()
                currentSession = session
                observeIdentity(session?.user)
                currentUser = session?.user
                currentUser?.id?.let { userId ->
                    loadProfile(userId)
                    billingIdentity?.login(userId)
                }
            } catch (e: Exception) {
                println("No existing session: ${e.message}")
            }

            isLoading = false

            // Listen for auth changes
            supabase.auth.sessionStatus.onEach { status ->
                handleAuthChange(status)
            }.launchIn(scope)
        }
    }

    private suspend fun handleAuthChange(status: io.github.jan.supabase.auth.status.SessionStatus) {
        when (status) {
            is io.github.jan.supabase.auth.status.SessionStatus.Authenticated -> {
                currentSession = supabase.auth.currentSessionOrNull()
                observeIdentity(supabase.auth.currentUserOrNull())
                currentUser = supabase.auth.currentUserOrNull()
                currentUser?.id?.let { userId ->
                    loadProfile(userId)
                    billingIdentity?.login(userId)
                }
            }
            is io.github.jan.supabase.auth.status.SessionStatus.NotAuthenticated -> {
                currentSession = null
                observeIdentity(null)
                currentUser = null
                profile = null
                billingIdentity?.logout()
            }
            else -> {}
        }
    }

    private suspend fun loadProfile(userId: String) {
        try {
            val response = supabase
                .from("profiles")
                .select {
                    filter {
                        eq("id", userId)
                    }
                }
                .decodeSingle<Profile>()

            profile = response
        } catch (e: Exception) {
            println("Failed to load profile: ${e.message}")
        }
    }

    // MARK: - Sign In Methods

    suspend fun signInWithGoogle(idToken: String, nonce: String? = null) {
        supabase.auth.signInWith(IDToken) {
            this.idToken = idToken
            this.provider = Google
            nonce?.let { this.nonce = it }
        }
    }

    suspend fun signInWithMagicLink(email: String) {
        supabase.auth.signInWith(OTP) {
            this.email = email
            createUser = true
        }
    }

    suspend fun signOut() {
        supabase.auth.signOut()
    }

    // MARK: - Profile Updates

    suspend fun updateProfile(displayName: String?, avatarUrl: String?, timezone: String?) {
        val userId = currentUser?.id ?: throw AuthError.NotAuthenticated

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

        profile = response
    }

    // MARK: - Handle OAuth Callback

    suspend fun handleDeepLink(url: String) {
        try {
            // Supabase will handle the deep link automatically
            // Additional token persistence if needed
        } catch (e: Exception) {
            println("Failed to handle deep link: ${e.message}")
        }
    }

    sealed class AuthError : Exception() {
        object NotAuthenticated : AuthError()
        data class AppleSignInFailed(override val message: String) : AuthError()
    }
}
