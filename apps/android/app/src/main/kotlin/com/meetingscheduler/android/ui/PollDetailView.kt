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
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.CalendarSource
import com.meetingscheduler.android.services.PollService
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import java.text.SimpleDateFormat
import java.util.*

// Extension function to convert kotlinx.datetime.Instant to java.time.Instant
private fun Instant.toJavaInstant(): java.time.Instant {
    return java.time.Instant.ofEpochMilli(this.toEpochMilliseconds())
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PollDetailView(
    pollId: String,
    pollService: PollService,
    calendarService: CalendarService,
    clock: Clock,
    onNavigateToResponses: (String) -> Unit,
    onNavigateBack: () -> Unit
) {
    val accountKey = pollService.creationAccountKey
    val opened = remember(pollId, accountKey) { runCatching { PollDetailModel(pollId, pollService, calendarService, clock) } }
    val model = opened.getOrElse {
        Column(Modifier.padding(24.dp)) {
            Text("Your saved response retry could not be read. Check your saved responses before editing.")
            TextButton(onClick = onNavigateBack) { Text("Back") }
        }
        return
    }
    var showClosePollDialog by remember(model) { mutableStateOf(false) }
    var finalTimeOption by remember(model) { mutableStateOf<PollTimeOption?>(null) }

    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val poll = model.poll

    LaunchedEffect(model) { model.load() }

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
        if (model.isLoading) {
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
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(model.detailError ?: "Poll not found")
                    TextButton(onClick = { scope.launch { model.load() } }) { Text("Retry") }
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                if (model.calendarCheck.failedSources.isNotEmpty()) {
                    item {
                        Column {
                            Text("${calendarSourceNames(model.calendarCheck.failedSources)} couldn't be checked. Options marked \"Couldn't check\" may still conflict.",
                                style = MaterialTheme.typography.bodySmall)
                            TextButton(enabled = !model.isCheckingCalendar, onClick = { scope.launch { model.checkCalendar() } }) {
                                Text("Retry calendar check")
                            }
                        }
                    }
                } else if (model.calendarCheck.checkedSources.isNotEmpty()) {
                    item {
                        Text("Checked ${calendarSourceNames(model.calendarCheck.checkedSources)}.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                model.calendarError?.let { message ->
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
                                    val deadline = model.deadlineStatus(closesAt)
                                    val isPastDue = deadline == DeadlineStatus.PAST_DUE
                                    val isClosingSoon = deadline == DeadlineStatus.CLOSING_SOON

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
                if (model.myParticipant == null && poll?.status == PollStatus.ACTIVE) {
                    item {
                        Button(
                            onClick = {
                                scope.launch { model.join() }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !model.isJoining
                        ) {
                            Text(if (model.isJoining) "Joining…" else "Join This Poll")
                        }
                        model.joinError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                }

                // Final Date Display
                model.finalEvent?.let { event ->
                    item {
                        FinalDateDisplay(event)
                    }
                }

                // Final Date Selection (for creator when closed)
                if (model.isCreator && poll?.status == PollStatus.CLOSED && poll?.selectedStartTime == null) {
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

                                model.rankedTimeOptions.forEach { option ->
                                    val stats = model.responseSummary(option.id)
                                    FinalDateOptionRow(
                                        option = option,
                                        pollTimeZone = poll?.timezone ?: "UTC",
                                        stats = stats,
                                        onClick = {
                                            finalTimeOption = option
                                        },
                                        enabled = !model.isSelectingFinalDate
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

                items(model.timeOptions) { option ->
                    TimeOptionRow(
                        pollTimeZone = poll?.timezone ?: "UTC",
                        option = option,
                        responses = model.responseSummary(option.id),
                        myResponse = model.localResponses[option.id],
                        hasCalendarConflict = option.id in model.calendarCheck.busy,
                        calendarUnchecked = option.id in model.calendarCheck.unchecked,
                        canRespond = model.canRespond,
                        onResponseChange = { status -> model.setResponse(option.id, status) },
                        onClick = { onNavigateToResponses(option.id) }
                    )
                }

                // Comment Field
                if (model.myParticipant != null && poll?.status == PollStatus.ACTIVE) {
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
                                        "${model.localComment.length}/${PollDetailModel.MAX_COMMENT_LENGTH}",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                OutlinedTextField(
                                    value = model.localComment,
                                    enabled = !model.isSaving && model.availabilityLoaded,
                                    onValueChange = model::updateComment,
                                    placeholder = { Text("e.g., I'm flexible on timing, or I can only attend virtually...") },
                                    modifier = Modifier.fillMaxWidth(),
                                    minLines = 2,
                                    maxLines = 4,
                                    isError = model.commentError.isNotEmpty()
                                )
                                if (model.commentError.isNotEmpty()) {
                                    Text(
                                        model.commentError,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.error
                                    )
                                }
                            }
                        }
                    }
                }

                if (model.saveError != null) {
                    item {
                        Text(model.saveError.orEmpty(), color = MaterialTheme.colorScheme.error)
                        if (model.myParticipant != null && !model.availabilityLoaded) {
                            TextButton(onClick = { scope.launch { model.loadSavedAvailability() } }) {
                                Text("Retry loading saved responses")
                            }
                        } else if (model.hasVersionConflict) {
                            TextButton(onClick = { scope.launch { model.reviewLatestVersion() } }) {
                                Text("Review latest saved version")
                            }
                        }
                    }
                }

                // Save Responses Button
                if (model.myParticipant != null && poll?.status == PollStatus.ACTIVE) {
                    item {
                        Button(
                            onClick = { scope.launch { model.save() } },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = model.canSave
                        ) {
                            if (model.isSaving) {
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
                    Text("Participants (${model.participants.size})", style = MaterialTheme.typography.titleMedium)
                }

                if (model.participants.isEmpty()) {
                    item {
                        Text(
                            "No participants yet",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                } else {
                    items(model.participants) { participant ->
                        ParticipantRow(
                            participant = participant,
                            isCurrentUser = model.isCurrentUser(participant)
                        )
                    }
                }

                // Close Poll Button
                if (model.isCreator && poll?.status == PollStatus.ACTIVE) {
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
                    scope.launch { model.close() }
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

    model.conflictSnapshot?.let { latest ->
        AlertDialog(
            onDismissRequest = model::dismissConflict,
            title = { Text("Availability changed") },
            text = { Text("Latest saved responses: ${latest.responses.joinToString { it.status.name.lowercase() }}\nComment: ${latest.comment.orEmpty()}\nYour draft is still on this screen.") },
            confirmButton = {
                TextButton(onClick = model::keepDraft) { Text("Keep my draft") }
            },
            dismissButton = {
                TextButton(onClick = model::useSavedVersion) { Text("Use saved version") }
            },
        )
    }

    // Select Final Date Dialog
    finalTimeOption?.let { option ->
        val formattedOption = run {
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
        }

        AlertDialog(
            onDismissRequest = { finalTimeOption = null },
            title = { Text("Select Final Date") },
            text = { Text("Set $formattedOption as the final meeting time? All participants will be notified.") },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch { model.finalize(option) }
                    finalTimeOption = null
                }) {
                    Text("Confirm")
                }
            },
            dismissButton = {
                TextButton(onClick = { finalTimeOption = null }) {
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
    calendarUnchecked: Boolean,
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
                        } else if (calendarUnchecked) {
                            Spacer(Modifier.width(8.dp))
                            Surface(
                                color = MaterialTheme.colorScheme.surfaceVariant,
                                shape = RoundedCornerShape(4.dp)
                            ) {
                                Text(
                                    "Couldn't check",
                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
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
fun FinalDateDisplay(event: FinalCalendarEvent) {
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
                    val (begin, end) = event.insertBounds
                    val intent = Intent(Intent.ACTION_INSERT).apply {
                        data = CalendarContract.Events.CONTENT_URI
                        putExtra(CalendarContract.Events.TITLE, event.title)
                        if (event.isAllDay) putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, true)
                        putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin.toEpochMilliseconds())
                        putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end.toEpochMilliseconds())
                        event.description?.let { putExtra(CalendarContract.Events.DESCRIPTION, it) }
                        event.location?.let { putExtra(CalendarContract.Events.EVENT_LOCATION, it) }
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
                            .apply { timeZone = PollDates.displayZone(event.isAllDay, event.pollTimeZone) }
                        Text(
                            dateFormat.format(Date.from(event.start.toJavaInstant())),
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White
                        )
                    }

                    if (!event.isAllDay) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.AccessTime, null, tint = Color.White)
                            Spacer(Modifier.width(8.dp))
                            val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
                            val start = timeFormat.format(Date.from(event.start.toJavaInstant()))
                            val end = timeFormat.format(Date.from(event.end.toJavaInstant()))
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

private fun calendarSourceNames(sources: List<CalendarSource>): String =
    sources.joinToString(" and ") { source ->
        when (source) {
            CalendarSource.APPLE_CALENDAR -> "Android Calendar"
            CalendarSource.GOOGLE_CALENDAR -> "Google Calendar (primary calendar)"
        }
    }
