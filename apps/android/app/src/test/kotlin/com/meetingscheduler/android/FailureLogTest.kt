package com.meetingscheduler.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class FailureLogTest {
    @Test
    fun summaryNamesTheFailureWithoutItsMessage() {
        val error = IllegalStateException("https://project.example.test/rest/v1/polls?token=secret-token")

        val summary = FailureLog.summary("Failed to load poll", error)

        assertEquals("Failed to load poll: java.lang.IllegalStateException", summary)
        assertFalse(summary.contains("secret-token"))
    }

    @Test
    fun recordRunsInJvmTestsWhereFailurePathsReachIt() {
        FailureLog.record("FailureLogTest", "Failed to load poll", IllegalStateException("secret-token"))
    }
}
