package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/** The screen model retains the edit draft and save across Activity recreation. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EditPollView(model: PollDetailModel, onSave: () -> Unit) {
    val draft = model.editDraft ?: return
    var confirmDiscard by remember { mutableStateOf(false) }
    var pickingDate by remember { mutableStateOf(false) }
    var pickingTime by remember { mutableStateOf(false) }
    val enabled = !model.isEditingPoll
    val validation = model.editValidationError()
    fun requestClose() {
        if (!enabled) return
        if (draft.hasChanges) confirmDiscard = true else model.cancelEditing()
    }

    Dialog(onDismissRequest = ::requestClose, properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnClickOutside = false)) {
        Scaffold(
            modifier = Modifier.fillMaxSize(),
            topBar = {
                TopAppBar(
                    title = { Text("Edit Poll") },
                    navigationIcon = { TextButton(onClick = ::requestClose, enabled = enabled) { Text("Cancel") } },
                    actions = {
                        TextButton(onClick = onSave, enabled = enabled && draft.hasChanges && validation == null) {
                            Text(if (model.isEditingPoll) "Saving…" else "Save")
                        }
                    },
                )
            },
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                OutlinedTextField(value = draft.title, onValueChange = { value -> model.editDetails { it.copy(title = value) } },
                    label = { Text("Title") }, singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = draft.description, onValueChange = { value -> model.editDetails { it.copy(description = value) } },
                    label = { Text("Description (optional)") }, minLines = 3, maxLines = 6, enabled = enabled, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = draft.location, onValueChange = { value -> model.editDetails { it.copy(location = value) } },
                    label = { Text("Location (optional)") }, singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Set response deadline", modifier = Modifier.weight(1f))
                    Switch(checked = draft.hasDeadline, onCheckedChange = { value -> model.editDetails { it.copy(hasDeadline = value) } }, enabled = enabled)
                }
                if (draft.hasDeadline) {
                    OutlinedButton(onClick = { pickingDate = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                        Text("Close responses on ${draft.deadlineDate.display()}")
                    }
                    OutlinedButton(onClick = { pickingTime = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                        Text("Close responses at ${draft.deadlineTime.display()}")
                    }
                }
                Text("Deadline times use ${draft.original.timezone}. Editing the deadline does not reopen a closed poll.",
                    style = MaterialTheme.typography.bodySmall)
                (validation ?: model.editError)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        }
    }
    if (confirmDiscard) {
        AlertDialog(onDismissRequest = { confirmDiscard = false }, title = { Text("Discard changes?") },
            confirmButton = { TextButton(onClick = { confirmDiscard = false; model.cancelEditing() }) { Text("Discard Changes") } },
            dismissButton = { TextButton(onClick = { confirmDiscard = false }) { Text("Keep Editing") } })
    }
    if (pickingDate) {
        DatePickerDialogFor(draft.deadlineDate,
            onPick = { date -> model.editDetails { it.copy(deadlineDate = date) } }, onDismiss = { pickingDate = false })
    }
    if (pickingTime) {
        TimePickerDialogFor("Close responses at", draft.deadlineTime,
            onPick = { time -> model.editDetails { it.copy(deadlineTime = time) } }, onDismiss = { pickingTime = false })
    }
}
