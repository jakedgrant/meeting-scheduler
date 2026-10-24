package com.meetingscheduler.android.services

import com.meetingscheduler.android.models.AvailabilityRecovery
import com.meetingscheduler.android.models.AvailabilitySaveSession
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Account-scoped durable retry envelopes; switching accounts never deletes work. */
class AvailabilityRecoveryStore(
    private val read: (String) -> String?,
    private val write: (String, String) -> Unit,
) {
    private val json = Json { encodeDefaults = true }
    fun open(accountId: String, pollId: String): AvailabilitySaveSession {
        val key = "$accountId:$pollId"
        // Corrupt recovery fails closed rather than replacing a possibly committed save.
        val recovery = read(key)?.let { json.decodeFromString<AvailabilityRecovery>(it) }
        return AvailabilitySaveSession(initial = recovery, persist = { write(key, json.encodeToString(it)) })
    }
}
