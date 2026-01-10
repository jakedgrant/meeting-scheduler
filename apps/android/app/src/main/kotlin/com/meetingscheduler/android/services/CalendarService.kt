package com.meetingscheduler.android.services

import android.Manifest
import android.content.ContentResolver
import android.content.Context
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
import kotlinx.coroutines.CoroutineScope
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

            googleCalendarEnabled = context.dataStore.data
                .map { it[googleKey] ?: false }
                .firstOrNull() ?: false
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

        syncPreferencesToSupabase()
    }

    suspend fun setGoogleCalendarEnabled(enabled: Boolean) {
        if (enabled) {
            val hasToken = hasGoogleCalendarToken()
            if (hasToken) {
                googleCalendarEnabled = true
                val key = booleanPreferencesKey("googleCalendarEnabled")
                context.dataStore.edit { it[key] = true }
                syncPreferencesToSupabase()
                return
            }

            // No token exists, need to authorize
            // This should trigger OAuth flow in UI
            googleCalendarEnabled = false
            return
        }

        googleCalendarEnabled = false
        val key = booleanPreferencesKey("googleCalendarEnabled")
        context.dataStore.edit { it[key] = false }

        // Clear tokens from Supabase
        try {
            val userId = authService.currentUser?.id ?: return
            val updates = buildJsonObject {
                put("google_calendar_refresh_token", "")
                put("google_calendar_token_expires_at", "")
                put("google_calendar_access_token", "")
            }

            supabase
                .from("profiles")
                .update(updates) {
                    filter {
                        eq("id", userId)
                    }
                }
        } catch (e: Exception) {
            println("Failed to clear calendar tokens: ${e.message}")
        }
    }

    private suspend fun syncPreferencesToSupabase() {
        try {
            val userId = authService.currentUser?.id ?: return
            val updates = buildJsonObject {
                put("calendar_integration_enabled", isEnabled)
            }

            supabase
                .from("profiles")
                .update(updates) {
                    filter {
                        eq("id", userId)
                    }
                }
        } catch (e: Exception) {
            println("Failed to sync calendar preferences: ${e.message}")
        }
    }

    private suspend fun hasGoogleCalendarToken(): Boolean {
        return try {
            val userId = authService.currentUser?.id ?: return false
            val profile = authService.profile
            // Check if profile has google_calendar_refresh_token
            // This would require extending the Profile model
            false
        } catch (e: Exception) {
            false
        }
    }

    // MARK: - Calendar Access

    suspend fun checkConflicts(
        startTime: Instant,
        endTime: Instant,
        sources: List<CalendarSource> = listOf(CalendarSource.APPLE_CALENDAR, CalendarSource.GOOGLE_CALENDAR)
    ): List<CalendarEvent> {
        val conflicts = mutableListOf<CalendarEvent>()

        if (sources.contains(CalendarSource.APPLE_CALENDAR) && appleCalendarEnabled) {
            conflicts.addAll(checkAppleCalendarConflicts(startTime, endTime))
        }

        if (sources.contains(CalendarSource.GOOGLE_CALENDAR) && googleCalendarEnabled) {
            conflicts.addAll(checkGoogleCalendarConflicts(startTime, endTime))
        }

        return conflicts
    }

    private fun checkAppleCalendarConflicts(
        startTime: Instant,
        endTime: Instant
    ): List<CalendarEvent> {
        if (!hasCalendarPermission) return emptyList()

        val events = mutableListOf<CalendarEvent>()
        val contentResolver: ContentResolver = context.contentResolver

        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.AVAILABILITY
        )

        val selection = "(${CalendarContract.Events.DTSTART} < ?) AND (${CalendarContract.Events.DTEND} > ?)"
        val selectionArgs = arrayOf(
            endTime.toEpochMilliseconds().toString(),
            startTime.toEpochMilliseconds().toString()
        )

        val cursor: Cursor? = contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            null
        )

        cursor?.use {
            val idIndex = it.getColumnIndex(CalendarContract.Events._ID)
            val titleIndex = it.getColumnIndex(CalendarContract.Events.TITLE)
            val startIndex = it.getColumnIndex(CalendarContract.Events.DTSTART)
            val endIndex = it.getColumnIndex(CalendarContract.Events.DTEND)
            val allDayIndex = it.getColumnIndex(CalendarContract.Events.ALL_DAY)
            val availabilityIndex = it.getColumnIndex(CalendarContract.Events.AVAILABILITY)

            while (it.moveToNext()) {
                val id = it.getString(idIndex)
                val title = it.getString(titleIndex) ?: "Busy"
                val start = Instant.fromEpochMilliseconds(it.getLong(startIndex))
                val end = Instant.fromEpochMilliseconds(it.getLong(endIndex))
                val allDay = it.getInt(allDayIndex) == 1
                val availability = it.getInt(availabilityIndex)

                // Filter out all-day events and free/transparent events
                if (!allDay && availability == CalendarContract.Events.AVAILABILITY_BUSY) {
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

    private suspend fun checkGoogleCalendarConflicts(
        startTime: Instant,
        endTime: Instant
    ): List<CalendarEvent> {
        // Call Supabase Edge Function to check Google Calendar
        return try {
            // This would call the same edge function as iOS
            // Implementation depends on your edge function setup
            emptyList()
        } catch (e: Exception) {
            println("Failed to check Google Calendar conflicts: ${e.message}")
            emptyList()
        }
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
                instance ?: CalendarService(context, authService, scope).also { instance = it }
            }
        }
    }
}
