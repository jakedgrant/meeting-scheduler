package com.meetingscheduler.android.models

import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.atTime
import kotlinx.datetime.plus
import kotlinx.datetime.toInstant
import kotlinx.datetime.toLocalDateTime
import kotlin.time.Duration.Companion.seconds

class NonexistentLocalTime(date: LocalDate, time: LocalTime, zone: TimeZone) :
    IllegalArgumentException("$date $time is skipped by a clock change in ${zone.id}. Choose another time.")

/**
 * Calendar dates, wall times and instants (F21). See docs/date-time-contract.md.
 * The rules match the web and iOS clients and the shared fixtures.
 */
object PollDates {
    /** Every date from start through end inclusive; empty when end precedes start. */
    fun range(start: LocalDate, end: LocalDate): List<LocalDate> =
        generateSequence(start) { it.plus(1, DateTimeUnit.DAY) }.takeWhile { it <= end }.toList()

    /** A wall time in zone. A skipped time is rejected; a repeated time uses its first occurrence. */
    fun instant(date: LocalDate, time: LocalTime, zone: TimeZone): Instant {
        val local = date.atTime(time)
        // The JVM resolves a repeated time to its earlier offset and moves a skipped time forward.
        val instant = local.toInstant(zone)
        if (instant.toLocalDateTime(zone) != local) throw NonexistentLocalTime(date, time, zone)
        return instant
    }

    fun timedOption(date: LocalDate, start: LocalTime, end: LocalTime, zone: TimeZone): CreationTimeOption {
        require(end > start) { "End time must be after start time for every option." }
        return CreationTimeOption(instant(date, start, zone), instant(date, end, zone), isAllDay = false)
    }

    /** One calendar date: its first instant through the next date's first instant (exclusive). */
    fun allDayOption(date: LocalDate, zone: TimeZone): CreationTimeOption =
        CreationTimeOption(date.atStartOfDayIn(zone), date.plus(1, DateTimeUnit.DAY).atStartOfDayIn(zone), isAllDay = true)

    /** A response due date accepts responses through the end of that date in zone. */
    fun deadline(dueDate: LocalDate, zone: TimeZone): Instant = dueDate.plus(1, DateTimeUnit.DAY).atStartOfDayIn(zone)

    /** The due date a stored deadline represents. */
    fun dueDate(deadline: Instant, zone: TimeZone): LocalDate = (deadline - 1.seconds).toLocalDateTime(zone).date

    /** The calendar date of an all-day option in its poll's zone (legacy 23:59 ends included). */
    fun allDayDate(start: Instant, pollTimeZone: String): LocalDate =
        start.toLocalDateTime(zoneOrUtc(pollTimeZone)).date

    fun zoneOrUtc(id: String): TimeZone = runCatching { TimeZone.of(id) }.getOrDefault(TimeZone.UTC)

    /** A java.util zone for formatting an option's date: the poll zone for all-day options, else the device zone. */
    fun displayZone(isAllDay: Boolean, pollTimeZone: String): java.util.TimeZone =
        if (isAllDay) java.util.TimeZone.getTimeZone(zoneOrUtc(pollTimeZone).id) else java.util.TimeZone.getDefault()
}
