package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
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

    val scope = rememberCoroutineScope()

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

                                Text("Start Date: ${rangeStartDate}")
                                Text("End Date: ${rangeEndDate}")
                                Text("Start Time: ${rangeStartTime}")
                                Text("End Time: ${rangeEndTime}")

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

                        Text("Date: ${option.date}")

                        if (!isAllDay) {
                            Text("Start: ${option.startTime}")
                            Text("End: ${option.endTime}")
                        }
                    }
                }
            }

            item {
                Button(
                    onClick = {
                        timeOptions = timeOptions + TimeOption()
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
