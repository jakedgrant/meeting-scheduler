package com.meetingscheduler.android.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.CalendarSource
import com.meetingscheduler.android.services.PollService
import kotlinx.coroutines.launch
import kotlinx.datetime.Instant
import java.text.SimpleDateFormat
import java.time.ZoneId
import java.util.*

// Extension function to convert kotlinx.datetime.Instant to java.time.Instant
private fun Instant.toJavaInstant(): java.time.Instant {
    return java.time.Instant.ofEpochMilli(this.toEpochMilliseconds())
}

data class ResponseSummary(
    val available: Int,
    val maybe: Int,
    val unavailable: Int
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PollDetailView(
    pollId: String,
    authService: AuthService,
    pollService: PollService,
    calendarService: CalendarService,
    onNavigateToResponses: (String) -> Unit,
    onNavigateBack: () -> Unit
) {
    var poll by remember { mutableStateOf<Poll?>(null) }
    var timeOptions by remember { mutableStateOf<List<PollTimeOption>>(emptyList()) }
    var participants by remember { mutableStateOf<List<PollParticipant>>(emptyList()) }
    var responses by remember { mutableStateOf<List<AvailabilityResponse>>(emptyList()) }
    var myParticipant by remember { mutableStateOf<PollParticipant?>(null) }
    var localResponses by remember { mutableStateOf<Map<String, AvailabilityStatus>>(emptyMap()) }
    var localComment by remember { mutableStateOf("") }
    var commentError by remember { mutableStateOf("") }
    var calendarConflicts by remember { mutableStateOf<Set<String>>(emptySet()) }

    val MAX_COMMENT_LENGTH = 500
    var isLoading by remember { mutableStateOf(true) }
    var isSaving by remember { mutableStateOf(false) }
    var showClosePollDialog by remember { mutableStateOf(false) }
    var showSelectFinalDateDialog by remember { mutableStateOf(false) }
    var finalTimeOption by remember { mutableStateOf<PollTimeOption?>(null) }
    var isSelectingFinalDate by remember { mutableStateOf(false) }

    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current

    val isCreator = poll?.creatorId == authService.currentUser?.id

    fun responsesForOption(optionId: String): ResponseSummary {
        val optionResponses = responses.filter { it.timeOptionId == optionId }
        return ResponseSummary(
            available = optionResponses.count { it.status == AvailabilityStatus.AVAILABLE },
            maybe = optionResponses.count { it.status == AvailabilityStatus.MAYBE },
            unavailable = optionResponses.count { it.status == AvailabilityStatus.UNAVAILABLE }
        )
    }

    val sortedTimeOptions = timeOptions.sortedWith { a, b ->
        val statsA = responsesForOption(a.id)
        val statsB = responsesForOption(b.id)
        when {
            statsB.available != statsA.available -> statsB.available.compareTo(statsA.available)
            else -> statsB.maybe.compareTo(statsA.maybe)
        }
    }

    LaunchedEffect(pollId) {
        isLoading = true
        poll = pollService.loadPoll(pollId)

        if (poll != null) {
            timeOptions = pollService.loadTimeOptions(pollId)
            participants = pollService.loadParticipants(pollId)

            authService.currentUser?.id?.let { userId ->
                myParticipant = participants.firstOrNull { it.userId == userId }
            }

            responses = pollService.loadResponses(timeOptions.map { it.id })

            myParticipant?.let { participant ->
                val myResponses = responses.filter { it.participantId == participant.id }
                localResponses = myResponses.associate { it.timeOptionId to it.status }
                localComment = participant.comment ?: ""
            }

            // Check calendar conflicts
            if (calendarService.isEnabled && timeOptions.isNotEmpty()) {
                val conflicts = mutableSetOf<String>()
                timeOptions.forEach { option ->
                    val conflictEvents = calendarService.checkConflicts(
                        option.startTime,
                        option.endTime,
                        listOf(CalendarSource.APPLE_CALENDAR, CalendarSource.GOOGLE_CALENDAR)
                    )
                    if (conflictEvents.isNotEmpty()) {
                        conflicts.add(option.id)
                    }
                }
                calendarConflicts = conflicts

                // Auto-mark conflicts as unavailable
                conflicts.forEach { conflictId ->
                    if (!localResponses.containsKey(conflictId)) {
                        localResponses = localResponses + (conflictId to AvailabilityStatus.UNAVAILABLE)
                    }
                }
            }
        }

        isLoading = false
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(poll?.title ?: "Poll") },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.Default.ArrowBack, "Back")
                    }
                },
                actions = {
                    if (isCreator && poll?.status == PollStatus.ACTIVE) {
                        IconButton(onClick = { showClosePollDialog = true }) {
                            Icon(Icons.Default.Close, "Close Poll")
                        }
                        IconButton(onClick = {
                            poll?.let {
                                val shareText = """
                                    Join my poll: ${it.title}

                                    Share Code: ${it.shareCode}

                                    Open the Meeting Scheduler app and enter the code to join!
                                """.trimIndent()

                                val sendIntent = Intent().apply {
                                    action = Intent.ACTION_SEND
                                    putExtra(Intent.EXTRA_TEXT, shareText)
                                    type = "text/plain"
                                }
                                context.startActivity(Intent.createChooser(sendIntent, null))
                            }
                        }) {
                            Icon(Icons.Default.Share, "Share")
                        }
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
        } else if (poll == null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center
            ) {
                Text("Poll not found")
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // Poll Info
                item {
                    Card {
                        Column(
                            modifier = Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            poll?.description?.let { desc ->
                                Text(desc, style = MaterialTheme.typography.bodyMedium)
                            }
                            poll?.location?.let { loc ->
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.Place, null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text(loc, style = MaterialTheme.typography.bodySmall)
                                }
                            }
                            Row(
                                horizontalArrangement = Arrangement.SpaceBetween,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text("Status")
                                poll?.status?.let { StatusBadge(it) }
                            }
                        }
                    }
                }

                // Share Code
                if (poll?.status == PollStatus.ACTIVE) {
                    item {
                        Card {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Row(
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Text("Share Code", style = MaterialTheme.typography.labelMedium)
                                    TextButton(onClick = {
                                        poll?.let { clipboardManager.setText(AnnotatedString(it.shareCode)) }
                                    }) {
                                        Icon(Icons.Default.ContentCopy, null, modifier = Modifier.size(16.dp))
                                        Spacer(Modifier.width(4.dp))
                                        Text("Copy")
                                    }
                                }

                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .background(
                                            MaterialTheme.colorScheme.primaryContainer,
                                            RoundedCornerShape(8.dp)
                                        )
                                        .padding(vertical = 16.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    poll?.let {
                                        Text(
                                            it.shareCode,
                                            style = MaterialTheme.typography.headlineSmall,
                                            fontWeight = FontWeight.Bold,
                                            color = MaterialTheme.colorScheme.primary
                                        )
                                    }
                                }

                                Text(
                                    "Share this code for others to join",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }

                // Final Date Display
                poll?.selectedStartTime?.let { selectedStart ->
                    poll?.selectedEndTime?.let { selectedEnd ->
                        item {
                            FinalDateDisplay(
                                selectedStart = selectedStart,
                                selectedEnd = selectedEnd,
                                isAllDay = timeOptions.firstOrNull()?.isAllDay ?: false
                            )
                        }
                    }
                }

                // Final Date Selection (for creator when closed)
                if (isCreator && poll?.status == PollStatus.CLOSED && poll?.selectedStartTime == null) {
                    item {
                        Card {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                Text("Select Final Meeting Time", style = MaterialTheme.typography.titleMedium)
                                Text(
                                    "Choose the best time based on availability:",
                                    style = MaterialTheme.typography.bodySmall
                                )

                                sortedTimeOptions.forEach { option ->
                                    val stats = responsesForOption(option.id)
                                    FinalDateOptionRow(
                                        option = option,
                                        stats = stats,
                                        onClick = {
                                            finalTimeOption = option
                                            showSelectFinalDateDialog = true
                                        },
                                        enabled = !isSelectingFinalDate
                                    )
                                }
                            }
                        }
                    }
                }

                // Time Options
                item {
                    Text("Time Options", style = MaterialTheme.typography.titleMedium)
                }

                items(timeOptions) { option ->
                    TimeOptionRow(
                        option = option,
                        responses = responsesForOption(option.id),
                        myResponse = localResponses[option.id],
                        hasCalendarConflict = calendarConflicts.contains(option.id),
                        canRespond = myParticipant != null && poll?.status == PollStatus.ACTIVE,
                        onResponseChange = { status ->
                            localResponses = localResponses + (option.id to status)
                        },
                        onClick = { onNavigateToResponses(option.id) }
                    )
                }

                // Comment Field
                if (myParticipant != null && poll?.status == PollStatus.ACTIVE) {
                    item {
                        Card {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        "Add a comment (optional)",
                                        style = MaterialTheme.typography.labelMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                    Text(
                                        "${localComment.length}/$MAX_COMMENT_LENGTH",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                OutlinedTextField(
                                    value = localComment,
                                    onValueChange = { newValue ->
                                        if (newValue.length <= MAX_COMMENT_LENGTH) {
                                            localComment = newValue
                                            commentError = ""
                                        } else {
                                            commentError = "Comment must be $MAX_COMMENT_LENGTH characters or less"
                                        }
                                    },
                                    placeholder = { Text("e.g., I'm flexible on timing, or I can only attend virtually...") },
                                    modifier = Modifier.fillMaxWidth(),
                                    minLines = 2,
                                    maxLines = 4,
                                    isError = commentError.isNotEmpty()
                                )
                                if (commentError.isNotEmpty()) {
                                    Text(
                                        commentError,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.error
                                    )
                                }
                            }
                        }
                    }
                }

                // Save Responses Button
                if (myParticipant != null && poll?.status == PollStatus.ACTIVE) {
                    item {
                        Button(
                            onClick = {
                                // Validate comment
                                if (localComment.length > MAX_COMMENT_LENGTH) {
                                    commentError = "Comment must be $MAX_COMMENT_LENGTH characters or less"
                                    return@Button
                                }

                                scope.launch {
                                    isSaving = true
                                    myParticipant?.let { participant ->
                                        try {
                                            val responseInputs = localResponses.map { (optionId, status) ->
                                                PollService.ResponseInput(
                                                    timeOptionId = optionId,
                                                    status = status,
                                                    note = null
                                                )
                                            }
                                            pollService.saveResponses(participant.id, responseInputs)
                                            // Save comment (trimmed, null if empty)
                                            val trimmedComment = localComment.trim()
                                            pollService.updateParticipantComment(
                                                participant.id,
                                                if (trimmedComment.isEmpty()) null else trimmedComment
                                            )
                                            responses = pollService.loadResponses(timeOptions.map { it.id })
                                            participants = pollService.loadParticipants(pollId)
                                        } catch (e: Exception) {
                                            println("Failed to save responses: ${e.message}")
                                        }
                                    }
                                    isSaving = false
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !isSaving && commentError.isEmpty()
                        ) {
                            if (isSaving) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(20.dp),
                                    color = MaterialTheme.colorScheme.onPrimary
                                )
                            } else {
                                Text("Save Responses")
                            }
                        }
                    }
                }

                // Join Button
                if (myParticipant == null && poll?.status == PollStatus.ACTIVE) {
                    item {
                        Button(
                            onClick = {
                                scope.launch {
                                    try {
                                        val participant = pollService.joinPoll(pollId)
                                        myParticipant = participant
                                        participants = participants + participant
                                    } catch (e: Exception) {
                                        println("Failed to join poll: ${e.message}")
                                    }
                                }
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Join This Poll")
                        }
                    }
                }

                // Participants
                item {
                    Text("Participants (${participants.size})", style = MaterialTheme.typography.titleMedium)
                }

                if (participants.isEmpty()) {
                    item {
                        Text(
                            "No participants yet",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                } else {
                    items(participants) { participant ->
                        ParticipantRow(
                            participant = participant,
                            isCurrentUser = participant.userId == authService.currentUser?.id
                        )
                    }
                }
            }
        }
    }

    // Close Poll Dialog
    if (showClosePollDialog) {
        AlertDialog(
            onDismissRequest = { showClosePollDialog = false },
            title = { Text("Close Poll") },
            text = { Text("Are you sure you want to close this poll? Once closed, participants will no longer be able to submit or modify their availability.") },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        try {
                            pollService.updatePollStatus(pollId, PollStatus.CLOSED)
                            poll = poll?.copy(status = PollStatus.CLOSED)
                        } catch (e: Exception) {
                            println("Failed to update status: ${e.message}")
                        }
                    }
                    showClosePollDialog = false
                }) {
                    Text("Close Poll")
                }
            },
            dismissButton = {
                TextButton(onClick = { showClosePollDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    // Select Final Date Dialog
    if (showSelectFinalDateDialog) {
        val formattedOption = finalTimeOption?.let { option ->
            val dateFormat = SimpleDateFormat("MMMM d, yyyy", Locale.getDefault())
            val dateStr = dateFormat.format(Date.from(option.startTime.toJavaInstant()))

            if (option.isAllDay) {
                dateStr
            } else {
                val timeFormat = SimpleDateFormat("h:mma", Locale.getDefault())
                val startTime = timeFormat.format(Date.from(option.startTime.toJavaInstant()))
                val endTime = timeFormat.format(Date.from(option.endTime.toJavaInstant()))
                "$dateStr $startTime - $endTime"
            }
        } ?: ""

        AlertDialog(
            onDismissRequest = { showSelectFinalDateDialog = false },
            title = { Text("Select Final Date") },
            text = { Text("Set $formattedOption as the final meeting time? All participants will be notified.") },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        isSelectingFinalDate = true
                        finalTimeOption?.let { option ->
                            try {
                                pollService.setSelectedFinalDate(
                                    pollId,
                                    option.startTime,
                                    option.endTime
                                )
                                poll = pollService.loadPoll(pollId)
                            } catch (e: Exception) {
                                println("Failed to set final date: ${e.message}")
                            }
                        }
                        isSelectingFinalDate = false
                    }
                    showSelectFinalDateDialog = false
                }) {
                    Text("Confirm")
                }
            },
            dismissButton = {
                TextButton(onClick = { showSelectFinalDateDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}

@Composable
fun TimeOptionRow(
    option: PollTimeOption,
    responses: ResponseSummary,
    myResponse: AvailabilityStatus?,
    hasCalendarConflict: Boolean,
    canRespond: Boolean,
    onResponseChange: (AvailabilityStatus) -> Unit,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        val dateFormat = SimpleDateFormat("MMM d, yyyy", Locale.getDefault())
                        Text(
                            dateFormat.format(Date.from(option.startTime.toJavaInstant())),
                            style = MaterialTheme.typography.titleSmall
                        )

                        if (hasCalendarConflict) {
                            Spacer(Modifier.width(8.dp))
                            Surface(
                                color = MaterialTheme.colorScheme.errorContainer,
                                shape = RoundedCornerShape(4.dp)
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(
                                        Icons.Default.Warning,
                                        null,
                                        modifier = Modifier.size(12.dp),
                                        tint = MaterialTheme.colorScheme.onErrorContainer
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Text(
                                        "Busy",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onErrorContainer
                                    )
                                }
                            }
                        }
                    }

                    if (option.isAllDay) {
                        Text("All day", style = MaterialTheme.typography.bodySmall)
                    } else {
                        val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
                        val start = timeFormat.format(Date.from(option.startTime.toJavaInstant()))
                        val end = timeFormat.format(Date.from(option.endTime.toJavaInstant()))
                        Text("$start - $end", style = MaterialTheme.typography.bodySmall)
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ResponseCount(responses.available, AvailabilityStatus.AVAILABLE)
                    ResponseCount(responses.maybe, AvailabilityStatus.MAYBE)
                    ResponseCount(responses.unavailable, AvailabilityStatus.UNAVAILABLE)
                }
            }

            if (canRespond) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    ResponseButton(
                        AvailabilityStatus.AVAILABLE,
                        myResponse == AvailabilityStatus.AVAILABLE,
                        modifier = Modifier.weight(1f)
                    ) { onResponseChange(AvailabilityStatus.AVAILABLE) }
                    ResponseButton(
                        AvailabilityStatus.MAYBE,
                        myResponse == AvailabilityStatus.MAYBE,
                        modifier = Modifier.weight(1f)
                    ) { onResponseChange(AvailabilityStatus.MAYBE) }
                    ResponseButton(
                        AvailabilityStatus.UNAVAILABLE,
                        myResponse == AvailabilityStatus.UNAVAILABLE,
                        modifier = Modifier.weight(1f)
                    ) { onResponseChange(AvailabilityStatus.UNAVAILABLE) }
                }
            }
        }
    }
}

@Composable
fun ResponseCount(count: Int, status: AvailabilityStatus) {
    val backgroundColor = when (status) {
        AvailabilityStatus.AVAILABLE -> Color(0xFF2E7D32).copy(alpha = 0.15f)
        AvailabilityStatus.MAYBE -> Color(0xFFE65100).copy(alpha = 0.15f)
        AvailabilityStatus.UNAVAILABLE -> Color(0xFFC62828).copy(alpha = 0.15f)
    }

    val foregroundColor = when (status) {
        AvailabilityStatus.AVAILABLE -> Color(0xFF1B5E20)
        AvailabilityStatus.MAYBE -> Color(0xFFE65100)
        AvailabilityStatus.UNAVAILABLE -> Color(0xFFC62828)
    }

    Box(
        modifier = Modifier
            .size(28.dp)
            .background(backgroundColor, CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Text(
            "$count",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
            color = foregroundColor
        )
    }
}

@Composable
fun ResponseButton(
    status: AvailabilityStatus,
    isSelected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    val icon = when (status) {
        AvailabilityStatus.AVAILABLE -> Icons.Default.Check
        AvailabilityStatus.MAYBE -> Icons.Default.HelpOutline
        AvailabilityStatus.UNAVAILABLE -> Icons.Default.Close
    }

    val selectedColor = when (status) {
        AvailabilityStatus.AVAILABLE -> Color(0xFF2E7D32).copy(alpha = 0.2f)
        AvailabilityStatus.MAYBE -> Color(0xFFE65100).copy(alpha = 0.2f)
        AvailabilityStatus.UNAVAILABLE -> Color(0xFFC62828).copy(alpha = 0.2f)
    }

    val foregroundColor = when (status) {
        AvailabilityStatus.AVAILABLE -> Color(0xFF1B5E20)
        AvailabilityStatus.MAYBE -> Color(0xFFE65100)
        AvailabilityStatus.UNAVAILABLE -> Color(0xFFC62828)
    }

    OutlinedButton(
        onClick = onClick,
        modifier = modifier.height(40.dp),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = if (isSelected) selectedColor else Color.Transparent
        )
    ) {
        Icon(
            icon,
            null,
            tint = if (isSelected) foregroundColor else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp)
        )
    }
}

@Composable
fun ParticipantRow(participant: PollParticipant, isCurrentUser: Boolean) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(participant.displayName)
            if (isCurrentUser) {
                Spacer(Modifier.width(8.dp))
                Surface(
                    color = MaterialTheme.colorScheme.primary,
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text(
                        "You",
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onPrimary
                    )
                }
            }
        }
        participant.comment?.let { comment ->
            if (comment.isNotBlank()) {
                Text(
                    comment,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontStyle = androidx.compose.ui.text.font.FontStyle.Italic
                )
            }
        }
    }
}

@Composable
fun FinalDateDisplay(
    selectedStart: Instant,
    selectedEnd: Instant,
    isAllDay: Boolean
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = Color.Transparent
        ),
        modifier = Modifier.fillMaxWidth()
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            Color(0xFF6678EB),
                            Color(0xFF754AA3)
                        )
                    ),
                    RoundedCornerShape(12.dp)
                )
                .padding(16.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "Final Meeting Time Selected",
                    style = MaterialTheme.typography.titleMedium,
                    color = Color.White
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.CalendarToday, null, tint = Color.White)
                    Spacer(Modifier.width(8.dp))
                    val dateFormat = SimpleDateFormat("MMMM d, yyyy", Locale.getDefault())
                    Text(
                        dateFormat.format(Date.from(selectedStart.toJavaInstant())),
                        style = MaterialTheme.typography.titleMedium,
                        color = Color.White
                    )
                }

                if (!isAllDay) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.AccessTime, null, tint = Color.White)
                        Spacer(Modifier.width(8.dp))
                        val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
                        val start = timeFormat.format(Date.from(selectedStart.toJavaInstant()))
                        val end = timeFormat.format(Date.from(selectedEnd.toJavaInstant()))
                        Text(
                            "$start - $end",
                            style = MaterialTheme.typography.bodyLarge,
                            color = Color.White
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun FinalDateOptionRow(
    option: PollTimeOption,
    stats: ResponseSummary,
    onClick: () -> Unit,
    enabled: Boolean
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                val dateFormat = SimpleDateFormat("MMM d, yyyy", Locale.getDefault())
                Text(
                    dateFormat.format(Date.from(option.startTime.toJavaInstant())),
                    style = MaterialTheme.typography.titleSmall
                )

                if (option.isAllDay) {
                    Text("All day", style = MaterialTheme.typography.bodySmall)
                } else {
                    val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
                    val start = timeFormat.format(Date.from(option.startTime.toJavaInstant()))
                    val end = timeFormat.format(Date.from(option.endTime.toJavaInstant()))
                    Text("$start - $end", style = MaterialTheme.typography.bodySmall)
                }
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                ResponseCount(stats.available, AvailabilityStatus.AVAILABLE)
                ResponseCount(stats.maybe, AvailabilityStatus.MAYBE)
                ResponseCount(stats.unavailable, AvailabilityStatus.UNAVAILABLE)

                Icon(Icons.Default.ChevronRight, null)
            }
        }
    }
}

@Composable
fun StatusBadge(status: PollStatus) {
    val backgroundColor = when (status) {
        PollStatus.DRAFT -> Color(0xFF616161).copy(alpha = 0.15f)
        PollStatus.ACTIVE -> Color(0xFF2E7D32).copy(alpha = 0.15f)
        PollStatus.CLOSED -> Color(0xFFE65100).copy(alpha = 0.15f)
        PollStatus.ARCHIVED -> Color(0xFF616161).copy(alpha = 0.2f)
    }

    val foregroundColor = when (status) {
        PollStatus.DRAFT -> Color(0xFF424242)
        PollStatus.ACTIVE -> Color(0xFF1B5E20)
        PollStatus.CLOSED -> Color(0xFFE65100)
        PollStatus.ARCHIVED -> Color(0xFF424242)
    }

    Surface(
        color = backgroundColor,
        shape = RoundedCornerShape(12.dp)
    ) {
        Text(
            status.name.lowercase().replaceFirstChar { it.uppercase() },
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
            color = foregroundColor
        )
    }
}
