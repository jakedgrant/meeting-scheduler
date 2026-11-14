package com.meetingscheduler.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** Which picker an option row or the range section has open. */
private sealed interface PickerTarget {
    data class OptionDate(val index: Int) : PickerTarget
    data class OptionStart(val index: Int) : PickerTarget
    data class OptionEnd(val index: Int) : PickerTarget
    data object RangeStartDate : PickerTarget
    data object RangeEndDate : PickerTarget
    data object RangeStartTime : PickerTarget
    data object RangeEndTime : PickerTarget
}

@Composable
internal fun TimeOptionsStep(model: PollCreationModel) {
    val draft = model.draft
    val enabled = !model.isSubmitting
    var picker by remember { mutableStateOf<PickerTarget?>(null) }

    Card(
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("All-day events", style = MaterialTheme.typography.bodyLarge)
            Switch(checked = draft.isAllDay, onCheckedChange = { value -> model.edit { it.copy(isAllDay = value) } }, enabled = enabled)
        }
        if (!draft.isAllDay) {
            HorizontalDivider()
            Row(
                Modifier.fillMaxWidth().clickable(enabled = enabled) { model.edit { it.copy(useDateRange = !it.useDateRange) } }
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Add Date Range", style = MaterialTheme.typography.titleMedium)
                Icon(
                    if (draft.useDateRange) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                    if (draft.useDateRange) "Collapse date range" else "Expand date range",
                )
            }
            AnimatedVisibility(draft.useDateRange) {
                Column(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    PickerRow("Starts", draft.rangeStartDate.display(), draft.rangeStartTime.display(), enabled,
                        { picker = PickerTarget.RangeStartDate }, { picker = PickerTarget.RangeStartTime })
                    PickerRow("Ends", draft.rangeEndDate.display(), draft.rangeEndTime.display(), enabled,
                        { picker = PickerTarget.RangeEndDate }, { picker = PickerTarget.RangeEndTime })
                    FilledTonalButton(onClick = model::addRangeOptions, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.Default.Add, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Add Date Range")
                    }
                }
            }
        }
    }

    if (draft.isAllDay) {
        FieldHeading(
            if (draft.selectedDays.isEmpty()) "Pick at least one day"
            else if (draft.selectedDays.size == 1) "1 day" else "${draft.selectedDays.size} days"
        )
        DayCalendar(selected = draft.selectedDays, today = model.today(), enabled = enabled, onToggle = model::toggleDay)
    } else {
        val options = draft.timeOptions
        if (options.isNotEmpty()) FieldHeading(if (options.size == 1) "1 option" else "${options.size} options")
        Card(
            shape = MaterialTheme.shapes.extraLarge,
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        ) {
            options.forEachIndexed { index, option ->
                Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Text("Option ${index + 1}", style = MaterialTheme.typography.titleMedium)
                        IconButton(onClick = { model.removeOption(index) }, enabled = enabled) {
                            Icon(Icons.Default.Delete, "Remove option ${index + 1}")
                        }
                    }
                    // An option ends on the day it starts, so the end date follows the start date and has no picker.
                    PickerRow("Starts", option.date.display(), option.startTime.display(), enabled,
                        { picker = PickerTarget.OptionDate(index) }, { picker = PickerTarget.OptionStart(index) })
                    PickerRow("Ends", option.date.display(), option.endTime.display(), enabled,
                        onDate = null, onTime = { picker = PickerTarget.OptionEnd(index) })
                }
                HorizontalDivider()
            }
            TextButton(
                onClick = model::addOption,
                enabled = enabled,
                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
            ) {
                Icon(Icons.Default.Add, null)
                Spacer(Modifier.width(8.dp))
                Text("Add Time Option")
            }
        }
    }

    when (val target = picker) {
        null -> {}
        is PickerTarget.OptionDate -> draft.timeOptions.getOrNull(target.index)?.let { option ->
            DatePickerDialogFor(option.date, { date -> model.updateOption(target.index) { it.copy(date = date) } }) { picker = null }
        } ?: run { picker = null }
        is PickerTarget.OptionStart -> draft.timeOptions.getOrNull(target.index)?.let { option ->
            TimePickerDialogFor("Select Start Time", option.startTime, { time -> model.updateOption(target.index) { it.copy(startTime = time) } }) { picker = null }
        } ?: run { picker = null }
        is PickerTarget.OptionEnd -> draft.timeOptions.getOrNull(target.index)?.let { option ->
            TimePickerDialogFor("Select End Time", option.endTime, { time -> model.updateOption(target.index) { it.copy(endTime = time) } }) { picker = null }
        } ?: run { picker = null }
        PickerTarget.RangeStartDate -> DatePickerDialogFor(draft.rangeStartDate, { date -> model.edit { it.copy(rangeStartDate = date) } }) { picker = null }
        PickerTarget.RangeEndDate -> DatePickerDialogFor(draft.rangeEndDate, { date -> model.edit { it.copy(rangeEndDate = date) } }) { picker = null }
        PickerTarget.RangeStartTime -> TimePickerDialogFor("Select Start Time", draft.rangeStartTime, { time -> model.edit { it.copy(rangeStartTime = time) } }) { picker = null }
        PickerTarget.RangeEndTime -> TimePickerDialogFor("Select End Time", draft.rangeEndTime, { time -> model.edit { it.copy(rangeEndTime = time) } }) { picker = null }
    }
}

/** A "Starts" or "Ends" line: a date chip and a time chip. A null [onDate] shows the date without a picker. */
@Composable
private fun PickerRow(label: String, date: String, time: String, enabled: Boolean, onDate: (() -> Unit)?, onTime: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(52.dp))
        FilledTonalButton(onClick = { onDate?.invoke() }, enabled = enabled && onDate != null, contentPadding = PaddingValues(horizontal = 12.dp)) { Text(date) }
        FilledTonalButton(onClick = onTime, enabled = enabled, contentPadding = PaddingValues(horizontal = 12.dp)) { Text(time) }
    }
}
