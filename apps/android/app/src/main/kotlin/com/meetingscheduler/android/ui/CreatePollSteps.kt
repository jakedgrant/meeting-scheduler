package com.meetingscheduler.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.datetime.*
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private val dateFormat: DateTimeFormatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
private val timeFormat: DateTimeFormatter = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)

internal fun LocalDate.display(): String = dateFormat.format(toJavaLocalDate())
internal fun LocalTime.display(): String = timeFormat.format(toJavaLocalTime())

/** A small, subdued heading above a form field or group. */
@Composable
internal fun FieldHeading(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 8.dp),
    )
}

@Composable
private fun SectionCard(content: @Composable ColumnScope.() -> Unit) {
    Card(
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) { Column(content = content) }
}

@Composable
internal fun DetailsStep(model: PollCreationModel) {
    val draft = model.draft
    val enabled = !model.isSubmitting
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FieldHeading("Title")
        OutlinedTextField(
            value = draft.title,
            onValueChange = { value -> model.edit { it.copy(title = value) } },
            placeholder = { Text("What are you planning?") },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
            singleLine = true,
        )
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FieldHeading("Description (optional)")
        OutlinedTextField(
            value = draft.description,
            onValueChange = { value -> model.edit { it.copy(description = value) } },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
            minLines = 3,
            maxLines = 6,
        )
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FieldHeading("Location (optional)")
        OutlinedTextField(
            value = draft.location,
            onValueChange = { value -> model.edit { it.copy(location = value) } },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
            singleLine = true,
        )
    }
}

@Composable
internal fun DeadlineStep(model: PollCreationModel) {
    val draft = model.draft
    var picking by remember { mutableStateOf(false) }
    SectionCard {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Set response deadline", style = MaterialTheme.typography.bodyLarge)
            Switch(checked = draft.hasDueDate, onCheckedChange = model::setHasDueDate)
        }
    }
    val due = draft.dueDate
    if (draft.hasDueDate && due != null) {
        SectionCard {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text("Deadline", style = MaterialTheme.typography.bodyLarge)
                    FilledTonalButton(onClick = { picking = true }) { Text(due.display()) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val today = model.today()
                    listOf("Tomorrow" to 1, "In 2 days" to 2, "In 1 week" to 7).forEach { (label, days) ->
                        val date = today.plus(days, DateTimeUnit.DAY)
                        FilterChip(
                            selected = due == date,
                            onClick = { model.edit { it.copy(dueDate = date) } },
                            label = { Text(label) },
                        )
                    }
                }
            }
        }
        Text(
            "Responses close at the end of ${due.display()} in your time zone (${model.zoneId()}).",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 8.dp),
        )
        model.firstOptionDate?.let {
            Text(
                "Your first option is on ${it.display()}.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
        }
    }
    if (picking) {
        DatePickerDialogFor(due ?: model.today(), onPick = { date -> model.edit { it.copy(dueDate = date) } }, onDismiss = { picking = false })
    }
}

@Composable
internal fun EventPassStep(model: PollCreationModel) {
    val locked = model.isSubmitting || model.pending != null
    SectionCard {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Use Event Pass", style = MaterialTheme.typography.bodyLarge)
            Switch(
                checked = model.draft.useEventPass,
                onCheckedChange = { value -> model.edit { it.copy(useEventPass = value) } },
                enabled = !locked,
            )
        }
    }
    Text(
        "Uses your oldest eligible pass for a premium poll and keeps your free slot. An active subscription takes priority and keeps your pass.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 8.dp),
    )
    if (model.pending != null) {
        Text(
            "The previous request may have succeeded. Retry this saved poll before changing anything or creating another.",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(horizontal = 8.dp),
        )
    }

    FieldHeading("Review")
    val review = model.review
    val optionLabel = if (review.optionCount == 1) "1 option" else "${review.optionCount} options"
    SectionCard {
        ReviewRow("Title", review.title, enabled = model.canGoBack) { model.goTo(CreationStep.DETAILS) }
        HorizontalDivider()
        ReviewRow("Time options", optionLabel, enabled = model.canGoBack) { model.goTo(CreationStep.TIME_OPTIONS) }
        HorizontalDivider()
        ReviewRow("Deadline", review.deadline?.display() ?: "None", enabled = model.canGoBack) { model.goTo(CreationStep.DEADLINE) }
        HorizontalDivider()
        ReviewRow("Location", review.location ?: "None", enabled = model.canGoBack) { model.goTo(CreationStep.DETAILS) }
    }
}

@Composable
private fun ReviewRow(label: String, value: String, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(horizontal = 20.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyLarge, maxLines = 1, modifier = Modifier.weight(2f, fill = false))
        if (enabled) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DatePickerDialogFor(initial: LocalDate, onPick: (LocalDate) -> Unit, onDismiss: () -> Unit) {
    val state = rememberDatePickerState(initialSelectedDateMillis = initial.atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds())
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let { onPick(Instant.fromEpochMilliseconds(it).toLocalDateTime(TimeZone.UTC).date) }
                onDismiss()
            }) { Text("OK") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    ) { DatePicker(state = state) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TimePickerDialogFor(title: String, initial: LocalTime, onPick: (LocalTime) -> Unit, onDismiss: () -> Unit) {
    val state = rememberTimePickerState(initialHour = initial.hour, initialMinute = initial.minute)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { TimePicker(state = state) },
        confirmButton = {
            TextButton(onClick = { onPick(LocalTime(state.hour, state.minute)); onDismiss() }) { Text("OK") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
