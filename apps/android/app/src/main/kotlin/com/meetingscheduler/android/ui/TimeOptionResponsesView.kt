package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.models.PollDates
import com.meetingscheduler.android.services.PollResponsesPolls
import kotlinx.datetime.Instant
import java.text.SimpleDateFormat
import java.util.*

// Extension function to convert kotlinx.datetime.Instant to java.time.Instant
private fun Instant.toJavaInstant(): java.time.Instant {
    return java.time.Instant.ofEpochMilli(this.toEpochMilliseconds())
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimeOptionResponsesView(
    pollId: String,
    timeOptionId: String,
    pollService: PollResponsesPolls,
    onNavigateBack: () -> Unit
) {
    // The holder is kept by the navigation entry's store, so the load outlasts the Activity.
    val holder = timeOptionResponsesHolder(pollId, timeOptionId, pollService)
    val model = holder.opened.getOrThrow()
    val groupedResponses = model.grouped
    val timeOption = model.timeOption
    val pollTimeZone = model.pollTimeZone
    val loadError = model.loadError

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Responses") },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.Default.ArrowBack, "Back")
                    }
                }
            )
        }
    ) { padding ->
        if (model.isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
        } else if (loadError != null) {
            Column(Modifier.padding(padding).padding(24.dp)) {
                Text(loadError)
                TextButton(onClick = { holder.launch { load() } }) { Text("Retry") }
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // Time Option Info
                timeOption?.let { option ->
                    item {
                        Card {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                val dateFormat = SimpleDateFormat("MMMM d, yyyy", Locale.getDefault())
                                    .apply { timeZone = PollDates.displayZone(option.isAllDay, pollTimeZone) }
                                Text(
                                    dateFormat.format(Date.from(option.startTime.toJavaInstant())),
                                    style = MaterialTheme.typography.titleMedium
                                )

                                if (option.isAllDay) {
                                    Text(
                                        "All day",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                } else {
                                    val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
                                    val start = timeFormat.format(Date.from(option.startTime.toJavaInstant()))
                                    val end = timeFormat.format(Date.from(option.endTime.toJavaInstant()))
                                    Text(
                                        "$start - $end",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                    }
                }

                // Responses
                val hasNoResponses = groupedResponses.available.isEmpty() &&
                    groupedResponses.maybe.isEmpty() &&
                    groupedResponses.unavailable.isEmpty()

                if (hasNoResponses) {
                    item {
                        Card {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(32.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    "No responses yet for this time option",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                } else {
                    // Available Section
                    if (groupedResponses.available.isNotEmpty()) {
                        item {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Check, null, tint = Color(0xFF1B5E20), modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    "Available (${groupedResponses.available.size})",
                                    style = MaterialTheme.typography.titleSmall,
                                    color = Color(0xFF1B5E20)
                                )
                            }
                        }

                        items(groupedResponses.available) { item ->
                            ResponseRow(item)
                        }
                    }

                    // Maybe Section
                    if (groupedResponses.maybe.isNotEmpty()) {
                        item {
                            Spacer(Modifier.height(8.dp))
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.HelpOutline, null, tint = Color(0xFFE65100), modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    "Tentative (${groupedResponses.maybe.size})",
                                    style = MaterialTheme.typography.titleSmall,
                                    color = Color(0xFFE65100)
                                )
                            }
                        }

                        items(groupedResponses.maybe) { item ->
                            ResponseRow(item)
                        }
                    }

                    // Unavailable Section
                    if (groupedResponses.unavailable.isNotEmpty()) {
                        item {
                            Spacer(Modifier.height(8.dp))
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Close, null, tint = Color(0xFFC62828), modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    "Not Available (${groupedResponses.unavailable.size})",
                                    style = MaterialTheme.typography.titleSmall,
                                    color = Color(0xFFC62828)
                                )
                            }
                        }

                        items(groupedResponses.unavailable) { item ->
                            ResponseRow(item)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ResponseRow(item: ResponseItem) {
    Card(
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                item.participantName,
                style = MaterialTheme.typography.bodyLarge
            )

            if (!item.note.isNullOrBlank()) {
                Text(
                    item.note,
                    style = MaterialTheme.typography.bodySmall,
                    fontStyle = FontStyle.Italic,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
