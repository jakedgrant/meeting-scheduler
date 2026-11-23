package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import kotlinx.datetime.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class PollEditDraftTest {
    private val now = Instant.parse("2026-11-05T12:00:00Z")
    private val original = Poll("poll", "owner", "Planning", description = "Agenda", location = "Room",
        timezone = "America/Chicago", closesAt = Instant.parse("2020-01-01T00:00:00.123456Z"), createdAt = now, updatedAt = now)

    @Test fun unchangedPastDeadlineIsOmittedWhileOptionalFieldsCanBeCleared() {
        val draft = PollEditDraft.from(original, now)
        assertFalse(draft.hasChanges)
        val edited = draft.copy(title = " Updated ", description = "", location = "")
        assertTrue(edited.hasChanges)
        assertNull(edited.validationError(now))
        val changes = edited.changes(now)
        assertEquals(setOf("title", "description", "location"), changes.keys)
        assertEquals("Updated", changes["title"]?.jsonPrimitive?.content)
        assertEquals(JsonNull, changes["description"])
        assertEquals(JsonNull, changes["location"])
    }

    @Test fun deadlineResolvesInPollZoneRejectsSkippedTimesAndCanBeRemoved() {
        val draft = PollEditDraft.from(original, now).copy(deadlineDate = LocalDate(2027, 3, 14), deadlineTime = LocalTime(2, 30))
        assertNotNull(draft.validationError(now))
        val repeated = draft.copy(deadlineDate = LocalDate(2027, 11, 7), deadlineTime = LocalTime(1, 30))
        assertEquals("2027-11-07T06:30:00Z", repeated.changes(now)["closes_at"]?.jsonPrimitive?.content)
        assertEquals(JsonNull, draft.copy(hasDeadline = false).changes(now)["closes_at"])
        assertNotNull(draft.copy(deadlineDate = LocalDate(2020, 1, 1)).validationError(now))
    }

    @Test fun serverFieldLimitsAreValidatedBeforeDispatch() {
        val draft = PollEditDraft.from(original, now)
        for (edited in listOf(draft.copy(title = " "), draft.copy(title = "a".repeat(201)),
            draft.copy(description = "a".repeat(10_001)), draft.copy(location = "a".repeat(1_001)))) {
            assertNotNull(edited.validationError(now))
        }
        assertNull(draft.copy(title = "a".repeat(200), description = "a".repeat(10_000), location = "a".repeat(1_000)).validationError(now))
    }
}
