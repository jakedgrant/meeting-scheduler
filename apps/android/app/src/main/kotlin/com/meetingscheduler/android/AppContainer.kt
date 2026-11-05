package com.meetingscheduler.android

import android.app.Application
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService
import com.meetingscheduler.android.services.AUTH_REDIRECT_URL
import com.meetingscheduler.android.services.AtomicSessionManager
import com.meetingscheduler.android.services.SupabaseAuthGateway
import com.meetingscheduler.android.ui.PollScreenEnvironment
import com.meetingscheduler.android.ui.SharedPreferencesCreationStore
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.FlowType
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlin.time.Clock

/**
 * Process-lifetime dependencies (F13). Owned by [MeetingSchedulerApplication], created once
 * per process, and shared by every Activity instance. Services receive only the Application
 * and [applicationScope], never an Activity or its lifecycle scope, so Activity recreation
 * neither cancels their work nor leaks the destroyed Activity.
 *
 * This is the only place the Supabase client is built (F23): [createAppSupabaseClient] is
 * private to this file. Each service takes the client as a constructor argument, so tests pass
 * their own rather than reaching a process-wide one.
 */
class AppContainer(
    application: Application,
    val applicationScope: CoroutineScope,
) {
    val purchaseService: PurchaseService? = try {
        PurchaseService(application, applicationScope)
    } catch (e: Exception) {
        FailureLog.record("AppContainer", "Failed to initialize PurchaseService", e)
        null
    }

    /** The one clock the services and screen models read. */
    val clock: Clock = Clock.System

    /** Internal so instrumented tests can drive the SDK session the services observe. */
    internal val supabase = createAppSupabaseClient()

    private val authAttemptPreferences = application.getSharedPreferences("auth_attempt_v1", 0)
    val authService = AuthService(applicationScope, billingIdentity = purchaseService,
        gateway = SupabaseAuthGateway(supabase),
        clock = clock,
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

    val pollService = PollService(authService, supabase)

    val calendarService = CalendarService(application, authService, applicationScope, supabase)

    private val creationPreferences = application.getSharedPreferences("poll_creation_v1", 0)
    val pollScreens = PollScreenEnvironment(
        clock = clock,
        creationStore = { accountId -> SharedPreferencesCreationStore(creationPreferences, accountId) },
    )

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

/**
 * Private so the container stays the only caller. A second client would share the persisted
 * session key but keep its own in-memory session and refresh job, splitting the one SDK
 * session that auth isolation relies on.
 */
private fun createAppSupabaseClient(): SupabaseClient = createSupabaseClient(
    supabaseUrl = Config.SUPABASE_URL,
    supabaseKey = Config.SUPABASE_ANON_KEY
) {
    install(Auth) {
        sessionManager = AtomicSessionManager("sb-${Config.SUPABASE_URL.removeSuffix("/").replace('/', '-').replace('.', '-')}-session")
        // SDK refresh jobs and application-owned installs share Main confinement.
        coroutineDispatcher = Dispatchers.Main.immediate
        scheme = "meetingscheduler"
        host = "auth"
        defaultRedirectUrl = AUTH_REDIRECT_URL
        flowType = FlowType.PKCE
    }
    install(Postgrest)
    install(Realtime)
    install(Functions)
}
