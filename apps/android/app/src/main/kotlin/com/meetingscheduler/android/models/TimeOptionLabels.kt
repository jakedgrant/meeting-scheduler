package com.meetingscheduler.android.models

import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toJavaLocalDate
import kotlinx.datetime.toJavaLocalDateTime
import kotlinx.datetime.toLocalDateTime
import java.time.format.DateTimeFormatter
import kotlin.time.Duration.Companion.seconds
import java.util.Locale

/** The text a time option row shows for its date, its time range and its calendar conflict. */
object TimeOptionLabels {
    /** "Tue, Dec 1", with the year only when the option is not in the current year. */
    fun date(
        option: PollTimeOption,
        pollTimeZone: String,
        now: Instant,
        zone: TimeZone = TimeZone.currentSystemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String {
        val date = if (option.isAllDay) PollDates.allDayDate(option.startTime, pollTimeZone)
            else option.startTime.toLocalDateTime(zone).date
        val pattern = if (date.year == now.toLocalDateTime(zone).year) "EEE, MMM d" else "EEE, MMM d, yyyy"
        return DateTimeFormatter.ofPattern(pattern, locale).format(date.toJavaLocalDate())
    }

    /**
     * "6–8 PM": each end drops ":00", and both ends share AM/PM when they match. A range that ends
     * on a later day names it: "11 PM – 1 AM (Dec 2)". An end at the following midnight belongs to
     * the start's day.
     */
    fun timeRange(
        start: Instant,
        end: Instant,
        zone: TimeZone = TimeZone.currentSystemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String {
        val from = start.toLocalDateTime(zone)
        val to = end.toLocalDateTime(zone)
        fun time(value: LocalDateTime, period: Boolean): String {
            val pattern = (if (value.minute == 0) "h" else "h:mm") + if (period) " a" else ""
            return DateTimeFormatter.ofPattern(pattern, locale).format(value.toJavaLocalDateTime())
        }
        if (from.date != to.date) {
            val range = "${time(from, true)} – ${time(to, true)}"
            val lastDay = (end - 1.seconds).toLocalDateTime(zone).date
            if (lastDay == from.date) return range
            return "$range (${DateTimeFormatter.ofPattern("MMM d", locale).format(to.date.toJavaLocalDate())})"
        }
        val sharesPeriod = (from.hour < 12) == (to.hour < 12)
        return "${time(from, !sharesPeriod)}–${time(to, true)}"
    }

    /** The conflict line under an option, or a generic one when no event is known, as for Google Calendar. */
    fun conflict(events: List<CalendarConflict>, zone: TimeZone = TimeZone.currentSystemDefault(), locale: Locale = Locale.getDefault()): String {
        val first = events.firstOrNull() ?: return "Conflicts with an event on your calendar"
        if (events.size > 1) return "Conflicts with ${eventTitle(first)} and ${events.size - 1} more"
        return "Conflicts with ${eventTitle(first)}, ${eventTime(first, zone, locale)}"
    }

    /** "Conflict: Design review, 5:30–7 PM" for TalkBack. */
    fun conflictDescription(events: List<CalendarConflict>, zone: TimeZone = TimeZone.currentSystemDefault(), locale: Locale = Locale.getDefault()): String {
        val first = events.firstOrNull() ?: return "Conflict: an event on your calendar"
        return "Conflict: ${eventTitle(first)}, ${eventTime(first, zone, locale)}"
    }

    fun eventTitle(event: CalendarConflict): String = event.title.ifEmpty { "Untitled event" }

    fun eventTime(event: CalendarConflict, zone: TimeZone = TimeZone.currentSystemDefault(), locale: Locale = Locale.getDefault()): String =
        if (event.isAllDay) "All day" else timeRange(event.start, event.end, zone, locale)
}
