package com.meetingscheduler.android.ui

import android.view.HapticFeedbackConstants
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.EventBusy
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.QuestionMark
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.models.AvailabilityStatus
import com.meetingscheduler.android.models.CalendarConflict
import com.meetingscheduler.android.models.PollTimeOption
import com.meetingscheduler.android.models.TimeOptionLabels
import kotlinx.datetime.Instant

/** What the viewer's calendars say about one time option. */
sealed interface OptionCalendarStatus {
    data object Free : OptionCalendarStatus
    /** Busy, with the device events behind it; empty when a source doesn't name its events. */
    data class Busy(val events: List<CalendarConflict>) : OptionCalendarStatus
    /** A failed source couldn't cover this option. */
    data object Unchecked : OptionCalendarStatus
}

/** The "Time options" header and the card holding one row per option, divided by hairlines. */
@Composable
fun TimeOptionsCard(options: List<PollTimeOption>, row: @Composable (PollTimeOption) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "Time options",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 4.dp)
        )
        Card(
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLowest)
        ) {
            Column(Modifier.padding(horizontal = 14.dp)) {
                options.forEachIndexed { index, option ->
                    row(option)
                    if (index < options.lastIndex) {
                        HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }
            }
        }
    }
}

/**
 * One time option: its date and time, the viewer's Yes/Maybe/No answer, any calendar conflict,
 * and optionally a tally of everyone's responses.
 */
@Composable
fun TimeOptionRow(
    option: PollTimeOption,
    pollTimeZone: String,
    now: Instant,
    calendarStatus: OptionCalendarStatus,
    responses: ResponseSummary,
    showsResponseTallies: Boolean,
    canRespond: Boolean,
    response: AvailabilityStatus?,
    onResponseChange: (AvailabilityStatus) -> Unit,
    onShowResponses: () -> Unit,
    onShowConflicts: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        val dateAndTime = @Composable { modifier: Modifier ->
            Column(
                modifier
                    .clickable(onClickLabel = "Show everyone's responses", onClick = onShowResponses)
                    .semantics(mergeDescendants = true) {}
            ) {
                Text(
                    TimeOptionLabels.date(option, pollTimeZone, now),
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    if (option.isAllDay) "All day" else TimeOptionLabels.timeRange(option.startTime, option.endTime),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        // At the largest font scales the answer buttons move under the date and grow with the text.
        val fontScale = LocalDensity.current.fontScale
        if (fontScale >= 1.5f) {
            dateAndTime(Modifier.fillMaxWidth())
            if (canRespond) ResponseControl(response, onResponseChange, textScale = fontScale)
        } else {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                dateAndTime(Modifier.weight(1f))
                if (canRespond) ResponseControl(response, onResponseChange)
            }
        }
        when (calendarStatus) {
            OptionCalendarStatus.Free -> Unit
            is OptionCalendarStatus.Busy -> ConflictRow(calendarStatus.events, onShowConflicts)
            OptionCalendarStatus.Unchecked -> Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Filled.HelpOutline, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(6.dp))
                Text("Couldn't check", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (showsResponseTallies) ResponseTallyBar(responses)
    }
}

/**
 * Yes, Maybe and No as one single-selection control. Once answered, an option stays answered.
 * A [textScale] above 1 grows the buttons with the text and has them share the row's width.
 */
@Composable
fun ResponseControl(selection: AvailabilityStatus?, onChange: (AvailabilityStatus) -> Unit, textScale: Float = 1f) {
    val view = LocalView.current
    val scaled = textScale > 1f
    Row(
        modifier = Modifier
            .then(if (scaled) Modifier.fillMaxWidth() else Modifier)
            .selectableGroup()
            .semantics { stateDescription = selection?.answerLabel ?: "No response" },
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        AvailabilityStatus.entries.forEach { status ->
            val selected = selection == status
            val shape = RoundedCornerShape(8.dp)
            Box(
                modifier = Modifier
                    .then(if (scaled) Modifier.weight(1f) else Modifier)
                    .sizeIn(minWidth = 44.dp, minHeight = 36.dp * textScale)
                    .clip(shape)
                    .background(if (selected) status.tint().copy(alpha = 0.15f) else Color.Transparent)
                    .then(if (selected) Modifier else Modifier.border(BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant), shape))
                    .selectable(selected = selected, role = Role.RadioButton) {
                        if (!selected) {
                            view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                            onChange(status)
                        }
                    }
                    .semantics { contentDescription = status.answerLabel },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    status.icon,
                    contentDescription = null,
                    tint = if (selected) status.tint() else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size((if (selected) 18.dp else 16.dp) * textScale)
                )
            }
        }
    }
}

/** The calendar event that overlaps an option. Tapping it shows the conflict details. */
@Composable
private fun ConflictRow(events: List<CalendarConflict>, onShowDetails: () -> Unit) {
    val tint = AvailabilityStatus.MAYBE.tint()
    val description = TimeOptionLabels.conflictDescription(events)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(tint.copy(alpha = 0.15f))
            .clickable(onClick = onShowDetails)
            .clearAndSetSemantics {
                contentDescription = description
                role = Role.Button
                onClick(label = "Show conflict details") { onShowDetails(); true }
            }
            .padding(vertical = 8.dp, horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Icon(Icons.Default.EventBusy, null, Modifier.size(16.dp), tint = tint)
        Text(
            TimeOptionLabels.conflict(events),
            style = MaterialTheme.typography.labelMedium,
            color = tint,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, Modifier.size(14.dp), tint = tint)
    }
}

/** Everyone's answers as green, orange and red segments sized by count. */
@Composable
fun ResponseTallyBar(summary: ResponseSummary) {
    val segments = summary.tallySegments()
    val shape = RoundedCornerShape(2.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(4.dp)
            .clearAndSetSemantics {
                contentDescription = "${summary.available} yes, ${summary.maybe} maybe, ${summary.unavailable} no"
            },
        horizontalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        if (segments.isEmpty()) {
            Box(Modifier.weight(1f).height(4.dp).background(MaterialTheme.colorScheme.outlineVariant, shape))
        } else {
            segments.forEach { (status, count) ->
                Box(Modifier.weight(count.toFloat()).height(4.dp).background(status.tint(), shape))
            }
        }
    }
}

/** The events behind a busy option: title, time and calendar. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CalendarConflictsSheet(option: PollTimeOption, events: List<CalendarConflict>, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text("Calendar conflict", style = MaterialTheme.typography.titleLarge)
            Text(
                if (option.isAllDay) "Proposed time: all day"
                else "Proposed time: ${TimeOptionLabels.timeRange(option.startTime, option.endTime)}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (events.isEmpty()) {
                Text(
                    "Google Calendar says you're busy during this time. It doesn't share which event.",
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            events.forEach { event ->
                Column(Modifier.semantics(mergeDescendants = true) {}) {
                    Text(TimeOptionLabels.eventTitle(event), style = MaterialTheme.typography.titleSmall)
                    Text(TimeOptionLabels.eventTime(event), style = MaterialTheme.typography.bodyMedium)
                    if (event.calendarName.isNotEmpty()) {
                        Text(event.calendarName, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

/** The answer counts as tally segments: yes, maybe, then no, without empty ones. */
fun ResponseSummary.tallySegments(): List<Pair<AvailabilityStatus, Int>> =
    listOf(AvailabilityStatus.AVAILABLE to available, AvailabilityStatus.MAYBE to maybe, AvailabilityStatus.UNAVAILABLE to unavailable)
        .filter { it.second > 0 }

/** "Yes", "Maybe" or "No". */
val AvailabilityStatus.answerLabel: String
    get() = when (this) {
        AvailabilityStatus.AVAILABLE -> "Yes"
        AvailabilityStatus.MAYBE -> "Maybe"
        AvailabilityStatus.UNAVAILABLE -> "No"
    }

private val AvailabilityStatus.icon: ImageVector
    get() = when (this) {
        AvailabilityStatus.AVAILABLE -> Icons.Default.Check
        AvailabilityStatus.MAYBE -> Icons.Default.QuestionMark
        AvailabilityStatus.UNAVAILABLE -> Icons.Default.Close
    }

/** Green, orange and red, lighter in dark mode so the tints keep their contrast. */
@Composable
private fun AvailabilityStatus.tint(): Color {
    val dark = isSystemInDarkTheme()
    return when (this) {
        AvailabilityStatus.AVAILABLE -> if (dark) Color(0xFF81C784) else Color(0xFF2E7D32)
        AvailabilityStatus.MAYBE -> if (dark) Color(0xFFFFB74D) else Color(0xFFE65100)
        AvailabilityStatus.UNAVAILABLE -> if (dark) Color(0xFFE57373) else Color(0xFFC62828)
    }
}
