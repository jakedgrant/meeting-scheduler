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

    private val authAttemptPreferences = application.getSharedPreferences("auth_attempt_v1", 0)
    val authService = AuthService(applicationScope, billingIdentity = purchaseService,
        attempts = object : com.meetingscheduler.android.services.AuthAttemptStore {
            override fun read(): com.meetingscheduler.android.services.PendingAuthAttempt? =
                authAttemptPreferences.getString("pending", null)?.let {
                    runCatching { kotlinx.serialization.json.Json.decodeFromString<com.meetingscheduler.android.services.PendingAuthAttempt>(it) }.getOrNull()
                }
            override fun write(attempt: com.meetingscheduler.android.services.PendingAuthAttempt?) {
                val edit = authAttemptPreferences.edit()
                if (attempt == null) edit.remove("pending")
                else edit.putString("pending", kotlinx.serialization.json.Json.encodeToString(com.meetingscheduler.android.services.PendingAuthAttempt.serializer(), attempt))
                check(edit.commit()) { "Sign-in could not be saved. Try again." }
            }
        })

    val pollService = PollService(authService)

    val calendarService = CalendarService(application, authService, applicationScope)

    init {
        val recovery = application.getSharedPreferences("availability_recovery_v1", 0)
        pollService.availabilityRecovery = com.meetingscheduler.android.services.AvailabilityRecoveryStore(
            read = { recovery.getString(it, null) },
            write = { key, value -> check(recovery.edit().putString(key, value).commit()) { "Your response could not be saved for retry." } },
        )
        authService.onBoundary {
            pollService.resetSession()
            calendarService.resetSession()
        }
        // Auth restoration may have completed synchronously before registration.
        pollService.resetSession()
        calendarService.resetSession()
    }
}

/**
 * Scope for work that must outlive any single screen or Activity: the auth session listener,
 * initial billing and calendar loads. A [SupervisorJob] keeps one failed child from cancelling
 * the others. Nothing cancels this scope; it ends with the process.
 */
fun createApplicationScope(dispatcher: CoroutineDispatcher): CoroutineScope =
    CoroutineScope(SupervisorJob() + dispatcher)
