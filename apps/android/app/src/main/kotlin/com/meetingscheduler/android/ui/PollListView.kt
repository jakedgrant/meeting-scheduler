package com.meetingscheduler.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Download
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.accompanist.swiperefresh.SwipeRefresh
import com.google.accompanist.swiperefresh.rememberSwipeRefreshState
import com.meetingscheduler.android.models.Poll
import com.meetingscheduler.android.services.PollListPolls
import kotlinx.datetime.Instant

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PollListView(
    pollService: PollListPolls,
    onNavigateToPoll: (String) -> Unit,
    onNavigateToCreatePoll: () -> Unit,
    onNavigateToPaywall: () -> Unit
) {
    // The holder is kept by the navigation entry's store, so the list's join sheet and requests outlast the Activity.
    val holder = pollListHolder(pollService)
    val model = holder.opened.getOrThrow()
    // The list reloads each time it comes back into view: after a child screen, a tab switch or a recreation.
    RefreshOnReturn(holder)
    DisposableEffect(holder) { onDispose { holder.coverWithChild() } }

    LaunchedEffect(model.pollToOpen) {
        model.pollToOpen?.let { pollId ->
            onNavigateToPoll(pollId)
            model.openedPoll()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("My Polls") },
                actions = {
                    IconButton(onClick = { model.showJoinSheet() }) {
                        Icon(Icons.Default.Download, "Join Poll")
                    }
                    IconButton(onClick = onNavigateToCreatePoll) {
                        Icon(Icons.Default.Add, "Create Poll")
                    }
                }
            )
        }
    ) { padding ->
        SwipeRefresh(
            state = rememberSwipeRefreshState(model.isRefreshing),
            onRefresh = { holder.launch { refresh() } },
            modifier = Modifier.padding(padding)
        ) {
            when {
                pollService.isLoading && pollService.createdPolls.isEmpty() && pollService.joinedPolls.isEmpty() -> {
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center
                    ) {
                        CircularProgressIndicator()
                    }
                }

                pollService.myPolls.isEmpty() && pollService.listLoadError == null -> {
                    EmptyPollsView(onCreatePoll = onNavigateToCreatePoll)
                }

                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (pollService.createdPolls.isNotEmpty()) {
                            item {
                                Text(
                                    "My Polls",
                                    style = MaterialTheme.typography.titleMedium,
                                    modifier = Modifier.padding(vertical = 8.dp)
                                )
                            }

                            items(pollService.createdPolls) { poll ->
                                PollRowView(
                                    poll = poll,
                                    participantCount = pollService.pollParticipantCounts[poll.id] ?: 0,
                                    timeRange = pollService.pollTimeRanges[poll.id],
                                    onClick = { onNavigateToPoll(poll.id) },
                                    pollService = pollService,
                                    isOwner = true
                                )
                            }
                        }

                        if (pollService.joinedPolls.isNotEmpty()) {
                            item {
                                Spacer(Modifier.height(16.dp))
                                Text(
                                    "Polls I Joined",
                                    style = MaterialTheme.typography.titleMedium,
                                    modifier = Modifier.padding(vertical = 8.dp)
                                )
                            }

                            items(pollService.joinedPolls) { poll ->
                                PollRowView(
                                    poll = poll,
                                    participantCount = pollService.pollParticipantCounts[poll.id] ?: 0,
                                    timeRange = pollService.pollTimeRanges[poll.id],
                                    onClick = { onNavigateToPoll(poll.id) },
                                    pollService = pollService,
                                    isOwner = false
                                )
                            }
                        }
                        item {
                            Column {
                                pollService.listTotalCount?.let { Text("Loaded ${pollService.myPolls.size} of $it polls") }
                                if (pollService.hasMorePolls) {
                                    TextButton(onClick = { holder.launch { loadMore() } },
                                        enabled = !pollService.isLoadingMore && !pollService.isLoading) { Text("Load more") }
                                }
                                if (pollService.isLoadingMore) CircularProgressIndicator()
                                pollService.listLoadError?.let { error ->
                                    Text(error, color = MaterialTheme.colorScheme.error)
                                    TextButton(onClick = { holder.launch { retry() } }) { Text("Retry") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Join by Code Sheet
    if (model.showJoinByCode) {
        JoinByCodeSheet(
            joinCode = model.joinCode,
            joinError = model.joinError,
            isJoining = model.isJoining,
            onCodeChange = model::editJoinCode,
            onJoin = { holder.launch { join() } },
            onDismiss = model::dismissJoinSheet
        )
    }
}

@Composable
fun EmptyPollsView(onCreatePoll: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.padding(32.dp)
        ) {
            Icon(
                Icons.Default.Add,
                null,
                modifier = Modifier.size(64.dp),
                tint = MaterialTheme.colorScheme.primary
            )

            Text(
                "No Polls Yet",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold
            )

            Text(
                "Create your first poll to start scheduling meetings.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Button(onClick = onCreatePoll) {
                Text("Create Poll")
            }
        }
    }
}

@Composable
fun PollRowView(
    poll: Poll,
    participantCount: Int = 0,
    timeRange: Pair<Instant, Instant>? = null,
    onClick: () -> Unit,
    pollService: PollListPolls,
    isOwner: Boolean = false
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    modifier = Modifier.weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        poll.title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold
                    )

                    if (isOwner) {
                        OwnerBadge()
                    }
                }

                Spacer(Modifier.width(4.dp))

                StatusBadge(poll.status)
            }

            poll.description?.let { desc ->
                Text(
                    desc,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2
                )
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (timeRange != null) {
                    Text(
                        pollService.formatTimeRange(timeRange.first, timeRange.second),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f)
                    )
                } else {
                    Text(
                        "No time options",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        modifier = Modifier.weight(1f)
                    )
                }

                Text(
                    "$participantCount participant${if (participantCount != 1) "s" else ""}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JoinByCodeSheet(
    joinCode: String,
    joinError: String?,
    isJoining: Boolean,
    onCodeChange: (String) -> Unit,
    onJoin: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Join by Code") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Enter the 6-character code shared by the poll creator")

                OutlinedTextField(
                    value = joinCode,
                    onValueChange = onCodeChange,
                    label = { Text("Share Code") },
                    placeholder = { Text("ABC123") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    enabled = !isJoining,
                    isError = joinError != null
                )

                joinError?.let { error ->
                    Text(
                        error,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }
        },
        confirmButton = {
            Button(
                onClick = onJoin,
                enabled = joinCode.length == 6 && !isJoining
            ) {
                if (isJoining) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        color = MaterialTheme.colorScheme.onPrimary
                    )
                } else {
                    Text("Join Poll")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !isJoining) {
                Text("Cancel")
            }
        }
    )
}

@Composable
fun OwnerBadge() {
    Surface(
        color = Color(0xFF1976D2).copy(alpha = 0.15f),
        shape = RoundedCornerShape(12.dp)
    ) {
        Text(
            "Owner",
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
            color = Color(0xFF0D47A1)
        )
    }
}
