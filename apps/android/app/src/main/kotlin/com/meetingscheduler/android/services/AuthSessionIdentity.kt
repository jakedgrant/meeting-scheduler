package com.meetingscheduler.android.services

import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.security.MessageDigest
import java.util.Base64

/** A token refresh retains its server session_id; reauthentication gets a new one. */
internal fun authSessionIdentity(session: UserSession?): String? {
    val account = session?.user?.id ?: return null
    val sessionId = runCatching {
        val payload = session.accessToken.split('.')[1]
        Json.parseToJsonElement(String(Base64.getUrlDecoder().decode(payload), Charsets.UTF_8))
            .jsonObject["session_id"]?.jsonPrimitive?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() }
    }.getOrNull()
    val kind = if (sessionId == null) "credential" else "session"
    val value = sessionId ?: session.accessToken
    val hash = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    return "$account:$kind:$hash"
}
