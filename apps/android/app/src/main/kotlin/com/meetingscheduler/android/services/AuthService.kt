package com.meetingscheduler.android.services

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.Config
import com.meetingscheduler.android.models.Profile
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.Google
import io.github.jan.supabase.auth.providers.builtin.OTP
import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

class AuthService(private val context: Context, private val scope: CoroutineScope) {
    private val supabase = SupabaseService.client

    var currentUser by mutableStateOf<UserInfo?>(null)
        private set
    var currentSession by mutableStateOf<UserSession?>(null)
        private set
    var profile by mutableStateOf<Profile?>(null)
        private set
    var isLoading by mutableStateOf(true)
        private set

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
                currentUser = session?.user
                currentUser?.id?.let { userId ->
                    loadProfile(userId)
                    PurchaseService.instance?.login(userId)
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

    private suspend fun handleAuthChange(status: io.github.jan.supabase.auth.SessionStatus) {
        when (status) {
            is io.github.jan.supabase.auth.SessionStatus.Authenticated -> {
                currentSession = status.session
                currentUser = status.session.user
                currentUser?.id?.let { userId ->
                    loadProfile(userId)
                    PurchaseService.instance?.login(userId)
                }
            }
            is io.github.jan.supabase.auth.SessionStatus.NotAuthenticated -> {
                currentSession = null
                currentUser = null
                profile = null
                PurchaseService.instance?.logout()
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

    suspend fun signInWithGoogle(idToken: String) {
        supabase.auth.signInWith(Google) {
            this.idToken = idToken
        }
    }

    suspend fun authorizeGoogleCalendar(idToken: String, scopes: String): Boolean {
        try {
            supabase.auth.signInWith(Google) {
                this.idToken = idToken
            }

            val session = supabase.auth.currentSessionOrNull()
            val providerToken = session?.accessToken
            val providerRefreshToken = session?.refreshToken

            if (providerToken != null && providerRefreshToken != null) {
                persistCalendarTokens(
                    accessToken = providerToken,
                    refreshToken = providerRefreshToken,
                    userId = session.user?.id ?: return false
                )
                return true
            }
        } catch (e: Exception) {
            println("Google Calendar authorization failed: ${e.message}")
        }
        return false
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

    private suspend fun persistCalendarTokens(
        accessToken: String,
        refreshToken: String,
        userId: String
    ) {
        try {
            val expiresAt = Clock.System.now().plus(kotlinx.datetime.DateTimeUnit.SECOND.times(3600))

            val updates = buildJsonObject {
                put("google_calendar_access_token", accessToken)
                put("google_calendar_refresh_token", refreshToken)
                put("google_calendar_token_expires_at", expiresAt.toString())
                put("calendar_integration_enabled", true)
            }

            supabase
                .from("profiles")
                .update(updates) {
                    filter {
                        eq("id", userId)
                    }
                }

            println("✓ Calendar tokens persisted successfully")
        } catch (e: Exception) {
            println("Failed to persist calendar tokens: ${e.message}")
        }
    }

    sealed class AuthError : Exception() {
        object NotAuthenticated : AuthError()
        data class AppleSignInFailed(override val message: String) : AuthError()
    }

    companion object {
        private var instance: AuthService? = null

        fun getInstance(context: Context, scope: CoroutineScope): AuthService {
            return instance ?: synchronized(this) {
                instance ?: AuthService(context, scope).also { instance = it }
            }
        }
    }
}
