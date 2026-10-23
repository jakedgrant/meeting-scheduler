package com.meetingscheduler.android

import android.app.Application
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob

/**
 * Process-lifetime dependencies (F13). Owned by [MeetingSchedulerApplication], created once
 * per process, and shared by every Activity instance. Services receive only the Application
 * and [applicationScope], never an Activity or its lifecycle scope, so Activity recreation
 * neither cancels their work nor leaks the destroyed Activity.
 */
class AppContainer(
    application: Application,
    val applicationScope: CoroutineScope,
) {
    val purchaseService: PurchaseService? = try {
        PurchaseService(application, applicationScope)
    } catch (e: Exception) {
        println("Failed to initialize PurchaseService: ${e.message}")
        null
    }

    val authService = AuthService(applicationScope, billingIdentity = purchaseService)

    val pollService = PollService(authService)

    val calendarService = CalendarService(application, authService, applicationScope)
}

/**
 * Scope for work that must outlive any single screen or Activity: the auth session listener,
 * initial billing and calendar loads. A [SupervisorJob] keeps one failed child from cancelling
 * the others. Nothing cancels this scope; it ends with the process.
 */
fun createApplicationScope(dispatcher: CoroutineDispatcher): CoroutineScope =
    CoroutineScope(SupervisorJob() + dispatcher)
