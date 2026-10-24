package com.meetingscheduler.android.services

import com.russhwolf.settings.Settings
import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Same Settings backing/key/serializer as SDK 3.3.0, without its withContext(IO)
 * gap between credential persistence and SDK status publication. Android Settings
 * uses SharedPreferences.apply (memory update immediately; disk write asynchronous).
 */
class AtomicSessionManager(
    private val key: String,
    private val settings: Settings = Settings(),
) : SessionManager {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    init {
        // Preserve the pinned SDK's migration of its old unqualified session key.
        if (key != "session" && settings.getStringOrNull(key) == null) {
            settings.getStringOrNull("session")?.let { settings.putString(key, it); settings.remove("session") }
        }
    }
    override suspend fun saveSession(session: UserSession) { settings.putString(key, json.encodeToString(session)) }
    override suspend fun loadSession(): UserSession? = settings.getStringOrNull(key)?.let { json.decodeFromString<UserSession>(it) }
    override suspend fun deleteSession() { settings.remove(key) }
}
