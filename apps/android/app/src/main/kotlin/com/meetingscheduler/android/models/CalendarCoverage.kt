package com.meetingscheduler.android.models

import com.meetingscheduler.android.services.CalendarSource
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.toLocalDateTime

/**
 * The outcome of one calendar check across the enabled sources (F16).
 * See docs/calendar-coverage.md. A null source result means it could not be checked.
 */
data class CalendarCheck(
    /** Options a checked source reports as busy. */
    val busy: Set<String> = emptySet(),
    /** Options that are not busy but that a failed source could not cover. */
    val unchecked: Set<String> = emptySet(),
    val checkedSources: List<CalendarSource> = emptyList(),
    val failedSources: List<CalendarSource> = emptyList(),
) {
    companion object {
        val NONE = CalendarCheck()

        fun combine(optionIds: Set<String>, sources: List<Pair<CalendarSource, Set<String>?>>): CalendarCheck {
            val busy = sources.mapNotNull { it.second }.flatten().toSet() intersect optionIds
            val failed = sources.filter { it.second == null }.map { it.first }
            return CalendarCheck(
                busy = busy,
                unchecked = if (failed.isEmpty()) emptySet() else optionIds - busy,
                checkedSources = sources.filter { it.second != null }.map { it.first },
                failedSources = failed,
            )
        }
    }
}

/** A period a device calendar event makes busy. */
sealed interface DeviceBusyPeriod {
    data class Timed(val start: Instant, val end: Instant) : DeviceBusyPeriod
    /** An all-day event from its first date to its end date (exclusive), floating in the device zone. */
    data class AllDay(val first: LocalDate, val end: LocalDate) : DeviceBusyPeriod

    companion object {
        /**
         * The busy period of a CalendarContract instance, or null when it does not count as busy.
         * Free, cancelled and declined events never count. All-day instances store UTC midnights.
         */
        fun of(allDay: Boolean, begin: Instant, end: Instant, free: Boolean, cancelled: Boolean, declined: Boolean): DeviceBusyPeriod? {
            if (end <= begin || free || cancelled || declined) return null
            if (!allDay) return Timed(begin, end)
            return AllDay(begin.toLocalDateTime(TimeZone.UTC).date, end.toLocalDateTime(TimeZone.UTC).date)
        }

        /**
         * Option IDs that overlap any busy period. All-day options and all-day events compare dates;
         * otherwise an all-day event covers its dates in the device zone and an all-day option covers
         * its stored interval.
         */
        fun busyOptionIds(options: List<PollTimeOption>, pollTimeZone: String, periods: List<DeviceBusyPeriod>, deviceZone: TimeZone): Set<String> =
            options.filter { option ->
                periods.any { period ->
                    when (period) {
                        is AllDay -> if (option.isAllDay) {
                            PollDates.allDayDate(option.startTime, pollTimeZone).let { it >= period.first && it < period.end }
                        } else {
                            period.first.atStartOfDayIn(deviceZone) < option.endTime && period.end.atStartOfDayIn(deviceZone) > option.startTime
                        }
                        is Timed -> period.start < option.endTime && period.end > option.startTime
                    }
                }
            }.map { it.id }.toSet()
    }
}
