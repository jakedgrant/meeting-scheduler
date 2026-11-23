package com.meetingscheduler.android

import com.meetingscheduler.android.ui.pollShareLink
import org.junit.Assert.assertEquals
import org.junit.Test

class PollSharingTest {
    @Test
    fun sharedLinkCarriesOnlyTheCode() {
        assertEquals("https://meetful.app/join/ABC123", pollShareLink("ABC123"))
        assertEquals("https://meetful.app/join/ABC123", pollShareLink("abc123"))
    }
}
