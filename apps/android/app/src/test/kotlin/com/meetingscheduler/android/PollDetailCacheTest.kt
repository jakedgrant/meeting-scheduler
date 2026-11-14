package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.PollDetailCache
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds

class PollDetailCacheTest {
    private val stamp = Instant.parse("2026-11-12T12:00:00Z")
    private var now = stamp
    private val clock = object : Clock { override fun now() = this@PollDetailCacheTest.now }
    private val values = mutableMapOf<String, String>()
    private fun cache() = PollDetailCache(values::get, { key, value ->
        if (value == null) values.remove(key) else values[key] = value
    }, clock)
    private val detail = PollDetail(Poll("poll", "A", "Persisted", createdAt = stamp, updatedAt = stamp),
        listOf(PollTimeOption("slot", "poll", stamp, stamp, createdAt = stamp)), emptyList(), emptyList())

    @Test fun completeSnapshotSurvivesCacheRecreationAndStaleSnapshotsRemainReadable() {
        cache().save("A", detail)
        assertEquals(detail, cache().detail("A", "poll", freshOnly = true))
        now += 300.seconds
        assertNull(cache().detail("A", "poll", freshOnly = true))
        assertEquals(detail, cache().detail("A", "poll"))
        assertNull(cache().detail("B", "poll"))
        cache().remove("A", "poll")
        assertNull(cache().detail("A", "poll"))
    }

    @Test fun corruptUnknownVersionAndForeignCollectionsAreIgnored() {
        values["poll-details-v1:A"] = "not JSON"
        assertNull(cache().detail("A", "poll"))
        values["poll-details-v1:A"] = """{"version":2,"entries":[]}"""
        assertNull(cache().detail("A", "poll"))
        cache().save("A", detail.copy(timeOptions = detail.timeOptions.map { it.copy(pollId = "foreign") }))
        assertNull(cache().detail("A", "poll"))
        cache().save("A", detail)
        assertEquals(detail, cache().detail("A", "poll"))
    }

    @Test fun storageFailuresDoNotPreventReadsOrUndoInvalidation() {
        val unavailable = PollDetailCache({ error("disk unavailable") }, { _, _ -> error("disk full") }, clock)
        unavailable.save("A", detail)
        assertEquals(detail, unavailable.detail("A", "poll"))
        unavailable.remove("A", "poll")
        assertNull(unavailable.detail("A", "poll"))
        unavailable.save("A", detail)
        unavailable.clearAccount("A")
        assertNull(unavailable.detail("A", "poll"))
    }
}
