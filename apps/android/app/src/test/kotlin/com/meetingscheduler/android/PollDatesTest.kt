package com.meetingscheduler.android

import com.meetingscheduler.android.models.*
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
import kotlinx.datetime.TimeZone
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** F21: PollDates and creation encoding match packages/shared-config/date-time-fixtures.json. */
class PollDatesTest {
    private val fixtures: JsonObject = run {
        // Gradle runs unit tests from the module directory; walk up to the repository root.
        var directory: File? = File("").absoluteFile
        while (directory != null && !File(directory, "packages/shared-config/date-time-fixtures.json").exists()) directory = directory.parentFile
        Json.parseToJsonElement(File(directory!!, "packages/shared-config/date-time-fixtures.json").readText()).jsonObject
    }

    private fun cases(key: String) = fixtures.getValue(key).jsonArray.map { it.jsonObject }
    private fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.content
    private fun JsonObject.optional(key: String) = get(key)?.jsonPrimitive?.contentOrNull
    private fun zone(case: JsonObject) = TimeZone.of(case.text("zone"))

    @Test
    fun dateRangesContainEachCalendarDateOnce() {
        for (c in cases("date_ranges")) {
            val expected = c.getValue("dates").jsonArray.map { it.jsonPrimitive.content }
            assertEquals(c.text("name"), expected, PollDates.range(LocalDate.parse(c.text("start")), LocalDate.parse(c.text("end"))).map { it.toString() })
        }
    }

    @Test
    fun timedOptionsRejectGapsAndUseFirstRepeatedTime() {
        for (c in cases("timed_options")) {
            val name = c.text("name")
            val build = { PollDates.timedOption(LocalDate.parse(c.text("date")), LocalTime.parse(c.text("start")), LocalTime.parse(c.text("end")), zone(c)) }
            when (c.optional("error")) {
                null -> {
                    val option = build()
                    assertEquals(name, Instant.parse(c.text("start_time")), option.startTime)
                    assertEquals(name, Instant.parse(c.text("end_time")), option.endTime)
                    assertFalse(option.isAllDay)
                }
                "nonexistent_local_time" -> assertThrows(name, NonexistentLocalTime::class.java) { build() }
                "end_not_after_start" -> assertTrue(name, runCatching { build() }.exceptionOrNull()?.message?.contains("after start") == true)
                else -> fail(name)
            }
        }
    }

    @Test
    fun allDayOptionsUseExclusiveNextDayStart() {
        for (c in cases("all_day_options")) {
            val option = PollDates.allDayOption(LocalDate.parse(c.text("date")), zone(c))
            assertEquals(c.text("name"), Instant.parse(c.text("start_time")), option.startTime)
            assertEquals(c.text("name"), Instant.parse(c.text("end_time")), option.endTime)
            assertTrue(option.isAllDay)
        }
    }

    @Test
    fun deadlinesCoverTheWholeDueDateAndRestoreToIt() {
        for (c in cases("deadlines")) {
            val deadline = PollDates.deadline(LocalDate.parse(c.text("date")), zone(c))
            assertEquals(c.text("name"), Instant.parse(c.text("closes_at")), deadline)
            assertEquals(c.text("name"), LocalDate.parse(c.text("date")), PollDates.dueDate(deadline, zone(c)))
        }
    }

    @Test
    fun allDayDatesAreFormattedInThePollZoneForEveryViewer() {
        val original = java.util.TimeZone.getDefault()
        try {
            for (viewer in listOf("Pacific/Honolulu", "Pacific/Kiritimati", "America/Chicago", "UTC")) {
                java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone(viewer))
                for (c in cases("option_dates")) {
                    val start = Instant.parse(c.text("start_time"))
                    assertEquals(c.text("name"), LocalDate.parse(c.text("date")), PollDates.allDayDate(start, c.text("zone")))
                    val format = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = PollDates.displayZone(true, c.text("zone")) }
                    assertEquals("${c.text("name")} for $viewer", c.text("date"), format.format(Date(start.toEpochMilliseconds())))
                }
            }
        } finally {
            java.util.TimeZone.setDefault(original)
        }
    }

    @Test
    fun payloadEncodesCanonicalInstants() {
        val zone = TimeZone.of("America/Chicago")
        val date = LocalDate.parse("2026-11-01")
        val payload = PollCreationPayload("Dates", timezone = zone.id, closesAt = PollDates.deadline(date, zone),
            timeOptions = listOf(PollDates.allDayOption(date, zone)))
        val json = Json.parseToJsonElement(Json { encodeDefaults = true }.encodeToString(payload)).jsonObject
        val option = json.getValue("time_options").jsonArray[0].jsonObject
        assertEquals("2026-11-01T05:00:00Z", option.text("start_time"))
        assertEquals("2026-11-02T06:00:00Z", option.text("end_time"))
        assertEquals("2026-11-02T06:00:00Z", json.text("closes_at"))
        assertEquals(true, option.getValue("is_all_day").jsonPrimitive.boolean)
    }
}
