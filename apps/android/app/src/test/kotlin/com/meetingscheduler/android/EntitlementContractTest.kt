package com.meetingscheduler.android

import com.meetingscheduler.android.models.Poll
import com.meetingscheduler.android.models.PollCreationEntitlement
import com.meetingscheduler.android.models.PollCreationEntitlement.*
import kotlinx.datetime.Instant
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** F23: plan ids and limits match packages/shared-config/entitlements.json. */
class EntitlementContractTest {
    private val fixture: JsonObject = run {
        // Gradle runs unit tests from the module directory; walk up to the repository root.
        var directory: File? = File("").absoluteFile
        while (directory != null && !File(directory, "packages/shared-config/entitlements.json").exists()) directory = directory.parentFile
        Json.parseToJsonElement(File(directory!!, "packages/shared-config/entitlements.json").readText()).jsonObject
    }

    private fun limits(tier: JsonObject) = tier.getValue("limits").jsonObject
    private fun JsonObject.int(key: String) = get(key)?.jsonPrimitive?.int

    /** The fixture tier that describes [entitlement]. The server calls the free tier `free`. */
    private fun tier(entitlement: PollCreationEntitlement): JsonObject = when (entitlement) {
        FREE -> fixture.getValue("free_tier").jsonObject
        PRO, TEAM -> fixture.getValue("entitlements").jsonObject.getValue(entitlement.id).jsonObject
        EVENT_PASS -> fixture.getValue(entitlement.id).jsonObject
    }

    @Test fun everyPaidTierInTheFixtureHasAnEntitlement() {
        assertEquals(setOf(PRO.id, TEAM.id), fixture.getValue("entitlements").jsonObject.keys)
    }

    @Test fun participantLimitsMatchTheFixture() {
        for (entitlement in PollCreationEntitlement.entries) {
            assertEquals(entitlement.name, limits(tier(entitlement)).int("max_participants_per_poll"), entitlement.participantLimit)
        }
    }

    @Test fun unlimitedActivePollsMatchTheFixture() {
        for (entitlement in PollCreationEntitlement.entries) {
            // -1 means unlimited; an event pass funds one poll and has no count.
            val unlimited = limits(tier(entitlement)).int("max_active_polls") == -1
            assertEquals(entitlement.name, unlimited, entitlement.allowsUnlimitedActivePolls)
        }
    }

    @Test fun idsAreTheSerializedNames() {
        for (entitlement in PollCreationEntitlement.entries) {
            assertEquals(JsonPrimitive(entitlement.id), Json.encodeToJsonElement(PollCreationEntitlement.serializer(), entitlement))
        }
        assertEquals(listOf("free", "pro_access", "team_access", "event_pass"), PollCreationEntitlement.entries.map { it.id })
    }

    @Test fun defaultPollCapacityIsTheFreeLimit() {
        val stamp = Instant.parse("2026-11-03T00:00:00Z")
        assertEquals(limits(tier(FREE)).int("max_participants_per_poll"), Poll("p", "A", "Poll", createdAt = stamp, updatedAt = stamp).maxParticipants)
    }
}
