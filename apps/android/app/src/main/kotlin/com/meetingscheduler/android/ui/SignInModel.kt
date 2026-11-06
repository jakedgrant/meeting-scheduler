package com.meetingscheduler.android.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.FailureLog
import com.meetingscheduler.android.services.SignInAuth
import kotlinx.coroutines.CancellationException
import java.security.MessageDigest
import java.util.UUID

/**
 * Gets a Google ID token through the system credential UI, which needs an Activity. The screen
 * implements it with its Activity and the model uses it for one sign-in only; the model never
 * stores it. [returningAccountsOnly] asks for the one-tap flow over accounts already authorized.
 * Failures arrive as the exceptions below.
 */
fun interface GoogleCredentialSource {
    suspend fun idToken(hashedNonce: String, returningAccountsOnly: Boolean): String
}

/** The person cancelled the credential UI. */
class GoogleCredentialCancelled : Exception()

/** There is no account to offer. */
class GoogleCredentialUnavailable : Exception()

/** The system could not provide a credential. */
class GoogleCredentialFailed(cause: Throwable) : Exception(cause)

/** The system answered with something that is not a Google ID token. [reason] is what the person sees. */
class GoogleCredentialRejected(val reason: String, cause: Throwable? = null) : Exception(reason, cause)

/** A raw nonce for Supabase and its SHA-256 hex digest for the credential request. */
fun generateNonce(): Pair<String, String> {
    val raw = UUID.randomUUID().toString()
    val digest = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())
    return raw to digest.joinToString("") { "%02x".format(it) }
}

/**
 * The sign-in screen's form and sign-in commands. It exists while nobody is signed in, so it is
 * fenced by the auth service's sign-in attempts rather than by an account: a result from an
 * attempt that a later attempt, a sign-out or a new session replaced is not shown. Only the latest
 * request owns [isLoading].
 */
class SignInModel(
    private val auth: SignInAuth,
    private val nonces: () -> Pair<String, String> = ::generateNonce,
) {
    private var uiRequest = 0L

    var email by mutableStateOf("")
        private set
    var isLoading by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set
    var showMagicLinkSent by mutableStateOf(false)
        private set

    /** What the screen shows: its own error, else the one from a failed sign-in link. */
    val displayedError: String? get() = errorMessage ?: auth.callbackError

    fun editEmail(value: String) { email = value }
    fun dismissMagicLinkSent() { showMagicLinkSent = false }

    suspend fun signInWithMagicLink() {
        if (email.isBlank()) {
            errorMessage = "Please enter your email"
            return
        }
        val request = ++uiRequest
        isLoading = true
        errorMessage = null
        try {
            auth.signInWithMagicLink(email)
            if (uiRequest == request) showMagicLinkSent = true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (uiRequest == request) errorMessage = e.message
        } finally {
            if (uiRequest == request) isLoading = false
        }
    }

    suspend fun signInWithGoogleBrowser() {
        val request = ++uiRequest
        isLoading = true
        errorMessage = null
        try {
            auth.signInWithGoogleBrowser()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (uiRequest == request) errorMessage = "Browser sign-in could not be started."
        } finally {
            if (uiRequest == request) isLoading = false
        }
    }

    /** Tries the one-tap flow, then the Sign In With Google button flow, then signs in with the token. */
    suspend fun signInWithGoogle(source: GoogleCredentialSource) {
        val attempt = auth.beginNativeSignIn()
        val request = ++uiRequest
        isLoading = true
        errorMessage = null
        val (rawNonce, hashedNonce) = nonces()
        try {
            val token = try {
                source.idToken(hashedNonce, returningAccountsOnly = true)
            } catch (e: Exception) {
                if (e is CancellationException || e is GoogleCredentialRejected) throw e
                if (!auth.isCurrent(attempt)) throw CancellationException("Authentication attempt changed")
                source.idToken(hashedNonce, returningAccountsOnly = false)
            }
            if (!auth.isCurrent(attempt)) throw CancellationException("Authentication attempt changed")
            try {
                auth.signInWithGoogle(token, rawNonce, attempt)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                FailureLog.record(TAG, "Supabase sign-in failed", e)
                if (auth.isCurrent(attempt)) errorMessage = e.message ?: "Sign-in failed"
            }
        } catch (e: GoogleCredentialCancelled) {
            // The person cancelled; no message.
        } catch (e: GoogleCredentialRejected) {
            FailureLog.record(TAG, "Received an unusable Google credential", e)
            if (auth.isCurrent(attempt)) errorMessage = e.reason
        } catch (e: GoogleCredentialUnavailable) {
            if (auth.isCurrent(attempt)) errorMessage = GOOGLE_UNAVAILABLE
        } catch (e: GoogleCredentialFailed) {
            FailureLog.record(TAG, "Google sign-in failed", e)
            if (auth.isCurrent(attempt)) errorMessage = GOOGLE_UNAVAILABLE
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            FailureLog.record(TAG, "Unexpected error during Google sign-in", e)
            if (auth.isCurrent(attempt)) errorMessage = e.message ?: "Sign-in failed"
        } finally {
            if (uiRequest == request) isLoading = false
        }
    }

    private companion object {
        const val TAG = "SignInModel"
        const val GOOGLE_UNAVAILABLE = "Google sign-in failed. Please ensure you have a Google account on this device."
    }
}
