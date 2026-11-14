package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.services.PollService

/** The five-step new-poll flow. [onOpenPoll] opens the created poll from the share step. */
@Composable
fun CreatePollView(
    pollService: PollService,
    screens: PollScreenEnvironment,
    onDismiss: () -> Unit,
    onOpenPoll: (String) -> Unit = {},
) {
    key(pollService.creationAccountKey) { CreationFlow(pollService, screens, onDismiss, onOpenPoll) }
}

@Composable
private fun CreationFlow(
    pollService: PollService,
    screens: PollScreenEnvironment,
    onDismiss: () -> Unit,
    onOpenPoll: (String) -> Unit,
) {
    // The holder lives in the navigation entry's store, which is nested in the session store. The
    // draft, the step and an in-flight creation outlast the Activity; popping the entry cancels
    // them, and reopening the form builds a fresh model.
    val holder = pollCreationHolder(
        polls = pollService,
        store = { screens.creationStore(pollService.creationAccountId) },
        clock = screens.clock,
    )
    val model = holder.opened.getOrElse {
        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Your saved creation could not be read. Check your poll list before starting another poll.")
            TextButton(onClick = onDismiss) { Text("Close") }
        }
        return
    }
    CreationFlowContent(
        model = model,
        onCreate = { holder.launch { submit() } },
        onDismiss = onDismiss,
        onOpenPoll = onOpenPoll,
    )
}

/** The flow's chrome and the current step, driven by [model] only so a test can render it. */
@Composable
fun CreationFlowContent(
    model: PollCreationModel,
    onCreate: () -> Unit,
    onDismiss: () -> Unit,
    onOpenPoll: (String) -> Unit,
) {
    val step = model.step
    val createdPoll = model.createdPoll
    if (step == CreationStep.SHARE && createdPoll != null) {
        PollSharingStep(poll = createdPoll, onClose = onDismiss, onOpenPoll = { onOpenPoll(createdPoll.id) })
        return
    }

    val busy = model.isSubmitting
    Scaffold(
        topBar = {
            Row(
                Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FilledTonalIconButton(onClick = onDismiss, enabled = !busy) {
                    Icon(Icons.Default.Close, "Cancel new poll")
                }
                Text(
                    "Step ${step.number} of ${CreationStep.entries.size}",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
                Spacer(Modifier.width(48.dp))
            }
        },
        bottomBar = {
            Row(
                Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (step != CreationStep.DETAILS) {
                    FilledTonalIconButton(
                        onClick = model::goBack,
                        enabled = model.canGoBack,
                        modifier = Modifier.size(60.dp),
                    ) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Back", Modifier.size(32.dp)) }
                } else {
                    Spacer(Modifier.size(60.dp))
                }
                if (step == CreationStep.EVENT_PASS) {
                    FilledIconButton(onClick = onCreate, enabled = !busy, modifier = Modifier.size(60.dp)) {
                        if (busy) CircularProgressIndicator(Modifier.size(24.dp), color = MaterialTheme.colorScheme.onPrimary, strokeWidth = 2.dp)
                        else Icon(Icons.Default.Check, if (model.pending != null) "Retry saved creation" else "Create Poll", Modifier.size(28.dp))
                    }
                } else {
                    FilledIconButton(onClick = model::advance, enabled = model.canAdvance, modifier = Modifier.size(60.dp)) {
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, "Continue", Modifier.size(32.dp))
                    }
                }
            }
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val (title, subtitle) = when (step) {
                CreationStep.DETAILS -> "Poll details" to "Tell people what you're planning."
                CreationStep.TIME_OPTIONS -> "Time options" to "Add the times people can vote on."
                CreationStep.DEADLINE -> "Response deadline" to "Choose when responses should stop."
                else -> "Event Pass" to "Review your poll, then create it."
            }
            Column(Modifier.padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.headlineMedium)
                Text(subtitle, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            when (step) {
                CreationStep.DETAILS -> DetailsStep(model)
                CreationStep.TIME_OPTIONS -> TimeOptionsStep(model)
                CreationStep.DEADLINE -> DeadlineStep(model)
                else -> EventPassStep(model)
            }
            model.errorMessage?.let { error ->
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                    Text(error, color = MaterialTheme.colorScheme.onErrorContainer, modifier = Modifier.padding(16.dp))
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}
