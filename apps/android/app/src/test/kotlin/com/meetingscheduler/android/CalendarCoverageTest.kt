package com.meetingscheduler.android

import com.meetingscheduler.android.models.CalendarCheck
import com.meetingscheduler.android.models.DeviceBusyPeriod
import com.meetingscheduler.android.models.PollDates
import com.meetingscheduler.android.models.PollTimeOption
import com.meetingscheduler.android.services.CalendarSource
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
import kotlinx.datetime.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** F16 device calendar coverage; see docs/calendar-coverage.md. */
class CalendarCoverageTest {
    private val stamp = Instant.parse("2026-10-23T00:00:00Z")
    private val chicago = TimeZone.of("America/Chicago")

    private fun allDay(id: String, date: String, zone: String) =
        PollDates.allDayOption(LocalDate.parse(date), TimeZone.of(zone)).let { PollTimeOption(id, "poll", it.startTime, it.endTime, isAllDay = true, createdAt = stamp) }

    private fun timed(id: String, date: String, start: String, end: String, zone: TimeZone) =
        PollTimeOption(id, "poll", PollDates.instant(LocalDate.parse(date), LocalTime.parse(start), zone),
            PollDates.instant(LocalDate.parse(date), LocalTime.parse(end), zone), createdAt = stamp)

    /** A CalendarContract all-day instance: UTC midnights from first through end (exclusive). */
    private fun deviceAllDay(first: String, end: String) = DeviceBusyPeriod.of(true,
        Instant.parse("${first}T00:00:00Z"), Instant.parse("${end}T00:00:00Z"), free = false, cancelled = false, declined = false)!!

    @Test fun freeCancelledAndDeclinedEventsAreNotBusy() {
        val begin = Instant.parse("2026-11-02T15:00:00Z"); val end = Instant.parse("2026-11-02T16:00:00Z")
        assertNull(DeviceBusyPeriod.of(false, begin, end, free = true, cancelled = false, declined = false))
        assertNull(DeviceBusyPeriod.of(false, begin, end, free = false, cancelled = true, declined = false))
        assertNull(DeviceBusyPeriod.of(false, begin, end, free = false, cancelled = false, declined = true))
        assertNull(DeviceBusyPeriod.of(true, end, begin, free = false, cancelled = false, declined = false))
        assertEquals(DeviceBusyPeriod.Timed(begin, end), DeviceBusyPeriod.of(false, begin, end, free = false, cancelled = false, declined = false))
        assertEquals(DeviceBusyPeriod.AllDay(LocalDate.parse("2026-11-02"), LocalDate.parse("2026-11-03")), deviceAllDay("2026-11-02", "2026-11-03"))
    }

    @Test fun busyAllDayEventsMatchAllDayOptionsByDateInEveryPollZone() {
        val period = deviceAllDay("2026-11-02", "2026-11-03")
        for (zone in listOf("Pacific/Auckland", "America/Chicago", "America/Santiago", "UTC")) {
            val options = listOf(allDay("before", "2026-11-01", zone), allDay("same", "2026-11-02", zone), allDay("after", "2026-11-03", zone))
            assertEquals(zone, setOf("same"), DeviceBusyPeriod.busyOptionIds(options, zone, listOf(period), chicago))
        }
    }

    @Test fun allDayEventsCoverTheirDatesInTheDeviceZoneForTimedOptions() {
        // A two-date event (Nov 2 and 3) across the Chicago fall-back day, Nov 1.
        val period = deviceAllDay("2026-11-02", "2026-11-04")
        val options = listOf(
            timed("late-before", "2026-11-01", "23:00", "23:59", chicago),
            timed("first-morning", "2026-11-02", "00:00", "01:00", chicago),
            timed("last-night", "2026-11-03", "23:00", "23:59", chicago),
            timed("after", "2026-11-04", "00:00", "01:00", chicago),
            // 08:00 Nov 3 in Auckland is mid-afternoon Nov 2 in Chicago.
            timed("other-zone", "2026-11-03", "08:00", "09:00", TimeZone.of("Pacific/Auckland")),
        )
        assertEquals(setOf("first-morning", "last-night", "other-zone"), DeviceBusyPeriod.busyOptionIds(options, "UTC", listOf(period), chicago))
    }

    @Test fun timedEventsOverlapStoredOptionIntervalsWithExclusiveEnds() {
        val meeting = DeviceBusyPeriod.Timed(Instant.parse("2026-11-02T15:00:00Z"), Instant.parse("2026-11-02T16:00:00Z"))
        val options = listOf(
            timed("touching-before", "2026-11-02", "08:00", "09:00", chicago),
            timed("overlapping", "2026-11-02", "09:30", "10:30", chicago),
            timed("touching-after", "2026-11-02", "10:00", "11:00", chicago),
            allDay("all-day", "2026-11-02", "America/Chicago"),
            allDay("other-date", "2026-11-03", "America/Chicago"),
        )
        assertEquals(setOf("overlapping", "all-day"), DeviceBusyPeriod.busyOptionIds(options, "America/Chicago", listOf(meeting), chicago))
    }

    @Test fun aFailedSourceLeavesEveryNonBusyOptionUnchecked() {
        val ids = setOf("a", "b", "c")
        assertEquals(CalendarCheck(busy = setOf("a"), checkedSources = listOf(CalendarSource.APPLE_CALENDAR, CalendarSource.GOOGLE_CALENDAR)),
            CalendarCheck.combine(ids, listOf(CalendarSource.APPLE_CALENDAR to setOf("a"), CalendarSource.GOOGLE_CALENDAR to setOf("stale-id"))))
        assertEquals(CalendarCheck(busy = setOf("a"), unchecked = setOf("b", "c"), checkedSources = listOf(CalendarSource.APPLE_CALENDAR), failedSources = listOf(CalendarSource.GOOGLE_CALENDAR)),
            CalendarCheck.combine(ids, listOf(CalendarSource.APPLE_CALENDAR to setOf("a"), CalendarSource.GOOGLE_CALENDAR to null)))
        assertEquals(CalendarCheck.NONE, CalendarCheck.combine(ids, emptyList()))
    }
}
