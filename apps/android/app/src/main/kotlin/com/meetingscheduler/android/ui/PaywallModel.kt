package com.meetingscheduler.android.ui

import android.app.Activity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.services.AccountScreenAuth
import com.meetingscheduler.android.services.ScreenBilling
import kotlinx.coroutines.CancellationException

/**
 * One account's paywall: the plans on offer, the chosen plan, and the purchase and restore commands.
 * Results that arrive after the account changes are dropped. [billing] is null when the billing
 * service could not start. A purchase takes the Activity for that call only.
 */
class PaywallModel<P : Any>(
    auth: AccountScreenAuth,
    private val billing: ScreenBilling<P>?,
) {
    private val isCurrent = auth.sameAccount()

    var packages by mutableStateOf<List<P>>(emptyList())
        private set
    var selected by mutableStateOf<P?>(null)
        private set
    var isLoading by mutableStateOf(true)
        private set
    var isPurchasing by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set
    /** True once a purchase or restore gives the account access, so the screen can close even if it was recreated meanwhile. */
    var finished by mutableStateOf(false)
        private set

    suspend fun load() {
        billing?.loadOfferings()
        if (!isCurrent()) return
        packages = billing?.packages ?: emptyList()
        isLoading = false
    }

    fun select(pkg: P) {
        selected = pkg
    }

    suspend fun purchase(activity: Activity?) {
        val pkg = selected ?: return
        isPurchasing = true
        errorMessage = null
        try {
            if (activity == null) {
                errorMessage = "Activity context not available"
            } else {
                billing?.purchase(activity, pkg)
                if (isCurrent()) finished = true
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (isCurrent()) errorMessage = e.message
        } finally {
            if (isCurrent()) isPurchasing = false
        }
    }

    suspend fun restore() {
        isPurchasing = true
        errorMessage = null
        try {
            billing?.let {
                it.restorePurchases()
                if (isCurrent()) {
                    if (it.hasProAccess) finished = true else errorMessage = "No purchases to restore"
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (isCurrent()) errorMessage = e.message
        } finally {
            if (isCurrent()) isPurchasing = false
        }
    }
}
