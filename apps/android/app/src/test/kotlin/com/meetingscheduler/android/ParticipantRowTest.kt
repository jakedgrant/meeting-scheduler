package com.meetingscheduler.android

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.models.AvailabilitySnapshot
import com.meetingscheduler.android.models.PollParticipant
import com.meetingscheduler.android.ui.ParticipantRow
import com.meetingscheduler.android.ui.ParticipantsHeading
import com.meetingscheduler.android.ui.theme.MeetingSchedulerTheme
import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class, qualifiers = "en-rUS-w393dp-h852dp")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ParticipantRowTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()
    private val stamp = Instant.parse("2026-11-24T02:22:00Z")
    private val participant = PollParticipant("member", "poll", anonymousName = "Jordan Lee",
        accessToken = "member", comment = "I can join after lunch.", createdAt = stamp, updatedAt = stamp,
        submittedAt = stamp)
    private val people = listOf(participant,
        participant.copy(id = "guest", anonymousName = "Guest", comment = null, submittedAt = null),
        participant.copy(id = "pending", anonymousName = "Alexandria Montgomery Wellington", comment = null, submittedAt = null))

    private fun show(participants: List<PollParticipant>, fontScale: Float = 1f) {
        rule.setContent {
            MeetingSchedulerTheme {
                CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                    LazyColumn(contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        item { ParticipantsHeading(participants) }
                        items(participants) {
                            ParticipantRow(it, it.id == "member")
                            HorizontalDivider()
                        }
                    }
                }
            }
        }
    }

    private fun screenshot(name: String) {
        val directory = System.getenv("PARTICIPANT_SCREENSHOT_DIR") ?: return
        val target = File(directory, name)
        target.parentFile?.mkdirs()
        val bitmap = rule.runOnIdle {
            val view = rule.activity.window.decorView
            Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
        }
        target.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Test fun submittedAndPendingParticipantsHaveDistinctLabelsAndAnAggregateCount() {
        show(people)
        rule.onNodeWithText("1 of 3 submitted").assertExists()
        rule.onAllNodesWithText("Not submitted").assertCountEquals(2)
        rule.onNodeWithText("Submitted", substring = true).assertExists()
        rule.onNodeWithText("I can join after lunch.").assertExists()
        screenshot("android-participants.png")
    }

    @Test fun submissionLabelsRemainVisibleAtLargeFontScale() {
        show(people, fontScale = 2f)
        rule.onNodeWithText("1 of 3 submitted").assertExists()
        rule.onNodeWithText("Submitted", substring = true).assertExists()
        screenshot("android-participants-large-text.png")
    }

    @Test fun optionalSubmissionTimestampDecodesHistoricalAndCurrentPayloads() {
        val json = Json { ignoreUnknownKeys = true }
        val historical = """{"id":"member","poll_id":"poll","access_token":"member","anonymous_name":"Guest","created_at":"2026-11-24T02:22:00Z","updated_at":"2026-11-24T02:22:00Z"}"""
        assertNull(json.decodeFromString<PollParticipant>(historical).submittedAt)
        val current = historical.dropLast(1) + """, "submitted_at":"2026-11-24T02:22:00Z"}"""
        assertEquals(stamp, json.decodeFromString<PollParticipant>(current).submittedAt)
        val snapshot = """{"participant_id":"member","poll_id":"poll","version":1,"responses":[],"submitted_at":"2026-11-24T02:22:00Z"}"""
        assertEquals(stamp, json.decodeFromString<AvailabilitySnapshot>(snapshot).submittedAt)
        assertNull(json.decodeFromString<AvailabilitySnapshot>(snapshot.replace("\"2026-11-24T02:22:00Z\"", "null")).submittedAt)
    }
}
