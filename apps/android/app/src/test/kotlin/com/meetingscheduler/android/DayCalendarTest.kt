package com.meetingscheduler.android

import com.meetingscheduler.android.ui.monthWeeks
import kotlinx.datetime.LocalDate
import org.junit.Assert.*
import org.junit.Test

class DayCalendarTest {
    @Test fun aMonthStartingOnTuesdayIsPaddedWithTwoBlanksAndEndsOnAFullWeek() {
        // December 2026 starts on a Tuesday.
        val weeks = monthWeeks(LocalDate(2026, 12, 17))
        assertEquals(listOf(null, null, LocalDate(2026, 12, 1)), weeks[0].take(3))
        assertEquals(LocalDate(2026, 12, 31), weeks.last().filterNotNull().last())
        assertTrue(weeks.all { it.size == 7 })
        assertEquals(31, weeks.flatten().filterNotNull().size)
    }

    @Test fun aMonthStartingOnSundayHasNoLeadingBlanks() {
        val weeks = monthWeeks(LocalDate(2026, 11, 1))
        assertEquals(LocalDate(2026, 11, 1), weeks[0][0])
        assertEquals(30, weeks.flatten().filterNotNull().size)
    }

    @Test fun februaryInALeapYearHasTwentyNineDays() {
        assertEquals(29, monthWeeks(LocalDate(2028, 2, 10)).flatten().filterNotNull().size)
    }
}
