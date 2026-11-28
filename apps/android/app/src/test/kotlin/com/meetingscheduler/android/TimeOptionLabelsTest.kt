package com.meetingscheduler.android

import com.meetingscheduler.android.models.CalendarConflict
import com.meetingscheduler.android.models.PollTimeOption
import com.meetingscheduler.android.models.TimeOptionLabels
import com.meetingscheduler.android.ui.ResponseSummary
import com.meetingscheduler.android.ui.tallySegments
import com.meetingscheduler.android.models.AvailabilityStatus
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toInstant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class TimeOptionLabelsTest {
    private val zone = TimeZone.of("America/Chicago")
    private val locale = Locale.US

    private fun at(month: Int, day: Int, hour: Int, minute: Int = 0, year: Int = 2026): Instant =
        LocalDateTime(year, month, day, hour, minute).toInstant(zone)

    private fun option(start: Instant, end: Instant) =
        PollTimeOption(id = "o", pollId = "p", startTime = start, endTime = end, isAllDay = false, createdAt = start)

    private fun range(start: Instant, end: Instant) = TimeOptionLabels.timeRange(start, end, zone, locale)

    @Test fun dateShowsTheYearOnlyOutsideTheCurrentYear() {
        val now = at(11, 27, 9)
        assertEquals("Tue, Dec 1", TimeOptionLabels.date(option(at(12, 1, 18), at(12, 1, 20)), "UTC", now, zone, locale))
        assertEquals("Tue, Jan 5, 2027",
            TimeOptionLabels.date(option(at(1, 5, 18, year = 2027), at(1, 5, 20, year = 2027)), "UTC", now, zone, locale))
    }

    @Test fun wholeHoursDropTheMinutesAndShareTheDayPeriod() {
        assertEquals("6–8 PM", range(at(12, 1, 18), at(12, 1, 20)))
        assertEquals("11 AM–1 PM", range(at(12, 1, 11), at(12, 1, 13)))
        assertEquals("5:30–7 PM", range(at(12, 1, 17, 30), at(12, 1, 19)))
    }

    @Test fun aRangeAcrossMidnightNamesTheEndDate() {
        assertEquals("11 PM – 1 AM (Dec 2)", range(at(12, 1, 23), at(12, 2, 1)))
        assertEquals("10 PM – 12 AM", range(at(12, 1, 22), at(12, 2, 0)))
    }

    @Test fun conflictNamesTheFirstEventAndCountsTheRest() {
        val rehearsal = CalendarConflict("Kids' winter concert rehearsal", "Family", at(12, 2, 17, 30), at(12, 2, 19), false)
        val dinner = CalendarConflict("Dinner", "Home", at(12, 2, 19), at(12, 2, 20), false)
        assertEquals("Conflicts with Kids' winter concert rehearsal, 5:30–7 PM", TimeOptionLabels.conflict(listOf(rehearsal), zone, locale))
        assertEquals("Conflicts with Kids' winter concert rehearsal and 1 more", TimeOptionLabels.conflict(listOf(rehearsal, dinner), zone, locale))
        assertEquals("Conflicts with an event on your calendar", TimeOptionLabels.conflict(emptyList(), zone, locale))
        assertEquals("Conflict: Kids' winter concert rehearsal, 5:30–7 PM", TimeOptionLabels.conflictDescription(listOf(rehearsal), zone, locale))
    }

    @Test fun tallySegmentsSkipEmptyCountsInOrder() {
        assertEquals(listOf(AvailabilityStatus.AVAILABLE to 3, AvailabilityStatus.UNAVAILABLE to 1),
            ResponseSummary(3, 0, 1).tallySegments())
        assertTrue(ResponseSummary(0, 0, 0).tallySegments().isEmpty())
    }
}
