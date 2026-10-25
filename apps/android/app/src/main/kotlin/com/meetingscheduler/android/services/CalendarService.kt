package com.meetingscheduler.android.services

import android.Manifest
import android.app.Application
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.database.Cursor
import android.provider.CalendarContract
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import com.meetingscheduler.android.models.PollTimeOption
import io.github.jan.supabase.functions.functions
import io.ktor.client.statement.bodyAsText
import io.ktor.client.request.setBody
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.datetime.Instant
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

enum class CalendarSource {
    APPLE_CALENDAR,
    GOOGLE_CALENDAR
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "calendar_settings")

/**
 * Process-lifetime calendar state (F13). [context] is the Application, so the service never
 * holds an Activity; [scope] is the application scope.
 */
class CalendarService(
    private val context: Application?,
    private val authService: AuthService,
    private val scope: CoroutineScope,
    private val connectionTransport: (suspend (String, String?) -> String)? = null,
    private val readDevicePreference: (suspend (String) -> Boolean)? = null,
    private val writeDevicePreference: (suspend (String, Boolean) -> Unit)? = null,
    private val readPermission: (() -> Boolean)? = null,
    private val injectedClient: io.github.jan.supabase.SupabaseClient? = null,
    private val readDeviceConflicts: (suspend (List<PollTimeOption>) -> Set<String>)? = null,
) {
    private val supabase by lazy { injectedClient ?: SupabaseService.client }
    private val json = Json { ignoreUnknownKeys = true }
    private var connectionGeneration = 0
    var calendarError by mutableStateOf<String?>(null)
        private set
    var googleCalendarAccountEmail by mutableStateOf<String?>(null)
        private set

    var hasCalendarPermission by mutableStateOf(false)
        private set
    var appleCalendarEnabled by mutableStateOf(false)
        private set
    var googleCalendarEnabled by mutableStateOf(false)
        private set
    var googleCalendarLoading by mutableStateOf(false)
        private set

    val isEnabled: Boolean
        get() = appleCalendarEnabled || googleCalendarEnabled

    init {
        updatePermissionStatus()
        // AppContainer starts account preferences after constructing all services.
    }

    // MARK: - Permission Management

    private fun updatePermissionStatus() {
        readPermission?.let { hasCalendarPermission = it(); return }
        val application = context ?: return
        hasCalendarPermission = ContextCompat.checkSelfPermission(
            application,
            Manifest.permission.READ_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun checkPermission(): Boolean {
        updatePermissionStatus()
        return hasCalendarPermission
    }

    // MARK: - Settings Persistence

    private var preferenceJob: kotlinx.coroutines.Job? = null
    private var refreshJob: kotlinx.coroutines.Job? = null
    fun resetSession() {
        preferenceJob?.cancel()
        refreshJob?.cancel()
        resetGoogleCalendarState()
        appleCalendarEnabled = false
        val id = authService.currentUser?.id ?: return
        val session = authService.identityGeneration
        preferenceJob = scope.launch {
            try {
                val enabled = readDevicePreference?.invoke(id) ?: context?.dataStore?.data?.firstOrNull()?.get(booleanPreferencesKey("appleCalendarEnabled:$id")) ?: false
                if (authService.isCurrent(id, session)) appleCalendarEnabled = enabled && hasCalendarPermission
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (authService.isCurrent(id, session)) calendarError = "Device calendar preferences could not be loaded."
            }
        }
        refreshJob = scope.launch { refreshGoogleCalendarConnection() }
    }

    suspend fun setAppleCalendarEnabled(enabled: Boolean) {
        val id = authService.currentUser?.id ?: return
        val session = authService.identityGeneration
        val allowed = enabled && hasCalendarPermission
        appleCalendarEnabled = allowed
        // Captured account key is intentional: old writes cannot change B's preference.
        try {
            if (writeDevicePreference != null) writeDevicePreference.invoke(id, allowed)
            else context?.dataStore?.edit { it[booleanPreferencesKey("appleCalendarEnabled:$id")] = allowed }
        } catch (error: Exception) {
            if (!authService.isCurrent(id, session)) throw CancellationException("Account changed")
            throw error
        }
    }

    fun resetGoogleCalendarState() {
        connectionGeneration++
        googleCalendarEnabled = false
        googleCalendarLoading = false
        calendarError = null
        googleCalendarAccountEmail = null
    }

    private suspend fun invokeOwned(function: String, body: kotlinx.serialization.json.JsonObject, credential: String): io.ktor.client.statement.HttpResponse =
        supabase.functions.invoke(function) {
            // The SDK's body+Headers overload appends Authorization; use assignment
            // after its default auth header to guarantee exactly one captured token.
            headers[io.ktor.http.HttpHeaders.Authorization] = "Bearer $credential"
            contentType(io.ktor.http.ContentType.Application.Json)
            setBody(body.toString())
        }

    private data class RequestOwner(val id: String, val session: Long, val generation: Int, val credential: String)
    private fun captureOwner(): RequestOwner? {
        val id = authService.currentUser?.id ?: return null
        val credential = authService.currentSession?.accessToken ?: return null
        return RequestOwner(id, authService.identityGeneration, connectionGeneration, credential)
    }
    private fun isCurrent(owner: RequestOwner) = authService.isCurrent(owner.id, owner.session) && owner.generation == connectionGeneration
    private suspend fun connection(owner: RequestOwner, action: String, target: String? = null): String {
        if (!isCurrent(owner)) throw CancellationException("Account changed before calendar dispatch")
        connectionTransport?.let { return it(action, target) }
        val credential = owner.credential
        val response = invokeOwned("calendar-connection", buildJsonObject {
            put("action", action)
            target?.let { put("target", it) }
        }, credential)
        if (!response.status.isSuccess()) throw IllegalStateException("Calendar request failed")
        return response.bodyAsText()
    }

    suspend fun refreshGoogleCalendarConnection() {
        if (googleCalendarLoading) return
        val userId = authService.currentUser?.id ?: run { resetGoogleCalendarState(); return }
        val session = authService.identityGeneration
        val generation = connectionGeneration
        val owner = captureOwner() ?: return
        try {
            val status = json.decodeFromString<ConnectionStatus>(connection(owner, "status"))
            if (!authService.isCurrent(userId, session) || generation != connectionGeneration) return
            googleCalendarEnabled = status.connected
            googleCalendarAccountEmail = status.accountEmail
            calendarError = when {
                status.revocationPending -> "Disconnected. Google access revocation is being retried."
                status.requiresReconnect -> "Reconnect Google Calendar in Settings."
                else -> null
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (!authService.isCurrent(userId, session) || generation != connectionGeneration) return
            googleCalendarEnabled = false
            googleCalendarAccountEmail = null
            calendarError = "Google Calendar connection could not be checked."
        }
    }

    suspend fun setGoogleCalendarEnabled(enabled: Boolean) {
        val userId = authService.currentUser?.id ?: return
        connectionGeneration++
        val session = authService.identityGeneration
        val generation = connectionGeneration
        val owner = captureOwner() ?: return
        googleCalendarLoading = true
        calendarError = null
        try {
            if (!enabled) {
                val status = json.decodeFromString<ConnectionStatus>(connection(owner, "disconnect"))
                if (!authService.isCurrent(userId, session) || generation != connectionGeneration) return
                googleCalendarEnabled = status.connected
                googleCalendarAccountEmail = status.accountEmail
                if (status.revocationPending) calendarError = "Disconnected. Google access revocation is being retried."
                return
            }
            val status = json.decodeFromString<ConnectionStatus>(connection(owner, "status"))
            if (!authService.isCurrent(userId, session) || generation != connectionGeneration) return
            googleCalendarEnabled = status.connected
            googleCalendarAccountEmail = status.accountEmail
            if (googleCalendarEnabled) return
            val start = json.decodeFromString<AuthorizationStart>(connection(owner, "start", "android"))
            if (!authService.isCurrent(userId, session) || generation != connectionGeneration) return
            val uri = Uri.parse(start.authorizationURL)
            if (uri.scheme != "https" || uri.host != "accounts.google.com" || uri.path != "/o/oauth2/v2/auth") {
                throw IllegalStateException("Invalid calendar authorization URL")
            }
            context?.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (authService.isCurrent(userId, session) && generation == connectionGeneration) {
                calendarError = "Google Calendar could not be updated. Try again."
            }
        } finally {
            if (authService.isCurrent(userId, session) && generation == connectionGeneration) googleCalendarLoading = false
        }
    }

    /** One bounded backend call for all options; no provider tokens reach Android. */
    suspend fun checkPollConflicts(options: List<PollTimeOption>): Set<String> {
        if (options.isEmpty()) return emptySet()
        val owner = captureOwner() ?: return emptySet()
        val userId = owner.id
        val session = owner.session
        val generation = owner.generation
        val deviceEnabled = appleCalendarEnabled
        val googleEnabled = googleCalendarEnabled
        calendarError = null
        val conflicts = mutableSetOf<String>()
        if (deviceEnabled) {
            try {
                val device = readDeviceConflicts?.invoke(options) ?: withContext(Dispatchers.IO) {
                    options.filter { checkAppleCalendarConflicts(it.startTime, it.endTime).isNotEmpty() }.map { it.id }.toSet()
                }
                if (!isCurrent(owner)) return emptySet()
                conflicts.addAll(device)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (authService.isCurrent(userId, session) && generation == connectionGeneration) {
                    calendarError = "Device calendar conflicts could not be checked."
                }
            }
        }
        if (!isCurrent(owner)) return emptySet()
        if (googleEnabled) {
            try {
                val credential = owner.credential
                val response = invokeOwned("check-calendar-conflicts", buildJsonObject {
                    put("timeOptions", kotlinx.serialization.json.buildJsonArray {
                        options.forEach { option ->
                            add(buildJsonObject {
                                put("id", option.id)
                                put("start_time", option.startTime.toString())
                                put("end_time", option.endTime.toString())
                            })
                        }
                    })
                }, credential)
                if (!response.status.isSuccess()) throw IllegalStateException("Calendar coverage unknown")
                val result = json.decodeFromString<ConflictResponse>(response.bodyAsText())
                if (!result.success) throw IllegalStateException("Calendar coverage unknown")
                if (!authService.isCurrent(userId, session) || generation != connectionGeneration) return emptySet()
                conflicts.addAll(result.conflictingIds)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (authService.isCurrent(userId, session) && generation == connectionGeneration) {
                    calendarError = "Google Calendar could not be checked. Review your availability before saving."
                }
            }
        }
        return if (authService.isCurrent(userId, session) && generation == connectionGeneration) conflicts else emptySet()
    }

    private fun checkAppleCalendarConflicts(
        startTime: Instant,
        endTime: Instant
    ): List<CalendarEvent> {
        if (!hasCalendarPermission) return emptyList()

        val events = mutableListOf<CalendarEvent>()
        val contentResolver: ContentResolver = context?.contentResolver ?: return emptyList()

        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.AVAILABILITY,
            CalendarContract.Events.STATUS,
            CalendarContract.Events.SELF_ATTENDEE_STATUS
        )

        val cursor: Cursor? = CalendarContract.Instances.query(
            contentResolver, projection, startTime.toEpochMilliseconds(), endTime.toEpochMilliseconds()
        )

        cursor?.use {
            val idIndex = it.getColumnIndex(CalendarContract.Instances.EVENT_ID)
            val titleIndex = it.getColumnIndex(CalendarContract.Events.TITLE)
            val startIndex = it.getColumnIndex(CalendarContract.Instances.BEGIN)
            val endIndex = it.getColumnIndex(CalendarContract.Instances.END)
            val availabilityIndex = it.getColumnIndex(CalendarContract.Events.AVAILABILITY)
            val statusIndex = it.getColumnIndex(CalendarContract.Events.STATUS)
            val attendeeIndex = it.getColumnIndex(CalendarContract.Events.SELF_ATTENDEE_STATUS)

            while (it.moveToNext()) {
                val id = it.getString(idIndex)
                val title = it.getString(titleIndex) ?: "Busy"
                val start = Instant.fromEpochMilliseconds(it.getLong(startIndex))
                val end = Instant.fromEpochMilliseconds(it.getLong(endIndex))
                val availability = it.getInt(availabilityIndex)

                if (availability != CalendarContract.Events.AVAILABILITY_FREE &&
                    it.getInt(statusIndex) != CalendarContract.Events.STATUS_CANCELED &&
                    it.getInt(attendeeIndex) != CalendarContract.Attendees.ATTENDEE_STATUS_DECLINED) {
                    events.add(
                        CalendarEvent(
                            id = id,
                            title = title,
                            startTime = start,
                            endTime = end,
                            source = CalendarSource.APPLE_CALENDAR
                        )
                    )
                }
            }
        }

        return events
    }

    data class CalendarEvent(
        val id: String,
        val title: String,
        val startTime: Instant,
        val endTime: Instant,
        val source: CalendarSource
    )
}

@Serializable
private data class ConnectionStatus(val connected: Boolean, val accountEmail: String?,
    val requiresReconnect: Boolean, val revocationPending: Boolean)
@Serializable
private data class AuthorizationStart(val authorizationURL: String)
@Serializable
private data class ConflictResponse(val success: Boolean, val conflictingIds: List<String>)
