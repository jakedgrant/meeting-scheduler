package com.meetingscheduler.android.services

import android.app.Activity
import com.meetingscheduler.android.models.Profile

/**
 * What the settings and profile screens read from and ask of the auth service. `AuthService`
 * implements it. [isCurrent] is how a model checks that the account it was made for is still
 * the signed-in one before it publishes a result.
 */
interface AccountScreenAuth {
    val identityGeneration: Long
    val accountId: String?
    val accountEmail: String?
    val profile: Profile?
    fun isCurrent(id: String?, generation: Long): Boolean
    suspend fun signOut()
    suspend fun updateProfile(displayName: String?, avatarUrl: String?, timezone: String?)
}

/**
 * What the sign-in screen asks of the auth service. `AuthService` implements it. The screen
 * runs while nobody is signed in, so its attempts are fenced by [NativeSignInAttempt] instead
 * of by an account.
 */
interface SignInAuth {
    val callbackError: String?
    fun beginNativeSignIn(): NativeSignInAttempt
    fun isCurrent(attempt: NativeSignInAttempt): Boolean
    suspend fun signInWithGoogle(idToken: String, nonce: String? = null, attempt: NativeSignInAttempt = beginNativeSignIn())
    suspend fun signInWithMagicLink(email: String)
    suspend fun signInWithGoogleBrowser()
}

/**
 * The billing state and commands the settings and paywall screens use. `PurchaseService`
 * implements it with RevenueCat's `Package` as [P]; tests use a plain type. [purchase] takes
 * the Activity as an argument for the one call and keeps no reference to it.
 */
interface ScreenBilling<P : Any> {
    val hasProAccess: Boolean
    /** The plans of the loaded offering; empty before [loadOfferings] finishes or when there are none. */
    val packages: List<P>
    suspend fun loadOfferings()
    suspend fun purchase(activity: Activity, pkg: P)
    suspend fun restorePurchases()
}

/** The calendar state the settings screen shows and the commands it runs. `CalendarService` implements it. */
interface SettingsCalendar {
    val calendarError: String?
    val googleCalendarAccountEmail: String?
    val hasCalendarPermission: Boolean
    val appleCalendarEnabled: Boolean
    val googleCalendarEnabled: Boolean
    val googleCalendarLoading: Boolean
    suspend fun setAppleCalendarEnabled(enabled: Boolean)
    suspend fun setGoogleCalendarEnabled(enabled: Boolean)
}
