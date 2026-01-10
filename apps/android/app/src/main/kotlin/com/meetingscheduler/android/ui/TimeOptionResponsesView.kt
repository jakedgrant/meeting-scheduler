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
import com.meetingscheduler.android.models.AvailabilityResponse
import com.meetingscheduler.android.models.AvailabilityStatus
import com.meetingscheduler.android.models.PollParticipant
import com.meetingscheduler.android.models.PollTimeOption
import com.meetingscheduler.android.services.PollService
import kotlinx.datetime.toJavaInstant
import java.text.SimpleDateFormat
import java.util.*

data class ResponseItem(
    val id: String,
    val participantName: String,
    val status: AvailabilityStatus,
    val note: String?
)

data class GroupedResponses(
    val available: List<ResponseItem>,
    val maybe: List<ResponseItem>,
    val unavailable: List<ResponseItem>
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimeOptionResponsesView(
    pollId: String,
    timeOptionId: String,
    pollService: PollService,
    onNavigateBack: () -> Unit
) {
    var timeOption by remember { mutableStateOf<PollTimeOption?>(null) }
    var participants by remember { mutableStateOf<List<PollParticipant>>(emptyList()) }
    var responses by remember { mutableStateOf<List<AvailabilityResponse>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    val groupedResponses = remember(responses, participants) {
        val optionResponses = responses.filter { it.timeOptionId == timeOptionId }

        val items = optionResponses.mapNotNull { response ->
            val participant = participants.firstOrNull { it.id == response.participantId }
            participant?.let {
                ResponseItem(
                    id = response.id,
                    participantName = it.displayName,
                    status = response.status,
                    note = response.note
                )
            }
        }

        val sortedItems = items.sortedBy { it.participantName }

        GroupedResponses(
            available = sortedItems.filter { it.status == AvailabilityStatus.AVAILABLE },
            maybe = sortedItems.filter { it.status == AvailabilityStatus.MAYBE },
            unavailable = sortedItems.filter { it.status == AvailabilityStatus.UNAVAILABLE }
        )
    }

    LaunchedEffect(pollId, timeOptionId) {
        isLoading = true
        val allTimeOptions = pollService.loadTimeOptions(pollId)
        timeOption = allTimeOptions.firstOrNull { it.id == timeOptionId }

        participants = pollService.loadParticipants(pollId)
        val participantIds = participants.map { it.id }
        responses = pollService.loadResponses(participantIds)

        isLoading = false
    }

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
        if (isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
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
                if (responses.isEmpty()) {
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
                                Icon(Icons.Default.Check, null, tint = Color.Green, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    "Available (${groupedResponses.available.size})",
                                    style = MaterialTheme.typography.titleSmall,
                                    color = Color.Green
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
                                Icon(Icons.Default.HelpOutline, null, tint = Color(0xFFFF9800), modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    "Tentative (${groupedResponses.maybe.size})",
                                    style = MaterialTheme.typography.titleSmall,
                                    color = Color(0xFFFF9800)
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
                                Icon(Icons.Default.Close, null, tint = Color.Red, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    "Not Available (${groupedResponses.unavailable.size})",
                                    style = MaterialTheme.typography.titleSmall,
                                    color = Color.Red
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
