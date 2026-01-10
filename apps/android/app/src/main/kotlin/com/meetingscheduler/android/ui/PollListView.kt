package com.meetingscheduler.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.models.Poll
import com.meetingscheduler.android.models.PollStatus
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.PollService
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PollListView(authService: AuthService, paddingValues: PaddingValues) {
    val pollService = remember { PollService.getInstance(authService, rememberCoroutineScope()) }
    var showCreatePoll by remember { mutableStateOf(false) }
    var showJoinByCode by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        pollService.loadMyPolls()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Polls") },
                actions = {
                    IconButton(onClick = { showJoinByCode = true }) {
                        Icon(Icons.Default.Add, contentDescription = "Join by Code")
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreatePoll = true }) {
                Icon(Icons.Default.Add, contentDescription = "Create Poll")
            }
        },
        modifier = Modifier.padding(paddingValues)
    ) { padding ->
        if (pollService.isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
        } else if (pollService.myPolls.isEmpty()) {
            EmptyPollsView(
                onCreatePoll = { showCreatePoll = true },
                onJoinByCode = { showJoinByCode = true },
                modifier = Modifier.padding(padding)
            )
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
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
                        PollCard(poll = poll, onClick = { /* Navigate to detail */ })
                    }
                }

                if (pollService.joinedPolls.isNotEmpty()) {
                    item {
                        Text(
                            "Polls I Joined",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.padding(vertical = 8.dp)
                        )
                    }
                    items(pollService.joinedPolls) { poll ->
                        PollCard(poll = poll, onClick = { /* Navigate to detail */ })
                    }
                }
            }
        }
    }

    if (showCreatePoll) {
        // TODO: Show CreatePollView as a dialog or navigate
        showCreatePoll = false
    }

    if (showJoinByCode) {
        JoinByCodeDialog(
            onDismiss = { showJoinByCode = false },
            onJoin = { code ->
                scope.launch {
                    val poll = pollService.loadPollByCode(code)
                    if (poll != null) {
                        // Navigate to poll detail
                    }
                    showJoinByCode = false
                }
            }
        )
    }
}

@Composable
fun EmptyPollsView(
    onCreatePoll: () -> Unit,
    onJoinByCode: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                "No polls yet",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold
            )
            Text(
                "Create a poll or join one with a code",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onCreatePoll) {
                    Text("Create Poll")
                }
                OutlinedButton(onClick = onJoinByCode) {
                    Text("Join by Code")
                }
            }
        }
    }
}

@Composable
fun PollCard(poll: Poll, onClick: () -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(
                text = poll.title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )
            poll.description?.let { desc ->
                Text(
                    text = desc,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                AssistChip(
                    onClick = {},
                    label = { Text(poll.status.name) }
                )
                poll.location?.let { loc ->
                    AssistChip(
                        onClick = {},
                        label = { Text(loc) }
                    )
                }
            }
        }
    }
}

@Composable
fun JoinByCodeDialog(onDismiss: () -> Unit, onJoin: (String) -> Unit) {
    var code by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Join Poll") },
        text = {
            OutlinedTextField(
                value = code,
                onValueChange = { code = it.uppercase() },
                label = { Text("Poll Code") },
                singleLine = true
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onJoin(code) },
                enabled = code.isNotBlank()
            ) {
                Text("Join")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
