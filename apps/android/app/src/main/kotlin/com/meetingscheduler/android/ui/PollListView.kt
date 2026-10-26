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
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService
import kotlinx.coroutines.launch
import kotlinx.datetime.Instant

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PollListView(
    pollService: PollService,
    purchaseService: PurchaseService?,
    onNavigateToPoll: (String) -> Unit,
    onNavigateToCreatePoll: () -> Unit,
    onNavigateToPaywall: () -> Unit
) {
    var showJoinByCode by remember { mutableStateOf(false) }
    var joinCode by remember { mutableStateOf("") }
    var joinError by remember { mutableStateOf<String?>(null) }
    var isJoining by remember { mutableStateOf(false) }
    var navigateToPollId by remember { mutableStateOf<String?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(pollService.creationAccountKey) {
        pollService.loadMyPolls()
    }

    LaunchedEffect(navigateToPollId) {
        navigateToPollId?.let { pollId ->
            onNavigateToPoll(pollId)
            navigateToPollId = null
        }
    }

    fun handleCreatePoll() {
        onNavigateToCreatePoll()
    }

    fun handleJoinByCode() {
        scope.launch {
            isJoining = true
            joinError = null

            val code = joinCode.trim().uppercase()

            if (code.length != 6) {
                joinError = "Code must be 6 characters"
                isJoining = false
                return@launch
            }

            val poll = pollService.loadPollByCode(code)

            if (poll == null) {
                joinError = "Poll not found. Please check the code."
                isJoining = false
                return@launch
            }

            if (poll.status == com.meetingscheduler.android.models.PollStatus.CLOSED ||
                poll.status == com.meetingscheduler.android.models.PollStatus.ARCHIVED
            ) {
                joinError = "This poll is closed and cannot accept new participants."
                isJoining = false
                return@launch
            }

            showJoinByCode = false
            joinCode = ""
            joinError = null
            isJoining = false
            navigateToPollId = poll.id
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("My Polls") },
                actions = {
                    IconButton(onClick = { showJoinByCode = true }) {
                        Icon(Icons.Default.Download, "Join Poll")
                    }
                    IconButton(onClick = { handleCreatePoll() }) {
                        Icon(Icons.Default.Add, "Create Poll")
                    }
                }
            )
        }
    ) { padding ->
        SwipeRefresh(
            state = rememberSwipeRefreshState(isRefreshing),
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try { pollService.loadMyPolls() }
                    finally { isRefreshing = false }
                }
            },
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
                    EmptyPollsView(onCreatePoll = { handleCreatePoll() })
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
                                    TextButton(onClick = { scope.launch { pollService.loadMorePolls() } },
                                        enabled = !pollService.isLoadingMore && !pollService.isLoading) { Text("Load more") }
                                }
                                if (pollService.isLoadingMore) CircularProgressIndicator()
                                pollService.listLoadError?.let { error ->
                                    Text(error, color = MaterialTheme.colorScheme.error)
                                    TextButton(onClick = { scope.launch {
                                        pollService.retryPollLoad()
                                    } }) { Text("Retry") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Join by Code Sheet
    if (showJoinByCode) {
        JoinByCodeSheet(
            joinCode = joinCode,
            joinError = joinError,
            isJoining = isJoining,
            onCodeChange = { joinCode = it },
            onJoin = { handleJoinByCode() },
            onDismiss = {
                showJoinByCode = false
                joinCode = ""
                joinError = null
            }
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
    pollService: PollService,
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
                    onValueChange = { if (it.length <= 6) onCodeChange(it.uppercase()) },
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
