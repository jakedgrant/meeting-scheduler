package com.meetingscheduler.android.services

import android.Manifest
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

class CalendarService(
    private val context: Context,
    private val authService: AuthService,
    private val scope: CoroutineScope
) {
    private val supabase = SupabaseService.client
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
        loadPreferences()
    }

    // MARK: - Permission Management

    private fun updatePermissionStatus() {
        hasCalendarPermission = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun checkPermission(): Boolean {
        updatePermissionStatus()
        return hasCalendarPermission
    }

    // MARK: - Settings Persistence

    private fun loadPreferences() {
        scope.launch {
            val appleKey = booleanPreferencesKey("appleCalendarEnabled")
            val googleKey = booleanPreferencesKey("googleCalendarEnabled")

            appleCalendarEnabled = context.dataStore.data
                .map { it[appleKey] ?: false }
                .firstOrNull() ?: false

            context.dataStore.edit { it.remove(googleKey) }
        }
    }

    suspend fun setAppleCalendarEnabled(enabled: Boolean) {
        if (enabled && !hasCalendarPermission) {
            appleCalendarEnabled = false
            return
        }

        appleCalendarEnabled = enabled
        val key = booleanPreferencesKey("appleCalendarEnabled")
        context.dataStore.edit { it[key] = enabled }

    }

    fun resetGoogleCalendarState() {
        connectionGeneration++
        googleCalendarEnabled = false
        googleCalendarLoading = false
        calendarError = null
        googleCalendarAccountEmail = null
    }

    private suspend fun connection(action: String, target: String? = null): String {
        val response = supabase.functions.invoke("calendar-connection", body = buildJsonObject {
            put("action", action)
            target?.let { put("target", it) }
        })
        if (!response.status.isSuccess()) throw IllegalStateException("Calendar request failed")
        return response.bodyAsText()
    }

    suspend fun refreshGoogleCalendarConnection() {
        if (googleCalendarLoading) return
        val userId = authService.currentUser?.id ?: run { resetGoogleCalendarState(); return }
        val generation = connectionGeneration
        try {
            val status = json.decodeFromString<ConnectionStatus>(connection("status"))
            if (authService.currentUser?.id != userId || generation != connectionGeneration) return
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
            if (authService.currentUser?.id != userId || generation != connectionGeneration) return
            googleCalendarEnabled = false
            googleCalendarAccountEmail = null
            calendarError = "Google Calendar connection could not be checked."
        }
    }

    suspend fun setGoogleCalendarEnabled(enabled: Boolean) {
        val userId = authService.currentUser?.id ?: return
        connectionGeneration++
        val generation = connectionGeneration
        googleCalendarLoading = true
        calendarError = null
        try {
            if (!enabled) {
                val status = json.decodeFromString<ConnectionStatus>(connection("disconnect"))
                if (authService.currentUser?.id != userId || generation != connectionGeneration) return
                googleCalendarEnabled = status.connected
                googleCalendarAccountEmail = status.accountEmail
                if (status.revocationPending) calendarError = "Disconnected. Google access revocation is being retried."
                return
            }
            val status = json.decodeFromString<ConnectionStatus>(connection("status"))
            if (authService.currentUser?.id != userId || generation != connectionGeneration) return
            googleCalendarEnabled = status.connected
            googleCalendarAccountEmail = status.accountEmail
            if (googleCalendarEnabled) return
            val start = json.decodeFromString<AuthorizationStart>(connection("start", "android"))
            if (authService.currentUser?.id != userId || generation != connectionGeneration) return
            val uri = Uri.parse(start.authorizationURL)
            if (uri.scheme != "https" || uri.host != "accounts.google.com" || uri.path != "/o/oauth2/v2/auth") {
                throw IllegalStateException("Invalid calendar authorization URL")
            }
            context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (authService.currentUser?.id == userId && generation == connectionGeneration) {
                calendarError = "Google Calendar could not be updated. Try again."
            }
        } finally {
            if (generation == connectionGeneration) googleCalendarLoading = false
        }
    }

    /** One bounded backend call for all options; no provider tokens reach Android. */
    suspend fun checkPollConflicts(options: List<PollTimeOption>): Set<String> {
        if (options.isEmpty()) return emptySet()
        val userId = authService.currentUser?.id
        val generation = connectionGeneration
        calendarError = null
        val conflicts = mutableSetOf<String>()
        if (appleCalendarEnabled) {
            try {
                conflicts.addAll(withContext(Dispatchers.IO) {
                    options.filter { checkAppleCalendarConflicts(it.startTime, it.endTime).isNotEmpty() }.map { it.id }
                })
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (authService.currentUser?.id == userId && generation == connectionGeneration) {
                    calendarError = "Device calendar conflicts could not be checked."
                }
            }
        }
        if (googleCalendarEnabled) {
            try {
                val response = supabase.functions.invoke("check-calendar-conflicts", body = buildJsonObject {
                    put("timeOptions", kotlinx.serialization.json.buildJsonArray {
                        options.forEach { option ->
                            add(buildJsonObject {
                                put("id", option.id)
                                put("start_time", option.startTime.toString())
                                put("end_time", option.endTime.toString())
                            })
                        }
                    })
                })
                if (!response.status.isSuccess()) throw IllegalStateException("Calendar coverage unknown")
                val result = json.decodeFromString<ConflictResponse>(response.bodyAsText())
                if (!result.success) throw IllegalStateException("Calendar coverage unknown")
                if (authService.currentUser?.id != userId || generation != connectionGeneration) return emptySet()
                conflicts.addAll(result.conflictingIds)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (authService.currentUser?.id == userId && generation == connectionGeneration) {
                    calendarError = "Google Calendar could not be checked. Review your availability before saving."
                }
            }
        }
        return if (authService.currentUser?.id == userId && generation == connectionGeneration) conflicts else emptySet()
    }

    private fun checkAppleCalendarConflicts(
        startTime: Instant,
        endTime: Instant
    ): List<CalendarEvent> {
        if (!hasCalendarPermission) return emptyList()

        val events = mutableListOf<CalendarEvent>()
        val contentResolver: ContentResolver = context.contentResolver

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

    companion object {
        private var instance: CalendarService? = null

        fun getInstance(
            context: Context,
            authService: AuthService,
            scope: CoroutineScope
        ): CalendarService {
            return instance ?: synchronized(this) {
                instance ?: CalendarService(context.applicationContext, authService, scope).also { instance = it }
            }
        }
    }
}

@Serializable
private data class ConnectionStatus(val connected: Boolean, val accountEmail: String?,
    val requiresReconnect: Boolean, val revocationPending: Boolean)
@Serializable
private data class AuthorizationStart(val authorizationURL: String)
@Serializable
private data class ConflictResponse(val success: Boolean, val conflictingIds: List<String>)
