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
import com.meetingscheduler.android.services.PollService
import kotlinx.coroutines.launch
import kotlinx.datetime.*
import java.util.*

private val currentSystemTime: Instant
    get() = Instant.fromEpochMilliseconds(System.currentTimeMillis())

data class TimeOption(
    val id: String = UUID.randomUUID().toString(),
    var date: LocalDate = currentSystemTime.toLocalDateTime(TimeZone.currentSystemDefault()).date,
    var startTime: LocalTime = LocalTime(9, 0),
    var endTime: LocalTime = LocalTime(10, 0)
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreatePollView(
    pollService: PollService,
    onDismiss: () -> Unit
) {
    var title by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var location by remember { mutableStateOf("") }
    var isAllDay by remember { mutableStateOf(false) }
    var useDateRange by remember { mutableStateOf(false) }
    var timeOptions by remember { mutableStateOf(listOf(TimeOption())) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // Date range fields
    var rangeStartDate by remember { mutableStateOf(currentSystemTime.toLocalDateTime(TimeZone.currentSystemDefault()).date) }
    var rangeEndDate by remember { mutableStateOf(currentSystemTime.toLocalDateTime(TimeZone.currentSystemDefault()).date) }
    var rangeStartTime by remember { mutableStateOf(LocalTime(9, 0)) }
    var rangeEndTime by remember { mutableStateOf(LocalTime(10, 0)) }

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

    val scope = rememberCoroutineScope()

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
                        timeOptions = timeOptions.mapIndexed { index, opt ->
                            if (index == editingOptionIndex) {
                                opt.copy(date = newDate)
                            } else opt
                        }
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
                    timeOptions = timeOptions.mapIndexed { index, opt ->
                        if (index == editingOptionIndex) {
                            opt.copy(startTime = newTime)
                        } else opt
                    }
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
                    timeOptions = timeOptions.mapIndexed { index, opt ->
                        if (index == editingOptionIndex) {
                            opt.copy(endTime = newTime)
                        } else opt
                    }
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
            initialSelectedDateMillis = rangeStartDate.atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds()
        )
        DatePickerDialog(
            onDismissRequest = { showRangeStartDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        rangeStartDate = Instant.fromEpochMilliseconds(millis)
                            .toLocalDateTime(TimeZone.UTC).date
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
            initialSelectedDateMillis = rangeEndDate.atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds()
        )
        DatePickerDialog(
            onDismissRequest = { showRangeEndDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        rangeEndDate = Instant.fromEpochMilliseconds(millis)
                            .toLocalDateTime(TimeZone.UTC).date
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
            initialHour = rangeStartTime.hour,
            initialMinute = rangeStartTime.minute
        )
        AlertDialog(
            onDismissRequest = { showRangeStartTimePicker = false },
            title = { Text("Select Start Time") },
            text = { TimePicker(state = timePickerState) },
            confirmButton = {
                TextButton(onClick = {
                    rangeStartTime = LocalTime(timePickerState.hour, timePickerState.minute)
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
            initialHour = rangeEndTime.hour,
            initialMinute = rangeEndTime.minute
        )
        AlertDialog(
            onDismissRequest = { showRangeEndTimePicker = false },
            title = { Text("Select End Time") },
            text = { TimePicker(state = timePickerState) },
            confirmButton = {
                TextButton(onClick = {
                    rangeEndTime = LocalTime(timePickerState.hour, timePickerState.minute)
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
                    IconButton(
                        onClick = {
                            scope.launch {
                                isLoading = true
                                errorMessage = null
                                try {
                                    val poll = pollService.createPoll(
                                        title = title,
                                        description = description.ifBlank { null },
                                        location = location.ifBlank { null }
                                    )

                                    val options = timeOptions.map { option ->
                                        val start: Instant
                                        val end: Instant

                                        if (isAllDay) {
                                            start = option.date.atTime(0, 0).toInstant(TimeZone.currentSystemDefault())
                                            end = option.date.atTime(23, 59).toInstant(TimeZone.currentSystemDefault())
                                        } else {
                                            start = option.date.atTime(option.startTime).toInstant(TimeZone.currentSystemDefault())
                                            end = option.date.atTime(option.endTime).toInstant(TimeZone.currentSystemDefault())

                                            if (end <= start) {
                                                errorMessage = "End time must be after start time for all time options"
                                                isLoading = false
                                                return@launch
                                            }
                                        }

                                        PollService.TimeOptionInput(start, end, isAllDay)
                                    }

                                    pollService.addTimeOptions(poll.id, options)
                                    onDismiss()
                                } catch (e: Exception) {
                                    errorMessage = e.message
                                    isLoading = false
                                }
                            }
                        },
                        enabled = title.isNotBlank() && !isLoading
                    ) {
                        Icon(Icons.Default.Check, "Create Poll")
                    }
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
                    value = title,
                    onValueChange = { title = it },
                    label = { Text("Title") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isLoading
                )
            }

            item {
                OutlinedTextField(
                    value = description,
                    onValueChange = { description = it },
                    label = { Text("Description (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isLoading,
                    minLines = 3,
                    maxLines = 6
                )
            }

            item {
                OutlinedTextField(
                    value = location,
                    onValueChange = { location = it },
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
                    Text("All-day events")
                    Switch(
                        checked = isAllDay,
                        onCheckedChange = { isAllDay = it },
                        enabled = !isLoading
                    )
                }
            }

            // Time Options Section
            item {
                Spacer(modifier = Modifier.height(8.dp))
                Text("Time Options", style = MaterialTheme.typography.titleMedium)
            }

            if (!isAllDay) {
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Use date range selector")
                        Switch(
                            checked = useDateRange,
                            onCheckedChange = { useDateRange = it },
                            enabled = !isLoading
                        )
                    }
                }

                if (useDateRange) {
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
                                    Text("Start Date: ${rangeStartDate}")
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
                                    Text("End Date: ${rangeEndDate}")
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
                                    Text("Start Time: ${rangeStartTime}")
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
                                    Text("End Time: ${rangeEndTime}")
                                    Icon(
                                        Icons.Default.Edit,
                                        contentDescription = "Edit end time",
                                        modifier = Modifier.size(18.dp),
                                        tint = MaterialTheme.colorScheme.primary
                                    )
                                }

                                Button(
                                    onClick = {
                                        if (rangeStartDate > rangeEndDate) {
                                            errorMessage = "Start date must be before or equal to end date"
                                            return@Button
                                        }

                                        var currentDate = rangeStartDate
                                        while (currentDate <= rangeEndDate) {
                                            timeOptions = timeOptions + TimeOption(
                                                date = currentDate,
                                                startTime = rangeStartTime,
                                                endTime = rangeEndTime
                                            )
                                            currentDate = currentDate.plus(1, DateTimeUnit.DAY)
                                        }

                                        timeOptions = timeOptions.sortedWith(compareBy({ it.date }, { it.startTime }))
                                        errorMessage = null
                                    },
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
                                        timeOptions = timeOptions.filterIndexed { i, _ -> i != index }
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

                        if (!isAllDay) {
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
            }

            item {
                Button(
                    onClick = {
                        val lastOption = timeOptions.lastOrNull()
                        val newDate = lastOption?.date?.plus(1, DateTimeUnit.DAY)
                            ?: currentSystemTime.toLocalDateTime(TimeZone.currentSystemDefault()).date
                        val newStartTime = lastOption?.startTime ?: LocalTime(9, 0)
                        val newEndTime = lastOption?.endTime ?: LocalTime(10, 0)
                        timeOptions = timeOptions + TimeOption(
                            date = newDate,
                            startTime = newStartTime,
                            endTime = newEndTime
                        )
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Default.Add, null)
                    Spacer(Modifier.width(8.dp))
                    Text("Add Time Option")
                }
            }

            // Error Section
            errorMessage?.let { error ->
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
        }
    }
}
