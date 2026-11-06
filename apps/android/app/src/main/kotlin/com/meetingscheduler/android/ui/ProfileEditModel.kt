package com.meetingscheduler.android.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.services.AccountScreenAuth
import kotlinx.coroutines.CancellationException

/**
 * One account's profile form. It starts from the profile the account has when the form opens and
 * keeps the edits until the form is left. A save result that arrives after the account changes is dropped.
 */
class ProfileEditModel(private val auth: AccountScreenAuth) {
    private val isCurrent = auth.sameAccount()

    var displayName by mutableStateOf(auth.profile?.displayName ?: "")
        private set
    var avatarUrl by mutableStateOf(auth.profile?.avatarUrl ?: "")
        private set
    var timezone by mutableStateOf(auth.profile?.timezone ?: "UTC")
        private set
    var isSaving by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set
    /** True after a save succeeds, until the person acknowledges it. */
    var saved by mutableStateOf(false)
        private set

    fun editDisplayName(value: String) { displayName = value }
    fun editAvatarUrl(value: String) { avatarUrl = value }
    fun editTimezone(value: String) { timezone = value }
    fun acknowledgeSaved() { saved = false }

    suspend fun save() {
        isSaving = true
        errorMessage = null
        try {
            auth.updateProfile(
                displayName = displayName.ifBlank { null },
                avatarUrl = avatarUrl.ifBlank { null },
                timezone = timezone,
            )
            if (isCurrent()) saved = true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (isCurrent()) errorMessage = "Failed to update profile: ${e.message}"
        } finally {
            if (isCurrent()) isSaving = false
        }
    }
}
