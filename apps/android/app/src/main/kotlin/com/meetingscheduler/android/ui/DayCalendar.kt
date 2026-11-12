package com.meetingscheduler.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.LocalDate
import kotlinx.datetime.daysUntil
import kotlinx.datetime.isoDayNumber
import kotlinx.datetime.plus

/** The weeks of [month]'s calendar grid, Sunday first. A null cell is outside the month. */
fun monthWeeks(month: LocalDate): List<List<LocalDate?>> {
    val first = LocalDate(month.year, month.month, 1)
    val length = first.daysUntil(first.plus(1, DateTimeUnit.MONTH))
    val leading = first.dayOfWeek.isoDayNumber % 7
    val cells: List<LocalDate?> = List(leading) { null } + List(length) { first.plus(it, DateTimeUnit.DAY) }
    return cells.chunked(7).map { week -> week + List(7 - week.size) { null } }
}

/**
 * A month calendar where tapping a day selects it and tapping it again deselects it. Days before
 * [today] can't be newly selected, but one already selected stays tappable so it can be removed.
 */
@Composable
fun DayCalendar(
    selected: Set<LocalDate>,
    today: LocalDate,
    enabled: Boolean,
    onToggle: (LocalDate) -> Unit,
) {
    val thisMonth = LocalDate(today.year, today.month, 1)
    var shown by rememberSaveable { mutableStateOf(thisMonth.toString()) }
    val month = LocalDate.parse(shown)

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(
                onClick = { shown = month.plus(-1, DateTimeUnit.MONTH).toString() },
                enabled = month > thisMonth,
                modifier = Modifier.semantics { contentDescription = "Previous month" },
            ) { Text("‹") }
            Text(
                "${month.month.name.lowercase().replaceFirstChar { it.uppercase() }} ${month.year}",
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.titleMedium,
            )
            TextButton(
                onClick = { shown = month.plus(1, DateTimeUnit.MONTH).toString() },
                modifier = Modifier.semantics { contentDescription = "Next month" },
            ) { Text("›") }
        }
        Row(Modifier.fillMaxWidth()) {
            listOf("S", "M", "T", "W", "T", "F", "S").forEach {
                Text(it, Modifier.weight(1f), textAlign = TextAlign.Center, style = MaterialTheme.typography.labelMedium)
            }
        }
        monthWeeks(month).forEach { week ->
            Row(Modifier.fillMaxWidth()) {
                week.forEach { day ->
                    if (day == null) {
                        Spacer(Modifier.weight(1f).aspectRatio(1f))
                    } else {
                        val isSelected = day in selected
                        val isEnabled = enabled && (day >= today || isSelected)
                        Box(
                            Modifier
                                .weight(1f)
                                .aspectRatio(1f)
                                .padding(2.dp)
                                .clip(CircleShape)
                                .background(if (isSelected) MaterialTheme.colorScheme.primary else androidx.compose.ui.graphics.Color.Transparent)
                                .clickable(enabled = isEnabled) { onToggle(day) }
                                .semantics { contentDescription = if (isSelected) "$day, selected" else "$day" },
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "${day.dayOfMonth}",
                                color = when {
                                    isSelected -> MaterialTheme.colorScheme.onPrimary
                                    isEnabled -> MaterialTheme.colorScheme.onSurface
                                    else -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}
