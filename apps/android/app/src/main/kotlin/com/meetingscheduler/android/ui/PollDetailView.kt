package com.meetingscheduler.android.ui

import android.content.Intent
import android.provider.CalendarContract
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.plus
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
    val accountKey = pollService.creationAccountKey
    var joinError by remember(pollId, accountKey) { mutableStateOf<String?>(null) }
    var isJoining by remember(pollId, accountKey) { mutableStateOf(false) }
    val userId = authService.currentUser?.id
    var poll by remember(pollId, userId) { mutableStateOf<Poll?>(null) }
    var timeOptions by remember(pollId, userId) { mutableStateOf<List<PollTimeOption>>(emptyList()) }
    var participants by remember(pollId, userId) { mutableStateOf<List<PollParticipant>>(emptyList()) }
    var responses by remember(pollId, userId) { mutableStateOf<List<AvailabilityResponse>>(emptyList()) }
    var myParticipant by remember(pollId, userId) { mutableStateOf<PollParticipant?>(null) }
    var localResponses by remember(pollId, userId) { mutableStateOf<Map<String, AvailabilityStatus>>(emptyMap()) }
    var localComment by remember(pollId, userId) { mutableStateOf("") }
    var commentError by remember(pollId, userId) { mutableStateOf("") }
    var calendarConflicts by remember(pollId, userId) { mutableStateOf<Set<String>>(emptySet()) }

    val recovery = remember(pollId, accountKey) { runCatching { pollService.availabilitySession(pollId) } }
    if (recovery.isFailure) {
        Column(Modifier.padding(24.dp)) {
            Text("Your saved response retry could not be read. Check your saved responses before editing.")
            TextButton(onClick = onNavigateBack) { Text("Back") }
        }
        return
    }
    val saveSession = recovery.getOrThrow()
    var availabilityLoaded by remember(pollId, authService.currentUser?.id) { mutableStateOf(false) }
    var saveError by remember(pollId, authService.currentUser?.id) { mutableStateOf<String?>(null) }
    var hasVersionConflict by remember(pollId, authService.currentUser?.id) { mutableStateOf(false) }
    var conflictSnapshot by remember(pollId, authService.currentUser?.id) { mutableStateOf<AvailabilitySnapshot?>(null) }
    val MAX_COMMENT_LENGTH = 500
    var isLoading by remember(pollId, userId) { mutableStateOf(true) }
    var isSaving by remember(pollId, userId) { mutableStateOf(false) }
    var showClosePollDialog by remember(pollId, userId) { mutableStateOf(false) }
    var showSelectFinalDateDialog by remember(pollId, userId) { mutableStateOf(false) }
    var finalTimeOption by remember(pollId, userId) { mutableStateOf<PollTimeOption?>(null) }
    var isSelectingFinalDate by remember(pollId, userId) { mutableStateOf(false) }

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

    fun applySavedAvailability(saved: AvailabilitySnapshot) {
        responses = responses.filter { it.participantId != saved.participantId } + saved.responseRows()
        participants = participants.map { if (it.id == saved.participantId) it.copy(comment = saved.comment) else it }
        myParticipant = participants.firstOrNull { it.id == saved.participantId }
        localResponses = saveSession.pendingDraft?.responses ?: saved.responses.associate { it.timeOptionId to it.status }
        localComment = saveSession.pendingDraft?.comment ?: saved.comment.orEmpty()
    }

    suspend fun loadSavedAvailability() {
        val loadingUserId = authService.currentUser?.id
        try {
            val saved = saveSession.loadIfCurrent(
                load = { pollService.getAvailability(pollId) },
                isCurrent = { authService.currentUser?.id == loadingUserId },
            ) ?: return
            applySavedAvailability(saved)
            availabilityLoaded = true
            saveError = null
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (authService.currentUser?.id == loadingUserId) {
                saveError = "Could not load your saved availability. Retry before editing."
            }
        }
    }

    LaunchedEffect(pollId, authService.currentUser?.id) {
        isLoading = true
        availabilityLoaded = false
        localResponses = emptyMap()
        localComment = ""
        myParticipant = null
        poll = pollService.loadPoll(pollId)

        if (poll != null) {
            timeOptions = pollService.loadTimeOptions(pollId)
            participants = pollService.loadParticipants(pollId)

            authService.currentUser?.id?.let { userId ->
                myParticipant = participants.firstOrNull { it.userId == userId }
            }

            responses = pollService.loadResponses(timeOptions.map { it.id })

            myParticipant?.let { participant ->
                loadSavedAvailability()
            }

            // Refresh safe connection metadata, then check all slots in one call.
            calendarService.refreshGoogleCalendarConnection()
            if (calendarService.isEnabled && timeOptions.isNotEmpty()) {
                val conflicts = calendarService.checkPollConflicts(timeOptions)
                calendarConflicts = conflicts

                // Auto-mark conflicts as unavailable
                conflicts.forEach { conflictId ->
                    if (saveSession.pendingDraft == null && !localResponses.containsKey(conflictId)) {
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
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(poll?.title ?: "Poll")
                        Spacer(Modifier.width(8.dp))
                        poll?.status?.let { StatusBadge(it) }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.Default.ArrowBack, "Back")
                    }
                },
                actions = {
                    if (poll?.status == PollStatus.ACTIVE) {
                        IconButton(onClick = {
                            poll?.let {
                                val pollURL = "${com.meetingscheduler.android.Config.WEB_URL}/polls/${it.id}"
                                val shareText = """
                                    Join my poll: ${it.title}

                                    $pollURL

                                    Share Code: ${it.shareCode}
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
                calendarService.calendarError?.let { message ->
                    item {
                        Text(message, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                // Poll Info
                if (poll?.description != null || poll?.location != null || poll?.closesAt != null) {
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
                                poll?.closesAt?.let { closesAt ->
                                    val currentTime = Instant.fromEpochMilliseconds(System.currentTimeMillis())
                                    val isPastDue = closesAt < currentTime
                                    val isClosingSoon = !isPastDue && (closesAt.toEpochMilliseconds() - currentTime.toEpochMilliseconds()) < 24 * 60 * 60 * 1000

                                    val dateFormatter = SimpleDateFormat("MMM dd, yyyy", Locale.getDefault())
                                    val formattedDate = dateFormatter.format(Date(closesAt.toEpochMilliseconds()))

                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(
                                            if (isPastDue) Icons.Default.Warning else Icons.Default.DateRange,
                                            null,
                                            modifier = Modifier.size(16.dp),
                                            tint = if (isPastDue) MaterialTheme.colorScheme.error else if (isClosingSoon) Color(0xFFFF8800) else MaterialTheme.colorScheme.onSurface
                                        )
                                        Spacer(Modifier.width(4.dp))
                                        Column {
                                            Text(
                                                "Response deadline: $formattedDate",
                                                style = MaterialTheme.typography.bodySmall,
                                                fontWeight = if (isPastDue || isClosingSoon) FontWeight.SemiBold else FontWeight.Normal,
                                                color = if (isPastDue) MaterialTheme.colorScheme.error else if (isClosingSoon) Color(0xFFFF8800) else MaterialTheme.colorScheme.onSurface
                                            )
                                            if (isPastDue) {
                                                Text(
                                                    "Past due",
                                                    style = MaterialTheme.typography.bodySmall,
                                                    color = MaterialTheme.colorScheme.error
                                                )
                                            } else if (isClosingSoon) {
                                                Text(
                                                    "Closes soon!",
                                                    style = MaterialTheme.typography.bodySmall,
                                                    color = Color(0xFFFF8800)
                                                )
                                            }
                                        }
                                    }
                                }
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
                                verticalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                // Share Link
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Row(
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Text("Share Link", style = MaterialTheme.typography.labelMedium)
                                        TextButton(onClick = {
                                            poll?.let {
                                                val pollURL = "${com.meetingscheduler.android.Config.WEB_URL}/polls/${it.id}"
                                                clipboardManager.setText(AnnotatedString(pollURL))
                                            }
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
                                            .padding(vertical = 12.dp, horizontal = 8.dp),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        poll?.let {
                                            Text(
                                                "${com.meetingscheduler.android.Config.WEB_URL}/polls/${it.id}",
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.primary
                                            )
                                        }
                                    }
                                }

                                HorizontalDivider()

                                // Share Code
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
                }

                // Join Button
                if (myParticipant == null && poll?.status == PollStatus.ACTIVE) {
                    item {
                        Button(
                            onClick = {
                                scope.launch {
                                    isJoining = true
                                    joinError = null
                                    try {
                                        val participant = pollService.joinPoll(pollId)
                                        if (pollService.creationAccountKey != accountKey) return@launch
                                        myParticipant = participant
                                        participants = participants.filterNot { it.id == participant.id } + participant
                                        loadSavedAvailability()
                                    } catch (error: Exception) {
                                        if (error is CancellationException) throw error
                                        if (pollService.creationAccountKey == accountKey) {
                                            joinError = if (error is PollCapacityReached) error.message
                                                else "Joining could not be confirmed. Tap Join This Poll to retry safely."
                                        }
                                    } finally {
                                        if (pollService.creationAccountKey == accountKey) isJoining = false
                                    }
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !isJoining
                        ) {
                            Text(if (isJoining) "Joining…" else "Join This Poll")
                        }
                        joinError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                }

                // Final Date Display
                poll?.selectedStartTime?.let { selectedStart ->
                    poll?.selectedEndTime?.let { selectedEnd ->
                        item {
                            FinalDateDisplay(
                                selectedStart = selectedStart,
                                selectedEnd = selectedEnd,
                                // Finalization copies the chosen option's interval onto the poll.
                                isAllDay = timeOptions.any { it.isAllDay && it.startTime == selectedStart && it.endTime == selectedEnd },
                                pollTimeZone = poll?.timezone ?: "UTC",
                                pollTitle = poll?.title ?: "",
                                pollDescription = poll?.description,
                                pollLocation = poll?.location
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
                                        pollTimeZone = poll?.timezone ?: "UTC",
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
                        pollTimeZone = poll?.timezone ?: "UTC",
                        option = option,
                        responses = responsesForOption(option.id),
                        myResponse = localResponses[option.id],
                        hasCalendarConflict = calendarConflicts.contains(option.id),
                        canRespond = myParticipant != null && poll?.status == PollStatus.ACTIVE && availabilityLoaded && !isSaving,
                        onResponseChange = { status ->
                            if (!isSaving && availabilityLoaded) {
                                localResponses = localResponses + (option.id to status)
                            }
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
                                    enabled = !isSaving && availabilityLoaded,
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

                if (saveError != null) {
                    item {
                        Text(saveError.orEmpty(), color = MaterialTheme.colorScheme.error)
                        if (myParticipant != null && !availabilityLoaded) {
                            TextButton(onClick = { scope.launch { loadSavedAvailability() } }) {
                                Text("Retry loading saved responses")
                            }
                        } else if (hasVersionConflict) {
                            TextButton(onClick = {
                                scope.launch {
                                    val loadingUserId = authService.currentUser?.id
                                    try {
                                        val latest = pollService.getAvailability(pollId)
                                        if (authService.currentUser?.id == loadingUserId) conflictSnapshot = latest
                                    } catch (error: CancellationException) {
                                        throw error
                                    } catch (error: Exception) {
                                        if (authService.currentUser?.id == loadingUserId) {
                                            saveError = "Could not load the latest version. Your draft is unchanged. Try again."
                                        }
                                    }
                                }
                            }) { Text("Review latest saved version") }
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
                                    val savingUserId = authService.currentUser?.id
                                    try {
                                        val draft = AvailabilityDraft(localResponses, localComment.trim().ifEmpty { null })
                                        val saved = saveSession.save(draft, send = { request ->
                                            pollService.saveAvailability(pollId, request)
                                        }, isCurrent = { pollService.creationAccountKey == accountKey })
                                        if (authService.currentUser?.id == savingUserId) {
                                            applySavedAvailability(saved)
                                            saveError = null
                                            hasVersionConflict = false
                                        }
                                    } catch (error: CancellationException) {
                                        throw error
                                    } catch (error: AvailabilityVersionConflict) {
                                        saveError = error.message
                                        hasVersionConflict = true
                                    } catch (error: Exception) {
                                        saveError = "Availability was not confirmed saved. Your draft is unchanged. Tap Save Responses to retry."
                                    } finally {
                                        isSaving = false
                                    }
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !isSaving && availabilityLoaded && !hasVersionConflict && commentError.isEmpty()
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

                // Close Poll Button
                if (isCreator && poll?.status == PollStatus.ACTIVE) {
                    item {
                        Spacer(modifier = Modifier.height(16.dp))
                        Button(
                            onClick = { showClosePollDialog = true },
                            modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.errorContainer,
                                contentColor = MaterialTheme.colorScheme.onErrorContainer
                            )
                        ) {
                            Text("Close Poll")
                        }
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

    conflictSnapshot?.let { latest ->
        AlertDialog(
            onDismissRequest = { conflictSnapshot = null },
            title = { Text("Availability changed") },
            text = { Text("Latest saved responses: ${latest.responses.joinToString { it.status.name.lowercase() }}\nComment: ${latest.comment.orEmpty()}\nYour draft is still on this screen.") },
            confirmButton = {
                TextButton(onClick = {
                    saveSession.acceptLoaded(latest)
                    conflictSnapshot = null
                    hasVersionConflict = false
                    saveError = "Your draft is unchanged. Tap Save Responses to replace the latest version with your draft."
                }) { Text("Keep my draft") }
            },
            dismissButton = {
                TextButton(onClick = {
                    saveSession.acceptLoaded(latest)
                    applySavedAvailability(latest)
                    conflictSnapshot = null
                    hasVersionConflict = false
                    saveError = null
                }) { Text("Use saved version") }
            },
        )
    }

    // Select Final Date Dialog
    if (showSelectFinalDateDialog) {
        val formattedOption = finalTimeOption?.let { option ->
            val dateFormat = SimpleDateFormat("MMMM d, yyyy", Locale.getDefault())
                .apply { timeZone = PollDates.displayZone(option.isAllDay, poll?.timezone ?: "UTC") }
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
                                poll = pollService.finalizePoll(pollId, option.id)
                            } catch (error: CancellationException) {
                                throw error
                            } catch (error: Exception) {
                                saveError = "The final date could not be saved. Try again."
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
    pollTimeZone: String,
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
                            .apply { timeZone = PollDates.displayZone(option.isAllDay, pollTimeZone) }
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
    isAllDay: Boolean,
    pollTimeZone: String,
    pollTitle: String,
    pollDescription: String?,
    pollLocation: String?
) {
    val context = LocalContext.current

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                "Final Meeting Time Selected",
                style = MaterialTheme.typography.titleMedium,
            )

            Button(
                onClick = {
                    val intent = Intent(Intent.ACTION_INSERT).apply {
                        data = CalendarContract.Events.CONTENT_URI
                        putExtra(CalendarContract.Events.TITLE, pollTitle)
                        if (isAllDay) {
                            // Calendar Provider all-day events are UTC midnights of their dates.
                            val date = PollDates.allDayDate(selectedStart, pollTimeZone)
                            putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, true)
                            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, date.atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds())
                            putExtra(CalendarContract.EXTRA_EVENT_END_TIME, date.plus(1, DateTimeUnit.DAY).atStartOfDayIn(TimeZone.UTC).toEpochMilliseconds())
                        } else {
                            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, selectedStart.toEpochMilliseconds())
                            putExtra(CalendarContract.EXTRA_EVENT_END_TIME, selectedEnd.toEpochMilliseconds())
                        }
                        pollDescription?.let {
                            putExtra(CalendarContract.Events.DESCRIPTION, it)
                        }
                        pollLocation?.let {
                            putExtra(CalendarContract.Events.EVENT_LOCATION, it)
                        }
                    }
                    context.startActivity(intent)
                },
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary
                )
            ) {
                Icon(
                    Icons.Default.Add,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(Modifier.width(4.dp))
                Text("Add to Calendar", style = MaterialTheme.typography.labelMedium)
            }
        }

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
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.CalendarToday, null, tint = Color.White)
                        Spacer(Modifier.width(8.dp))
                        val dateFormat = SimpleDateFormat("MMMM d, yyyy", Locale.getDefault())
                            .apply { timeZone = PollDates.displayZone(isAllDay, pollTimeZone) }
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
}

@Composable
fun FinalDateOptionRow(
    option: PollTimeOption,
    pollTimeZone: String,
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
                    .apply { timeZone = PollDates.displayZone(option.isAllDay, pollTimeZone) }
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
