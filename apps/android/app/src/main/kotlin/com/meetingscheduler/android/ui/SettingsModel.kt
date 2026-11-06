package com.meetingscheduler.android.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.FailureLog
import com.meetingscheduler.android.services.AccountScreenAuth
import com.meetingscheduler.android.services.ScreenBilling
import com.meetingscheduler.android.services.SettingsCalendar
import kotlinx.coroutines.CancellationException

/**
 * One account's settings screen: what it shows about the account, the plan and the calendars,
 * and the commands behind its buttons. Results that arrive after the account changes are dropped.
 *
 * [billing] is null when the billing service could not start.
 */
class SettingsModel(
    private val auth: AccountScreenAuth,
    private val billing: ScreenBilling<*>?,
    val calendar: SettingsCalendar,
) {
    private val isCurrent = auth.sameAccount()

    var isSigningOut by mutableStateOf(false)
        private set

    val displayName: String get() = auth.profile?.displayName ?: auth.accountEmail ?: "User"
    val email: String get() = auth.accountEmail ?: ""
    val avatarUrl: String? get() = auth.profile?.avatarUrl
    val hasProAccess: Boolean get() = billing?.hasProAccess == true

    /** The first letters of the first two words of [displayName], or its first two characters. */
    val initials: String
        get() {
            val words = displayName.split(" ")
            return if (words.size >= 2) {
                (words[0].firstOrNull()?.toString() ?: "") + (words[1].firstOrNull()?.toString() ?: "")
            } else {
                displayName.take(2)
            }.uppercase()
        }

    suspend fun restorePurchases() {
        try {
            billing?.restorePurchases()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            FailureLog.record("SettingsView", "Restore failed", e)
        }
    }

    /** Turns the device calendar on or off; [requestPermission] runs instead when it is turned on without permission. */
    suspend fun toggleDeviceCalendar(enabled: Boolean, requestPermission: () -> Unit) {
        if (enabled && !calendar.hasCalendarPermission) requestPermission()
        else calendar.setAppleCalendarEnabled(enabled)
    }

    suspend fun deviceCalendarPermissionResult(granted: Boolean) {
        if (granted) calendar.setAppleCalendarEnabled(true)
    }

    suspend fun setGoogleCalendar(enabled: Boolean) = calendar.setGoogleCalendarEnabled(enabled)

    suspend fun signOut() {
        isSigningOut = true
        try {
            auth.signOut()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (isCurrent()) FailureLog.record("SettingsView", "Sign out failed", e)
        } finally {
            if (isCurrent()) isSigningOut = false
        }
    }
}
