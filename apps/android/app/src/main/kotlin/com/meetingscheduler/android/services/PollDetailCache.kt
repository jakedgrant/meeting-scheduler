package com.meetingscheduler.android.services

import com.meetingscheduler.android.models.PollDetail
import com.meetingscheduler.android.models.PollDetailPage
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.time.Clock

/** Complete snapshots only; account namespaces survive process recreation. Storage is best effort. */
class PollDetailCache(
    private val read: (String) -> String?,
    private val write: (String, String?) -> Unit,
    private val clock: Clock,
) {
    @Serializable
    private data class Entry(val syncedAt: Long, val detail: PollDetail)
    @Serializable
    private data class Envelope(val version: Int, val entries: List<Entry>)

    private val loadedAccounts = mutableMapOf<String, List<Entry>>()

    private fun key(accountId: String) = "poll-details-v1:$accountId"

    private fun entries(accountId: String): List<Entry> = loadedAccounts.getOrPut(accountId) {
        try {
            val value = read(key(accountId))
            if (value == null) emptyList() else Json.decodeFromString<Envelope>(value).let {
                if (it.version == 1) it.entries else emptyList()
            }
        } catch (_: Exception) { emptyList() }
    }

    fun detail(accountId: String, pollId: String, freshOnly: Boolean = false): PollDetail? = runCatching {
        val entry = entries(accountId).firstOrNull { it.detail.poll.id == pollId } ?: return null
        val age = clock.now().epochSeconds - entry.syncedAt
        if (freshOnly && age !in 0 until 300) return null
        val detail = entry.detail
        PollDetailPage(detail.poll, detail.timeOptions, detail.participants,
            detail.timeOptions.size, detail.participants.size).apply {
            validate(pollId)
            validateResponses(detail.responses)
        }
        detail
    }.getOrNull()

    fun save(accountId: String, detail: PollDetail) {
        val retained = entries(accountId).filter { it.detail.poll.id != detail.poll.id }.takeLast(19)
        persist(accountId, retained + Entry(clock.now().epochSeconds, detail))
    }

    fun remove(accountId: String, pollId: String) {
        persist(accountId, entries(accountId).filter { it.detail.poll.id != pollId })
    }

    fun clearAccount(accountId: String) {
        loadedAccounts[accountId] = emptyList()
        runCatching { write(key(accountId), null) }
    }

    private fun persist(accountId: String, entries: List<Entry>) {
        // A failed disk write must not bring a revoked or pre-command snapshot back this session.
        loadedAccounts[accountId] = entries
        runCatching { write(key(accountId), Json.encodeToString(Envelope(1, entries))) }
    }

    companion object {
        fun inMemory(clock: Clock = Clock.System): PollDetailCache {
            val values = mutableMapOf<String, String>()
            return PollDetailCache(values::get, { key, value ->
                if (value == null) values.remove(key) else values[key] = value
            }, clock)
        }
    }
}
