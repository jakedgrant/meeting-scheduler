package com.meetingscheduler.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.PollService
import kotlinx.datetime.*

@Composable
fun CreatePollView(pollService: PollService, screens: PollScreenEnvironment, onDismiss: () -> Unit) {
    key(pollService.creationAccountKey) { CreationForm(pollService, screens, onDismiss) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CreationForm(
    pollService: PollService,
    screens: PollScreenEnvironment,
    onDismiss: () -> Unit
) {
    // The holder lives in the navigation entry's store, which is nested in the session store. The
    // draft and an in-flight creation outlast the Activity; popping the entry cancels them, and
    // reopening the form builds a fresh model.
    val holder = pollCreationHolder(
        polls = pollService,
        store = { screens.creationStore(pollService.creationAccountId) },
        clock = screens.clock,
    )
    val model = holder.opened.getOrElse {
        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Your saved creation could not be read. Check your poll list before starting another poll.")
            TextButton(onClick = onDismiss) { Text("Close") }
        }
        return
    }
    val draft = model.draft
    val isLoading = model.isSubmitting
    val timeOptions = draft.timeOptions

    // Picker dialog state for time options
    var showDatePicker by remember { mutableStateOf(false) }
    var showStartTimePicker by remember { mutableStateOf(false) }
    var showEndTimePicker by remember { mutableStateOf(false) }
    var editingOptionIndex by remember { mutableStateOf(-1) }

    // Picker dialog state for date range
    var showRangeStartDatePicker by remember { mutableStateOf(false) }
    var showRangeEndDatePicker by remember { mutableStateOf(false) }
    var showRangeStartTimePicker by remember { mutableStateOf(false) }
    var showRangeEndTimePicker by remember { mutableStateOf(false) }

    // Picker dialog state for due date
    var showDueDatePicker by remember { mutableStateOf(false) }

    // Dismiss once the creation succeeded, including when it finished while the Activity was recreated.
    LaunchedEffect(model.created) { if (model.created) onDismiss() }

    fun submitCreation() {
        holder.launch { submit() }
    }

    model.pending?.let { pending ->
        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Confirm your saved creation", style = MaterialTheme.typography.headlineSmall)
            Text(pending.payload.title)
            Text("The previous request may have succeeded. Retry this saved operation before editing or creating another poll.")
            model.errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(onClick = { submitCreation() }, enabled = !isLoading) { Text(if (isLoading) "Checking…" else "Retry saved creation") }
            TextButton(onClick = onDismiss, enabled = !isLoading) { Text("Close") }
        }
        return
    }

    // Date picker dialog
    if (showDatePicker && editingOptionIndex >= 0 && editingOptionIndex < timeOptions.size) {
        val option = timeOptions[editingOptionIndex]
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = option.date.atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds()
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val newDate = Instant.fromEpochMilliseconds(millis)
                            .toLocalDateTime(TimeZone.UTC).date
                        model.updateOption(editingOptionIndex) { it.copy(date = newDate) }
                    }
                    showDatePicker = false
                }) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) {
                    Text("Cancel")
                }
            }
        ) {
            DatePicker(state = datePickerState)
        }
    }

    // Start time picker dialog
    if (showStartTimePicker && editingOptionIndex >= 0 && editingOptionIndex < timeOptions.size) {
        val option = timeOptions[editingOptionIndex]
        val timePickerState = rememberTimePickerState(
            initialHour = option.startTime.hour,
            initialMinute = option.startTime.minute
        )
        AlertDialog(
            onDismissRequest = { showStartTimePicker = false },
            title = { Text("Select Start Time") },
            text = { TimePicker(state = timePickerState) },
            confirmButton = {
                TextButton(onClick = {
                    val newTime = LocalTime(timePickerState.hour, timePickerState.minute)
                    model.updateOption(editingOptionIndex) { it.copy(startTime = newTime) }
                    showStartTimePicker = false
                }) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = { showStartTimePicker = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    // End time picker dialog
    if (showEndTimePicker && editingOptionIndex >= 0 && editingOptionIndex < timeOptions.size) {
        val option = timeOptions[editingOptionIndex]
        val timePickerState = rememberTimePickerState(
            initialHour = option.endTime.hour,
            initialMinute = option.endTime.minute
        )
        AlertDialog(
            onDismissRequest = { showEndTimePicker = false },
            title = { Text("Select End Time") },
            text = { TimePicker(state = timePickerState) },
            confirmButton = {
                TextButton(onClick = {
                    val newTime = LocalTime(timePickerState.hour, timePickerState.minute)
                    model.updateOption(editingOptionIndex) { it.copy(endTime = newTime) }
                    showEndTimePicker = false
                }) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = { showEndTimePicker = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    // Date range start date picker
    if (showRangeStartDatePicker) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = draft.rangeStartDate.atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds()
        )
        DatePickerDialog(
            onDismissRequest = { showRangeStartDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val date = Instant.fromEpochMilliseconds(millis).toLocalDateTime(TimeZone.UTC).date
                        model.edit { it.copy(rangeStartDate = date) }
                    }
                    showRangeStartDatePicker = false
                }) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = { showRangeStartDatePicker = false }) {
                    Text("Cancel")
                }
            }
        ) {
            DatePicker(state = datePickerState)
        }
    }

    // Date range end date picker
    if (showRangeEndDatePicker) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = draft.rangeEndDate.atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds()
        )
        DatePickerDialog(
            onDismissRequest = { showRangeEndDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val date = Instant.fromEpochMilliseconds(millis).toLocalDateTime(TimeZone.UTC).date
                        model.edit { it.copy(rangeEndDate = date) }
                    }
                    showRangeEndDatePicker = false
                }) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = { showRangeEndDatePicker = false }) {
                    Text("Cancel")
                }
            }
        ) {
            DatePicker(state = datePickerState)
        }
    }

    // Date range start time picker
    if (showRangeStartTimePicker) {
        val timePickerState = rememberTimePickerState(
            initialHour = draft.rangeStartTime.hour,
            initialMinute = draft.rangeStartTime.minute
        )
        AlertDialog(
            onDismissRequest = { showRangeStartTimePicker = false },
            title = { Text("Select Start Time") },
            text = { TimePicker(state = timePickerState) },
            confirmButton = {
                TextButton(onClick = {
                    val time = LocalTime(timePickerState.hour, timePickerState.minute)
                    model.edit { it.copy(rangeStartTime = time) }
                    showRangeStartTimePicker = false
                }) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = { showRangeStartTimePicker = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    // Date range end time picker
    if (showRangeEndTimePicker) {
        val timePickerState = rememberTimePickerState(
            initialHour = draft.rangeEndTime.hour,
            initialMinute = draft.rangeEndTime.minute
        )
        AlertDialog(
            onDismissRequest = { showRangeEndTimePicker = false },
            title = { Text("Select End Time") },
            text = { TimePicker(state = timePickerState) },
            confirmButton = {
                TextButton(onClick = {
                    val time = LocalTime(timePickerState.hour, timePickerState.minute)
                    model.edit { it.copy(rangeEndTime = time) }
                    showRangeEndTimePicker = false
                }) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = { showRangeEndTimePicker = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    // Due date picker dialog
    if (showDueDatePicker) {
        val initialMillis = draft.dueDate?.atStartOfDayIn(TimeZone.UTC)?.toEpochMilliseconds()
            ?: model.today().atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds()
        val datePickerState = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
        DatePickerDialog(
            onDismissRequest = { showDueDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val date = Instant.fromEpochMilliseconds(millis).toLocalDateTime(TimeZone.UTC).date
                        model.edit { it.copy(dueDate = date) }
                    }
                    showDueDatePicker = false
                }) {
                    Text("OK")
                }
            },
            dismissButton = {
                TextButton(onClick = { showDueDatePicker = false }) {
                    Text("Cancel")
                }
            }
        ) {
            DatePicker(state = datePickerState)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Poll") },
                navigationIcon = {
                    IconButton(onClick = onDismiss, enabled = !isLoading) {
                        Icon(Icons.Default.Close, "Cancel")
                    }
                },
                actions = {
                    // No actions in toolbar
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Poll Details Section
            item {
                Text("Poll Details", style = MaterialTheme.typography.titleMedium)
            }

            item {
                OutlinedTextField(
                    value = draft.title,
                    onValueChange = { value -> model.edit { it.copy(title = value) } },
                    label = { Text("Title") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isLoading
                )
            }

            item {
                OutlinedTextField(
                    value = draft.description,
                    onValueChange = { value -> model.edit { it.copy(description = value) } },
                    label = { Text("Description (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isLoading,
                    minLines = 3,
                    maxLines = 6
                )
            }

            item {
                OutlinedTextField(
                    value = draft.location,
                    onValueChange = { value -> model.edit { it.copy(location = value) } },
                    label = { Text("Location (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isLoading
                )
            }

            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("Set response deadline")
                    Switch(
                        checked = draft.hasDueDate,
                        onCheckedChange = model::setHasDueDate,
                        enabled = !isLoading
                    )
                }
            }

            if (draft.hasDueDate) {
                item {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { showDueDatePicker = true },
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Due Date: ${draft.dueDate ?: ""}")
                        Icon(Icons.Default.Edit, "Edit due date")
                    }
                }
            }

            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("All-day events")
                    Switch(
                        checked = draft.isAllDay,
                        onCheckedChange = { value -> model.edit { it.copy(isAllDay = value) } },
                        enabled = !isLoading
                    )
                }
            }

            // Time Options Section
            item {
                Spacer(modifier = Modifier.height(8.dp))
                Text("Time Options", style = MaterialTheme.typography.titleMedium)
            }

            if (draft.isAllDay) {
                item {
                    DayCalendar(
                        selected = draft.selectedDays,
                        today = model.today(),
                        enabled = !isLoading,
                        onToggle = model::toggleDay,
                    )
                }
            } else {
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Use date range selector")
                        Switch(
                            checked = draft.useDateRange,
                            onCheckedChange = { value -> model.edit { it.copy(useDateRange = value) } },
                            enabled = !isLoading
                        )
                    }
                }

                if (draft.useDateRange) {
                    item {
                        Card(
                            modifier = Modifier.fillMaxWidth(),
                            colors = CardDefaults.cardColors(
                                containerColor = MaterialTheme.colorScheme.surfaceVariant
                            )
                        ) {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                Text("Add Date Range", style = MaterialTheme.typography.labelLarge)

                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { showRangeStartDatePicker = true },
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text("Start Date: ${draft.rangeStartDate}")
                                    Icon(
                                        Icons.Default.Edit,
                                        contentDescription = "Edit start date",
                                        modifier = Modifier.size(18.dp),
                                        tint = MaterialTheme.colorScheme.primary
                                    )
                                }

                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { showRangeEndDatePicker = true },
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text("End Date: ${draft.rangeEndDate}")
                                    Icon(
                                        Icons.Default.Edit,
                                        contentDescription = "Edit end date",
                                        modifier = Modifier.size(18.dp),
                                        tint = MaterialTheme.colorScheme.primary
                                    )
                                }

                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { showRangeStartTimePicker = true },
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text("Start Time: ${draft.rangeStartTime}")
                                    Icon(
                                        Icons.Default.Edit,
                                        contentDescription = "Edit start time",
                                        modifier = Modifier.size(18.dp),
                                        tint = MaterialTheme.colorScheme.primary
                                    )
                                }

                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { showRangeEndTimePicker = true },
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text("End Time: ${draft.rangeEndTime}")
                                    Icon(
                                        Icons.Default.Edit,
                                        contentDescription = "Edit end time",
                                        modifier = Modifier.size(18.dp),
                                        tint = MaterialTheme.colorScheme.primary
                                    )
                                }

                                Button(
                                    onClick = model::addRangeOptions,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Icon(Icons.Default.Add, null)
                                    Spacer(Modifier.width(8.dp))
                                    Text("Add Date Range")
                                }
                            }
                        }
                    }
                }
            }

            if (!draft.isAllDay) {
                itemsIndexed(timeOptions) { index, option ->
                    Card(
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(
                            modifier = Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("Time Option ${index + 1}", style = MaterialTheme.typography.labelLarge)
                                if (timeOptions.size > 1) {
                                    IconButton(
                                        onClick = {
                                            model.removeOption(index)
                                        }
                                    ) {
                                        Icon(Icons.Default.Delete, "Delete")
                                    }
                                }
                            }

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        editingOptionIndex = index
                                        showDatePicker = true
                                    },
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("Date: ${option.date}")
                                Icon(
                                    Icons.Default.Edit,
                                    contentDescription = "Edit date",
                                    modifier = Modifier.size(18.dp),
                                    tint = MaterialTheme.colorScheme.primary
                                )
                            }

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        editingOptionIndex = index
                                        showStartTimePicker = true
                                    },
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("Start: ${option.startTime}")
                                Icon(
                                    Icons.Default.Edit,
                                    contentDescription = "Edit start time",
                                    modifier = Modifier.size(18.dp),
                                    tint = MaterialTheme.colorScheme.primary
                                )
                            }

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        editingOptionIndex = index
                                        showEndTimePicker = true
                                    },
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("End: ${option.endTime}")
                                Icon(
                                    Icons.Default.Edit,
                                    contentDescription = "Edit end time",
                                    modifier = Modifier.size(18.dp),
                                    tint = MaterialTheme.colorScheme.primary
                                )
                            }
                        }
                    }
                }

                item {
                    Button(
                        onClick = model::addOption,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.Add, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Add Time Option")
                    }
                }
            }

            // Error Section
            model.errorMessage?.let { error ->
                item {
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.errorContainer
                        )
                    ) {
                        Text(
                            text = error,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                }
            }

            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = draft.useEventPass, onCheckedChange = { value -> model.edit { it.copy(useEventPass = value) } }, enabled = !isLoading)
                    Text("Use an event pass for this poll")
                }
                Text("Uses your oldest eligible pass for a premium poll and keeps your free slot. An active subscription takes priority and keeps your pass.",
                    style = MaterialTheme.typography.bodySmall)
            }

            // Create Poll Button
            item {
                Spacer(modifier = Modifier.height(16.dp))
                Button(
                    onClick = {
                        submitCreation()
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = draft.title.isNotBlank() && !isLoading
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                    } else {
                        Text("Create Poll")
                    }
                }
            }
        }
    }
}
